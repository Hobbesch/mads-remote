import Foundation
import Network

/// Ereignisse aus dem Receive-Loop, die die Session (InstanceSession) braucht (Token speichern etc.).
enum ConnectionEvent: Sendable {
    /// WS-Handshake steht wirklich (`NWConnection` ist `ready`) — erst jetzt Auth/Pairing anstoßen.
    case connected
    /// `endpoints`: die von der Bridge gemeldeten „host:port" — die Session merkt sie sich, damit
    /// das Gerät den Mac auch ohne mDNS wiederfindet. Leer bei älteren mads-Versionen.
    case authenticated(deviceId: String, endpoints: [String])
    case paired(token: String, deviceId: String, endpoints: [String])
    case pairRejected(String)
    case failed(String)
}

/// WSS-Verbindung zu einer mads-Instanz (docs/architecture.md §3a). `NWConnection` mit
/// `NWProtocolWebSocket` und SPKI-Pinning im TLS-Verify-Block; Receive-Loop decodiert Frames,
/// spiegelt Events in den `InstanceStore` (MainActor-Hop) und meldet Auth-/Pairing-Ergebnisse
/// über `events`.
actor SocketConnection {
    nonisolated let events: AsyncStream<ConnectionEvent>

    private let url: URL
    private let store: InstanceStore
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mads-remote.socket")
    private let eventsCont: AsyncStream<ConnectionEvent>.Continuation
    private var started = false
    /// Endzustand erreicht (Fehler, Schliessen oder Abbruch) — verhindert doppelte Events und
    /// lässt den `cancelled`-Zustand nach einem eigenen `disconnect()` stumm durchgehen.
    private var finished = false
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
        // Stream ZUERST bauen — `ready` meldet die stehende Verbindung darüber, damit die Session
        // Pairing/Auth nicht optimistisch VOR dem Handshake anzeigt.
        let (events, eventsCont) = AsyncStream<ConnectionEvent>.makeStream()
        self.events = events
        self.eventsCont = eventsCont
        self.connection = NWConnection(
            to: .url(url),
            using: Self.parameters(pinnedFingerprintHex: pinnedFingerprintHex, queue: queue))
    }

    /// TLS- und WebSocket-Parameter; der gepinnte SPKI ist die EINZIGE Zertifikatsprüfung.
    ///
    /// Bewusst `Network.framework` statt `URLSession`: App Transport Security greift nur bei der
    /// High-Level-API und nimmt „lokale" Ziele von der Zertifikatsprüfung aus — dazu zählen aber
    /// nur die privaten Bereiche (10/8, 172.16/12, 192.168/16, `.local`), NICHT 100.64/10, aus dem
    /// Tailscale & Co. ihre Adressen vergeben. Gegen eine LAN-IP liess ATS den gepinnten
    /// Self-Signed-Leaf also durch, gegen die Overlay-IP brach es mit `NSURLError -1200` ab, BEVOR
    /// das Pinning gefragt wurde — im Simulator gegen denselben Listener, dasselbe Zertifikat und
    /// denselben Pin reproduziert (10.0.0.x offen, 100.64.x -1200).
    ///
    /// `sec_protocol_options_set_verify_block` ersetzt die System-Prüfung vollständig: es gilt nur
    /// noch der beim Pairing gepinnte SPKI. Das ist strenger als ATS (eine öffentliche CA nützt
    /// hier nichts) und unabhängig davon, aus welchem Adressbereich die Bridge erreichbar ist.
    private static func parameters(pinnedFingerprintHex: String, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let leaf = chain.first
                else {
                    complete(false)
                    return
                }
                complete(SPKIPinning.matches(certificate: leaf, pinnedFingerprintHex: pinnedFingerprintHex))
            },
            queue)

        let parameters = NWParameters(tls: tls)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }

    /// Finaler Teardown, wenn die Verbindung dealloziert wird (Instanz verlassen / Pop).
    deinit {
        connection.cancel()
        eventsCont.finish()
    }

    func connect() {
        guard !started else { return }
        started = true

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.onReady() }
            case .failed(let error):
                Task { await self.fail("\(error)") }
            case .waiting(let error):
                // `NWConnection` meldet „abgelehnt"/„kein Weg dorthin" als `waiting` und wartet
                // still auf bessere Zeiten. Hier ist das falsch: die Session probiert selbst den
                // nächsten Kandidaten und hat einen Watchdog — also als Fehlschlag melden.
                Task { await self.fail("\(error)") }
            case .cancelled:
                Task { await self.fail("Verbindung beendet") }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func authenticate(token: String) async throws { try await send(OutgoingFrame.auth(token: token)) }
    func pair(pin: String, name: String) async throws { try await send(OutgoingFrame.pair(pin: pin, name: name)) }

    func send(_ text: String) async throws {
        guard started, !finished else { throw URLError(.notConnectedToInternet) }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(text.utf8), contentContext: context, isComplete: true,
                completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
        }
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
        guard !finished else { return }
        finished = true
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.goingAway)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
        connection.cancel()
        failAllPending()
        eventsCont.finish()
    }

    // MARK: - intern

    private func onReady() {
        guard !finished else { return }
        eventsCont.yield(.connected)
        receiveNext()
    }

    /// Endzustand: einmal melden, offene Requests auflösen, Stream schliessen. Die URL steht mit
    /// im Text → Diagnose: welchen Kandidaten hat die App tatsächlich gewählt?
    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        eventsCont.yield(.failed("[\(url.absoluteString)] \(reason)"))
        failAllPending()
        eventsCont.finish()
        connection.cancel()
    }

    /// Eine WS-Nachricht lesen. Alles, was der Callback weiterreicht, wird VOR dem Hop in den
    /// Actor in `Sendable`-Werte übersetzt — `ContentContext`/`NWError` gehören nicht über die
    /// Isolationsgrenze.
    private func receiveNext() {
        connection.receiveMessage { [weak self] data, context, _, error in
            let isClose = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata)?.opcode == .close
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            let errorText = error.map { "\($0)" }
            guard let self else { return }
            Task { await self.onMessage(text: text, isClose: isClose, errorText: errorText) }
        }
    }

    private func onMessage(text: String?, isClose: Bool, errorText: String?) async {
        if let errorText {
            fail(errorText)
            return
        }
        if isClose {
            fail("Gegenstelle hat die Verbindung geschlossen")
            return
        }
        if let text { await handle(text) }
        guard !finished else { return }
        receiveNext()
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
                eventsCont.yield(.paired(token: token, deviceId: dev, endpoints: frame.endpoints ?? []))
            } else {
                eventsCont.yield(.pairRejected(frame.error ?? "Pairing fehlgeschlagen"))
            }
        case "auth-reply":
            if frame.ok == true {
                eventsCont.yield(.authenticated(deviceId: frame.deviceId ?? "", endpoints: frame.endpoints ?? []))
            } else {
                eventsCont.yield(.failed(frame.error ?? "Authentifizierung fehlgeschlagen"))
            }
        default:
            break
        }
    }
}
