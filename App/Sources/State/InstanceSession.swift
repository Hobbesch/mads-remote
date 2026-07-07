import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Koordiniert eine Verbindung zu EINER Instanz: Bonjour auflösen → `SocketConnection` → mit
/// gespeichertem Token authentifizieren, sonst Pairing (PIN/QR). Hält den `InstanceStore` (Live-
/// Mirror) und konsumiert die Verbindungs-Events (Token bei Erfolg in die Keychain).
@Observable
@MainActor
final class InstanceSession {
    enum Phase: Sendable, Equatable {
        case idle, resolving, connecting, needsPairing, live
        case failed(String)
    }

    let instance: DiscoveredInstance
    let store = InstanceStore()
    private(set) var phase: Phase = .idle

    private var connection: SocketConnection?
    private var eventTask: Task<Void, Never>?

    init(instance: DiscoveredInstance) { self.instance = instance }

    /// Verbindung aufbauen. Erneut aufrufbar nach einem Fehler.
    func start() async {
        switch phase { case .idle, .failed: break; default: return }
        phase = .resolving

        guard let (host, port) = await BonjourResolver.resolve(instance.endpoint) else {
            phase = .failed("Instanz nicht erreichbar"); return
        }
        // Gepinnter fp (Keychain, autoritativ) oder beim ersten Pairing der TXT-Hinweis (TOFU).
        guard let fp = KeychainStore.pinnedFingerprint(instanceId: instance.id) ?? instance.fingerprint else {
            phase = .failed("Kein Server-Fingerprint verfügbar"); return
        }

        let conn = SocketConnection(host: host, port: port, pinnedFingerprintHex: fp, store: store)
        connection = conn
        consumeEvents(of: conn, tofuFingerprint: fp)
        await conn.connect()

        if let token = KeychainStore.token(instanceId: instance.id) {
            phase = .connecting
            try? await conn.authenticate(token: token)
        } else {
            phase = .needsPairing
        }
    }

    /// PIN einlösen (manuelle Eingabe oder aus einem gescannten QR).
    func submitPin(_ pin: String) async {
        guard let conn = connection else { return }
        phase = .connecting
        try? await conn.pair(pin: pin, name: Self.deviceName)
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        await connection?.disconnect()
        connection = nil
        phase = .idle
    }

    // MARK: - intern

    private func consumeEvents(of conn: SocketConnection, tofuFingerprint: String) {
        eventTask = Task { [weak self] in
            for await event in conn.events {
                await self?.handle(event, tofuFingerprint: tofuFingerprint)
            }
        }
    }

    private func handle(_ event: ConnectionEvent, tofuFingerprint: String) async {
        switch event {
        case .paired(let token, _):
            // Beim ersten Pairing den (TOFU-)fp mit dem Token pinnen.
            KeychainStore.saveCredentials(instanceId: instance.id, token: token, fingerprint: tofuFingerprint)
            await requestSnapshot()
            phase = .live
        case .authenticated:
            await requestSnapshot()
            phase = .live
        case .pairRejected(let reason), .failed(let reason):
            phase = .failed(reason)
        }
    }

    private func requestSnapshot() async {
        try? await connection?.send(OutgoingFrame.command(hostMessage: ["type": "request_snapshot"]))
    }

    static let deviceName: String = {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iOS-Gerät"
        #endif
    }()
}
