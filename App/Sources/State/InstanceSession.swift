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
    /// Watchdog für JEDE `.connecting`-Phase (Verbindungsaufbau, Auth-Antwort, Pairing-Antwort):
    /// bleibt eine dieser Runden > 8 s ohne Ergebnis (z. B. Server nimmt WS an, antwortet aber nie),
    /// wird sauber gescheitert statt ewig im „Verbinde …"-Spinner zu hängen. Bei jedem Übergang in
    /// einen Ruhezustand (.live/.needsPairing/.failed) gecancelt.
    private var watchdog: Task<Void, Never>?

    init(instance: DiscoveredInstance) { self.instance = instance }

    /// Verbindung aufbauen. Erneut aufrufbar nach einem Fehler.
    func start() async {
        switch phase { case .idle, .failed: break; default: return }
        phase = .resolving

        // Bevorzugt die im TXT annoncierte LAN-IP (deterministisch, keine Zone) — die fragile
        // Bonjour-Auflösung liefert auf einem USB-verbundenen iPad die unbrauchbare link-local
        // Adresse. Fallback: doch auflösen, falls kein addr/port im TXT stand.
        let resolved: (host: String, port: UInt16)?
        if let directHost = instance.directHost, let directPort = instance.directPort {
            resolved = (host: directHost, port: directPort)
        } else {
            resolved = await BonjourResolver.resolve(instance.endpoint)
        }
        guard let (host, port) = resolved else {
            phase = .failed("Instanz nicht erreichbar"); return
        }
        // Gepinnter fp (Keychain, autoritativ) oder beim ersten Pairing der TXT-Hinweis (TOFU).
        guard let fp = KeychainStore.pinnedFingerprint(instanceId: instance.id) ?? instance.fingerprint else {
            phase = .failed("Kein Server-Fingerprint verfügbar"); return
        }

        guard let conn = SocketConnection(host: host, port: port, pinnedFingerprintHex: fp, store: store) else {
            phase = .failed("Ungültige Server-Adresse (\(host):\(port))")
            return
        }
        connection = conn
        consumeEvents(of: conn, tofuFingerprint: fp)
        phase = .connecting            // Spinner bis `.connected` (didOpen) ODER Watchdog
        await conn.connect()
        armWatchdog()
    }

    /// Frischen 8-s-Watchdog für die laufende `.connecting`-Runde bewaffnen (Aufbau/Auth/Pairing).
    /// Feuert nur, wenn wir dann NOCH `.connecting` sind — jeder Übergang in einen Ruhezustand
    /// cancelt ihn. Deckt den toten Endpunkt (Stealth-Firewall schickt kein RST → sonst 60-s-Hänger)
    /// ebenso wie einen Server ab, der den WS annimmt, aber nie auf `auth`/`pair` antwortet.
    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await self?.watchdogFired()
        }
    }

    private func cancelWatchdog() { watchdog?.cancel(); watchdog = nil }

    private func watchdogFired() async {
        guard phase == .connecting else { return }   // schon verbunden/gescheitert → nichts tun
        eventTask?.cancel(); eventTask = nil
        await connection?.disconnect(); connection = nil
        phase = .failed("Zeitüberschreitung – die Instanz antwortet nicht (evtl. veralteter Eintrag). Erneut versuchen oder in mads neu koppeln.")
    }

    /// PIN einlösen (manuelle Eingabe oder aus einem gescannten QR).
    func submitPin(_ pin: String) async {
        guard let conn = connection else { return }
        phase = .connecting
        armWatchdog()                 // Pairing-Antwort muss in 8 s kommen — sonst kein ewiger Spinner
        try? await conn.pair(pin: pin, name: Self.deviceName)
    }

    func disconnect() async {
        cancelWatchdog()
        eventTask?.cancel()
        eventTask = nil
        await connection?.disconnect()
        connection = nil
        phase = .idle
    }

    /// Beim Zurückkehren in den Vordergrund neu verbinden — iOS suspendiert den WebSocket im
    /// Hintergrund (§8.5). `start()` re-authentifiziert mit dem gespeicherten Token (kein erneutes
    /// Pairing) und holt via request_snapshot den frischen Stand. Läuft NUR, wenn wir zuvor
    /// verbunden/gescheitert waren — ein laufender Verbindungs-/Pairing-Vorgang wird nicht gestört.
    func reconnect() async {
        switch phase {
        case .live, .failed:
            cancelWatchdog()
            eventTask?.cancel()
            eventTask = nil
            await connection?.disconnect()
            connection = nil
            phase = .idle
            await start()
        default:
            break
        }
    }

    /// „Neu koppeln": den (evtl. serverseitig widerrufenen) Token verwerfen und neu verbinden. Der
    /// gepinnte Fingerprint bleibt (Cert unverändert) → nach dem Reconnect fehlt nur der Token → die
    /// App geht in `.needsPairing` → `PairingView` (frische PIN). Escape aus dem revoked-/Auth-
    /// Sackgassen-Zustand, in dem „Erneut versuchen" nur den toten Token wiederholt.
    func repair() async {
        await disconnect()
        KeychainStore.forgetToken(instanceId: instance.id)
        await start()
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
        let delivered = await sendCommand(["type": "send_input", "agentId": agentId, "text": trimmed])
        if delivered { store.addSentMessage(agentId: agentId, text: trimmed) } // eigene Nachricht sichtbar machen
        return delivered
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

    /// AskUserQuestion aus der Ferne beantworten: pro Frage die gewählte Antwort (Schlüssel = Fragetext,
    /// Wert = gewähltes Label oder Freitext) als `answer_questions`-Entscheidung senden — identisch zum
    /// Desktop-`QuestionForm`. Der Sidecar formatiert daraus die Nutzer-Antwort und lässt den Agenten
    /// fortfahren. Nur aus explizitem Tap; bei Sende-Fehler wieder einblenden.
    func answerQuestions(agentId: String, requestId: String, answers: [String: String]) async {
        guard let req = store.permissions.first(where: { $0.requestId == requestId }) else { return }
        store.removePermission(requestId: requestId)

        let decision: [String: Any] = ["behavior": "answer_questions", "answers": answers]
        let delivered = await sendCommand([
            "type": "answer_permission", "agentId": agentId, "requestId": requestId, "decision": decision,
        ])
        if !delivered {
            store.restorePermission(req)
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

    /// register_root + read_dir in EINEM Schritt, mit typisiertem Fehler (statt stummer leerer Liste).
    /// So sieht der Datei-Browser den echten Grund (Root-Reg fehlgeschlagen / Pfad außerhalb /
    /// Zeitüberschreitung), statt bei jedem Problem nur „Leer" zu zeigen.
    enum DirLoad: Sendable { case ok([DirNode]); case failed(String) }

    func loadDir(_ path: String) async -> DirLoad {
        let regText = await rawFileRPC(op: "register_root", args: ["path": path])
        if let env = try? JSONDecoder().decode(OkEnvelope.self, from: Data(regText.utf8)), !env.ok {
            return .failed("register_root: \(env.error ?? "unbekannt")")
        }
        let text = await rawFileRPC(op: "read_dir", args: ["path": path])
        guard let env = try? JSONDecoder().decode(FileRPCEnvelope<[DirNode]>.self, from: Data(text.utf8)) else {
            return .failed("read_dir: ungültiges/kein Reply")
        }
        if env.ok { return .ok(env.result ?? []) }
        return .failed("read_dir: \(env.error ?? "unbekannt")")
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
        // NUR den Event-Stream capturen, NICHT `conn` — sonst hielte der Task die Verbindung am Leben
        // (Retain-Cycle) und sie schlösse beim Verlassen der Instanz nie. So dealloziert die
        // Verbindung beim Pop → deinit schließt die URLSession sauber.
        let events = conn.events
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event, tofuFingerprint: tofuFingerprint)
            }
        }
    }

    private func handle(_ event: ConnectionEvent, tofuFingerprint: String) async {
        switch event {
        case .connected:
            // Verbindung steht WIRKLICH → jetzt erst Auth (Token vorhanden) oder Pairing anzeigen.
            if let token = KeychainStore.token(instanceId: instance.id) {
                armWatchdog()                                       // Auth-Antwort in 8 s absichern
                try? await connection?.authenticate(token: token)   // bleibt .connecting bis .authenticated
            } else {
                cancelWatchdog()                                    // Ruhezustand: wartet auf Nutzer-PIN
                phase = .needsPairing
            }
        case .paired(let token, _):
            // Beim ersten Pairing den (TOFU-)fp mit dem Token pinnen.
            cancelWatchdog()
            KeychainStore.saveCredentials(instanceId: instance.id, token: token, fingerprint: tofuFingerprint)
            await requestSnapshot()
            phase = .live
        case .authenticated:
            cancelWatchdog()
            await requestSnapshot()
            phase = .live
        case .pairRejected(let reason), .failed(let reason):
            cancelWatchdog()
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
