import Foundation

/// Ereignisse aus dem Receive-Loop, die die Session (InstanceSession) braucht (Token speichern etc.).
enum ConnectionEvent: Sendable {
    /// WS-Handshake steht wirklich (`didOpenWithProtocol`) — erst jetzt Auth/Pairing anstoßen.
    case connected
    case authenticated(deviceId: String)
    case paired(token: String, deviceId: String)
    case pairRejected(String)
    case failed(String)
}

/// WSS-Verbindung zu einer mads-Instanz (docs/architecture.md §3a). `URLSessionWebSocketTask` mit
/// SPKI-Pinning am Session-Delegate; Receive-Loop decodiert Frames, spiegelt Events in den
/// `InstanceStore` (MainActor-Hop) und meldet Auth-/Pairing-Ergebnisse über `events`.
actor SocketConnection {
    nonisolated let events: AsyncStream<ConnectionEvent>

    private let url: URL
    private let store: InstanceStore
    private let session: URLSession
    private let delegate: PinningDelegate
    private let eventsCont: AsyncStream<ConnectionEvent>.Continuation
    private var task: URLSessionWebSocketTask?
    /// Offene file-rpc-Requests (id → Continuation), aufgelöst durch das passende file-rpc-reply.
    private var pending: [String: CheckedContinuation<String, Never>] = [:]
    /// Timeout-Tasks je Request — bei Reply gecancelt, damit kein `Task.sleep` liegen bleibt.
    private var timeouts: [String: Task<Void, Never>] = [:]

    init?(host: String, port: UInt16, pinnedFingerprintHex: String, store: InstanceStore) {
        // Zone-ID (link-local, z. B. "169.254.x.x%en3" oder IPv6 "fe80::…%en0") prozentkodieren —
        // ein rohes % ist keine gültige URL-Kodierung, `URL(string:)` gäbe sonst nil zurück.
        let encodedHost = host.replacingOccurrences(of: "%", with: "%25")
        guard let url = URL(string: "wss://\(encodedHost):\(port)/") else { return nil }
        self.url = url
        self.store = store
        // Stream ZUERST bauen — der Pinning-Delegate meldet `didOpen` (echte Verbindung steht)
        // darüber, damit die Session Pairing/Auth nicht optimistisch VOR dem Handshake anzeigt.
        let (events, eventsCont) = AsyncStream<ConnectionEvent>.makeStream()
        self.events = events
        self.eventsCont = eventsCont
        self.delegate = PinningDelegate(pinnedFingerprintHex: pinnedFingerprintHex) {
            eventsCont.yield(.connected)
        }
        self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

    /// Finaler Teardown, wenn die Verbindung dealloziert wird (Instanz verlassen / Pop): URLSession
    /// invalidieren → WS schließen + Event-Stream beenden. Greift zuverlässig, weil der eventTask
    /// jetzt den STREAM (nicht die Verbindung) hält → kein Retain-Cycle, der die Verbindung am Leben
    /// hielte. So braucht es KEIN aggressives `onDisappear { disconnect }` mehr (das beim internen
    /// Navigieren in einen Stream fälschlich trennte).
    deinit {
        session.invalidateAndCancel()
        eventsCont.finish()
    }

    func connect() {
        guard task == nil else { return }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        Task { await receiveLoop() }
    }

    func authenticate(token: String) async throws { try await send(OutgoingFrame.auth(token: token)) }
    func pair(pin: String, name: String) async throws { try await send(OutgoingFrame.pair(pin: pin, name: name)) }

    func send(_ text: String) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        try await task.send(.string(text))
    }

    /// Einen bereits gebauten file-rpc-Request (Text, mit `id`) senden und auf das korrelierte
    /// `file-rpc-reply` warten. Gibt den rohen Reply-Text zurück (der Aufrufer decodiert typisiert).
    /// Robust: Sende-Fehler und ein 10-s-Timeout lösen die Continuation mit einer Fehler-Hülle auf.
    func request(id: String, text: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            pending[id] = cont
            timeouts[id] = Task {
                try? await Task.sleep(for: .seconds(10))
                resolve(id, #"{"ok":false,"error":"Zeitüberschreitung"}"#)
            }
            Task {
                do { try await send(text) }
                catch { resolve(id, #"{"ok":false,"error":"nicht gesendet"}"#) }
            }
        }
    }

    private func resolve(_ id: String, _ text: String) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(returning: text)
    }

    /// Alle offenen Requests mit Fehler auflösen (Socket-Ende / Disconnect) — kein 10-s-Hängen.
    private func failAllPending() {
        for (_, timeout) in timeouts { timeout.cancel() }
        timeouts.removeAll()
        for (_, cont) in pending { cont.resume(returning: #"{"ok":false,"error":"getrennt"}"#) }
        pending.removeAll()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failAllPending()
        eventsCont.finish()
    }

    // MARK: - intern

    private func receiveLoop() async {
        guard let task else { return }
        while true {
            do {
                switch try await task.receive() {
                case .string(let text): await handle(text)
                case .data(let data):
                    if let s = String(data: data, encoding: .utf8) { await handle(s) }
                @unknown default: break
                }
            } catch {
                // Deckt auch den Pin-Mismatch ab (TLS-Trust-Abbruch → receive() wirft).
                // URL mit ausgeben → Diagnose: nutzt die App die TXT-IP oder die link-local Adresse?
                eventsCont.yield(.failed("[\(url.absoluteString)] \(error)"))
                failAllPending() // offene file-rpc-Requests sofort scheitern lassen (nicht 10 s hängen)
                eventsCont.finish()
                return
            }
        }
    }

    private func handle(_ text: String) async {
        guard let frame = WireFrame.decode(text) else { return }
        switch frame.channel {
        case "event", "snapshot":
            if let msg = frame.msg { await store.apply(msg) }
        case "file-rpc-reply":
            if let id = frame.id { resolve(id, text) }
        case "pair-reply":
            if frame.ok == true, let token = frame.token, let dev = frame.deviceId {
                eventsCont.yield(.paired(token: token, deviceId: dev))
            } else {
                eventsCont.yield(.pairRejected(frame.error ?? "Pairing fehlgeschlagen"))
            }
        case "auth-reply":
            if frame.ok == true {
                eventsCont.yield(.authenticated(deviceId: frame.deviceId ?? ""))
            } else {
                eventsCont.yield(.failed(frame.error ?? "Authentifizierung fehlgeschlagen"))
            }
        default:
            break
        }
    }
}
