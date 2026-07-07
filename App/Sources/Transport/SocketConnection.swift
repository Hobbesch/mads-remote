import Foundation

/// WSS-Verbindung zu einer mads-Instanz (docs/architecture.md §3a). `URLSessionWebSocketTask` mit
/// SPKI-Pinning am Session-Delegate; Receive-Loop decodiert Frames und spiegelt sie in den
/// `InstanceStore` (MainActor-Hop). Als `actor` gekapselt, damit Senden/Empfangen/State thread-safe
/// sind. Auth (`pair`/`auth`) senden die Aufrufer; die UI dafür kommt in P2.3.
actor SocketConnection {
    enum State: Sendable, Equatable {
        case idle, connecting, connected, authenticated
        case failed(String)
    }

    private let url: URL
    private let store: InstanceStore
    private let session: URLSession
    private let delegate: PinningDelegate
    private var task: URLSessionWebSocketTask?
    private(set) var state: State = .idle

    init(host: String, port: UInt16, pinnedFingerprintHex: String, store: InstanceStore) {
        self.url = URL(string: "wss://\(host):\(port)/")!
        self.store = store
        self.delegate = PinningDelegate(pinnedFingerprintHex: pinnedFingerprintHex)
        self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

    func connect() {
        guard task == nil else { return }
        let task = session.webSocketTask(with: url)
        self.task = task
        state = .connecting
        task.resume()
        Task { await receiveLoop() }
    }

    func authenticate(token: String) async throws {
        try await send(OutgoingFrame.auth(token: token))
    }

    func pair(pin: String, name: String) async throws {
        try await send(OutgoingFrame.pair(pin: pin, name: name))
    }

    func send(_ text: String) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        try await task.send(.string(text))
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    // MARK: - intern

    private func receiveLoop() async {
        guard let task else { return }
        state = .connected
        while true {
            do {
                switch try await task.receive() {
                case .string(let text): await handle(text)
                case .data(let data):
                    if let s = String(data: data, encoding: .utf8) { await handle(s) }
                @unknown default: break
                }
            } catch {
                state = .failed(String(describing: error)) // deckt Pin-Mismatch (TLS-Abbruch) mit ab
                return
            }
        }
    }

    private func handle(_ text: String) async {
        guard let frame = WireFrame.decode(text) else { return }
        switch frame.channel {
        case "event", "snapshot":
            if let msg = frame.msg { await store.apply(msg) }
        case "pair-reply", "auth-reply":
            if frame.ok == true { state = .authenticated }
        default:
            break
        }
    }
}
