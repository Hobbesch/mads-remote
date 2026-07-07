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

    // MARK: - Command-Plane (P3.1) — die App fernsteuert

    /// Sendet einen command-Frame. `true` = auf den Socket geschrieben (kein Wurf). KEIN echtes Ack
    /// (es gibt kein Ack-Protokoll) — fängt aber die realen Fehlerfälle ab: kein Socket / Verbindung
    /// nil / geschlossener Socket. Bei Fehler wird eine Notiz für die UI gesetzt.
    @discardableResult
    private func sendCommand(_ hostMessage: [String: Any]) async -> Bool {
        guard let conn = connection else {
            store.noteError("Nicht verbunden.")
            return false
        }
        do {
            try await conn.send(OutgoingFrame.command(hostMessage: hostMessage))
            return true
        } catch {
            store.noteError("Senden fehlgeschlagen: \(error.localizedDescription)")
            return false
        }
    }

    /// `true` = zugestellt (der Composer leert das Eingabefeld erst dann).
    @discardableResult
    func sendInput(agentId: String, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await sendCommand(["type": "send_input", "agentId": agentId, "text": trimmed])
    }

    func interrupt(agentId: String) async { await sendCommand(["type": "interrupt_agent", "agentId": agentId]) }
    func stopAgent(agentId: String) async { await sendCommand(["type": "stop_agent", "agentId": agentId]) }

    /// Berechtigungsanfrage beantworten — NUR aus einem expliziten Nutzer-Tap (§6 P3#16).
    /// Guard gegen Doppel-Antwort (Anfrage noch offen?); optimistisch entfernen (schließt das
    /// Doppel-Tap-Fenster über den await hinweg); bei Sende-Fehler wieder einblenden.
    func answerPermission(agentId: String, requestId: String, allow: Bool) async {
        guard let req = store.permissions.first(where: { $0.requestId == requestId }) else { return }
        store.removePermission(requestId: requestId)

        let decision: [String: Any] = allow
            ? ["behavior": "allow"]
            : ["behavior": "deny", "message": "Aus der Ferne abgelehnt"]
        let delivered = await sendCommand([
            "type": "answer_permission", "agentId": agentId, "requestId": requestId, "decision": decision,
        ])
        if !delivered {
            store.restorePermission(req) // Antwort kam nicht raus → wieder anzeigen (noteError ist gesetzt)
        }
    }

    /// Einfache `{ type, agentId }`-Aktion (sync_branch/create_pr/gate_task/integrate_pr/update_main/…).
    func streamAction(_ type: String, agentId: String) async {
        await sendCommand(["type": type, "agentId": agentId])
    }

    // MARK: - file-rpc (P3.2) — Datei-Baum + Markdown lesen/schreiben

    /// Request bauen (Args auf dem MainActor) und nur den fertigen String an die Actor reichen.
    /// Ein Server-Fehler (`{ok:false,error}`) wird für die UI vermerkt — damit unterscheidbar von
    /// einem reinen Decode-Fehler und die echte Ursache sichtbar (statt „nicht erreichbar" zu raten).
    private func rawFileRPC(op: String, args: [String: Any]) async -> String {
        guard let conn = connection else { return #"{"ok":false,"error":"Nicht verbunden"}"# }
        let id = UUID().uuidString
        let text = await conn.request(id: id, text: OutgoingFrame.fileRPC(id: id, op: op, args: args))
        if let env = try? JSONDecoder().decode(OkEnvelope.self, from: Data(text.utf8)), !env.ok {
            store.noteError(env.error ?? "Dateizugriff fehlgeschlagen")
        }
        return text
    }

    @discardableResult
    func registerRoot(_ path: String) async -> Bool {
        let text = await rawFileRPC(op: "register_root", args: ["path": path])
        return (try? JSONDecoder().decode(OkEnvelope.self, from: Data(text.utf8)))?.ok ?? false
    }

    func readDir(_ path: String) async -> [DirNode] {
        let text = await rawFileRPC(op: "read_dir", args: ["path": path])
        return (try? JSONDecoder().decode(FileRPCEnvelope<[DirNode]>.self, from: Data(text.utf8)))?.result ?? []
    }

    func readFile(_ path: String) async -> FileRead? {
        let text = await rawFileRPC(op: "read_file", args: ["path": path])
        return (try? JSONDecoder().decode(FileRPCEnvelope<FileRead>.self, from: Data(text.utf8)))?.result
    }

    func writeFile(path: String, content: String, baseMtimeMs: Double, baseSize: Int, baseHash: String) async -> WriteResult? {
        let text = await rawFileRPC(op: "write_file", args: [
            "path": path, "content": content,
            "baseMtimeMs": baseMtimeMs, "baseSize": baseSize, "baseHash": baseHash,
        ])
        return (try? JSONDecoder().decode(FileRPCEnvelope<WriteResult>.self, from: Data(text.utf8)))?.result
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
