import Foundation

/// Ereignisse aus dem Receive-Loop, die die Session (InstanceSession) braucht (Token speichern etc.).
enum ConnectionEvent: Sendable {
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

    init(host: String, port: UInt16, pinnedFingerprintHex: String, store: InstanceStore) {
        self.url = URL(string: "wss://\(host):\(port)/")!
        self.store = store
        self.delegate = PinningDelegate(pinnedFingerprintHex: pinnedFingerprintHex)
        self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        (self.events, self.eventsCont) = AsyncStream.makeStream()
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
                eventsCont.yield(.failed(String(describing: error)))
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
