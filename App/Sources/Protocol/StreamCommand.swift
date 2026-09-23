import Foundation

/// Reine Baupläne für die HostMessages, mit denen die App die Betriebsart eines Streams ändert.
///
/// Ausgelagert aus `InstanceSession`, damit die Nutzlast prüfbar ist, ohne eine Verbindung zu
/// bauen: die Fehler, die hier entstehen, sind stille — ein falsch geschriebener `rawValue` oder
/// ein mitgeschicktes `nil`-Feld wird von der Bridge verworfen, und am Gerät passiert dann
/// schlicht nichts. Genau das lässt sich so festnageln.
enum StreamCommand {
    /// Modell und/oder Effort. Nicht gesetzte Felder werden WEGGELASSEN, nicht als `null`
    /// geschickt: mads unterscheidet „nicht ändern" von „leeren", und ein `null` landete im
    /// `msg["model"] = NSNull()`-Fall als unbrauchbarer Wert im Sidecar.
    static func modelEffort(agentId: String, model: String?, effort: EffortMode?) -> [String: Any] {
        var msg: [String: Any] = ["type": "set_model_effort", "agentId": agentId]
        if let model, !model.isEmpty { msg["model"] = model }
        if let effort { msg["effort"] = effort.rawValue }
        return msg
    }

    static func permissionMode(agentId: String, mode: PermissionMode) -> [String: Any] {
        ["type": "set_permission_mode", "agentId": agentId, "mode": mode.rawValue]
    }

    static func sandboxMode(agentId: String, mode: SandboxMode) -> [String: Any] {
        ["type": "set_sandbox_mode", "agentId": agentId, "mode": mode.rawValue]
    }

    /// Konto wechseln. Ohne `agentId` gilt es nur als Default für NEUE Streams — das Feld darf dann
    /// nicht mitkommen, sonst wechselte mads das Konto eines Streams namens "".
    static func account(_ accountId: String, agentId: String?) -> [String: Any] {
        var msg: [String: Any] = ["type": "set_account", "accountId": accountId]
        if let agentId, !agentId.isEmpty { msg["agentId"] = agentId }
        return msg
    }

    // Berechnet statt `static let`: ein `[String: Any]` ist nicht `Sendable`, als globale Konstante
    // also unter strict concurrency nicht erlaubt. Die Berechnung liefert jedes Mal ein frisches
    // Dictionary — kein geteilter Zustand, kein Sperren nötig.
    static var requestAccounts: [String: Any] { ["type": "request_accounts"] }
    static var requestSnapshot: [String: Any] { ["type": "request_snapshot"] }
}
