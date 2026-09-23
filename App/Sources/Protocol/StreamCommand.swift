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

    /// Einen NEUEN Sub-Stream starten.
    ///
    /// Immer Rolle `sub`: den Integrator legt mads beim Öffnen eines Projekts an, und ein zweiter
    /// wäre ein Widerspruch zur Kern-Invariante „nur der Integrator merged".
    ///
    /// `branch`/`baseRef`/`repoRoot` gehören zusammen — fehlt eines, legt der Sidecar KEINEN
    /// Worktree an und der Stream liefe im Haupt-Checkout. Deshalb entweder alle drei oder keines.
    static func startAgent(
        agentId: String, label: String, prompt: String, project: ProjectInfo?,
        model: String?, effort: EffortMode?, permissionMode: PermissionMode,
        sandboxMode: SandboxMode?, accountId: String?
    ) -> [String: Any] {
        var msg: [String: Any] = [
            "type": "start_agent",
            "agentId": agentId,
            "prompt": prompt,
            "label": label,
            "role": "sub",
            "permissionMode": permissionMode.rawValue,
            "autopilot": "assisted",   // derselbe Default wie am Mac
        ]
        if let model, !model.isEmpty { msg["model"] = model }
        if let effort { msg["effort"] = effort.rawValue }
        if let accountId, !accountId.isEmpty { msg["accountId"] = accountId }
        // Nur abweichend vom Default mitschicken — wie der Mac-Dialog es hält.
        if let sandboxMode, sandboxMode != .on { msg["sandboxMode"] = sandboxMode.rawValue }
        if let project {
            msg["repoRoot"] = project.repoRoot
            msg["branch"] = branchName(for: label)
            msg["baseRef"] = "origin/\(project.defaultBranch)"
        }
        return msg
    }

    /// Branch-Name aus dem Stream-Namen — Spiegel von `slugifyBranch` in `src/store.ts`.
    ///
    /// Bewusst ZEICHENGENAU gespiegelt, inklusive der NFKD-Eigenheit: „über" wird zu `mads/u-ber`,
    /// nicht zu `mads/uber`. Ein Stream, der am Handy und am Mac denselben Namen bekommt, muss
    /// denselben Branch bekommen — sonst entstehen zwei Branches für dieselbe Aufgabe, und die
    /// Kürzung auf 32 Zeichen liesse sie auch noch fast gleich aussehen.
    static func branchName(for label: String) -> String {
        let decomposed = label.lowercased().decomposedStringWithCompatibilityMapping
        var slug = ""
        var lastWasDash = false
        for scalar in decomposed.unicodeScalars {
            let ch = Character(scalar)
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
                slug.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        slug = String(slug.prefix(32))
        return "mads/\(slug.isEmpty ? "task" : slug)"
    }

    // Berechnet statt `static let`: ein `[String: Any]` ist nicht `Sendable`, als globale Konstante
    // also unter strict concurrency nicht erlaubt. Die Berechnung liefert jedes Mal ein frisches
    // Dictionary — kein geteilter Zustand, kein Sperren nötig.
    static var requestAccounts: [String: Any] { ["type": "request_accounts"] }
    static var requestSnapshot: [String: Any] { ["type": "request_snapshot"] }
}
