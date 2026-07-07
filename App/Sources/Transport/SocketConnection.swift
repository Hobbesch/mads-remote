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

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
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
