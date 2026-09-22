import Observation

/// Ein Stream (== mads-`AgentVM`), aus dem Event-/Snapshot-Strom abgeleitet.
struct Stream: Identifiable, Sendable {
    let id: String
    var label: String?          // menschlicher Name (mads-Label); Fallback: id
    var role: String?           // "integrator" | "sub"
    var status: AgentStatus = .starting
    var currentStep: String?
    var costUsd: Double = 0
    var numTurns: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var behind: Int = 0
    var ahead: Int = 0
    var dirty: Bool = false
    var syncBlocked: Bool?
    var pr: PullRequestInfo?
    var timeline: [TimelineItem] = []
    /// Teil-Agenten dieses Streams: toolUseId des `Task`/`Agent`-Aufrufs → Anzeigename. Reine
    /// Laufzeit-Anzeige, damit die Werkzeug-Aufrufe eines Teil-Agenten zuordenbar sind.
    var subAgents: [String: String] = [:]
}

/// Eine Werkzeug-Karte der Timeline — dieselben Felder wie die mads-Timeline am Mac
/// (`TimelineEvent` kind „tool" in `src/store.ts`): Name, mitgelieferte Beschreibung, das Argument
/// (IN), das Ergebnis (OUT) und der Status. Vorher trug die Karte nur den Namen — daher die
/// endlose Reihe inhaltsloser „Bash"-Zeilen.
struct ToolCard: Sendable, Hashable {
    let toolUseId: String
    let name: String
    /// Die vom Tool MITGELIEFERTE Klartext-Beschreibung (Bash & Co. setzen sie) — wie am Mac. Die
    /// abgeleitete Satz-Fassung (`ToolText.description`) gehört auf die Berechtigungskarte.
    var description: String? = nil
    var command: String? = nil      // IN
    var output: String? = nil       // OUT
    var ok: Bool? = nil
    var running: Bool = true
    /// Name des Teil-Agenten, der das Werkzeug aufrief (nil = der Stream selbst).
    var viaSubAgent: String? = nil
}

/// Ein Timeline-Eintrag mit stabiler, monoton steigender ID (für SwiftUI-`ForEach`).
struct TimelineItem: Identifiable, Sendable {
    let id: Int
    var kind: Kind
    enum Kind: Sendable {
        case user(String, [TimelineAttachment])  // Anweisung vom Menschen (+ Bild-Anhänge als Thumbnails)
        case assistant(String, viaSubAgent: String? = nil)
        case thinking(String, viaSubAgent: String? = nil)
        case tool(ToolCard)
        case todos([TodoItem])
        case notice(String)
    }
}

/// Der Store einer verbundenen Instanz: implementiert DENSELBEN Reducer wie der mads-zustand-Store
/// (docs/architecture.md §3a) — `apply(SidecarMessage)` patcht Streams, hängt Timeline-Events an
/// (Ringpuffer 800). `@Observable` treibt die SwiftUI-Ansichten.
@Observable
@MainActor
final class InstanceStore {
    private(set) var project: ProjectInfo?
    private(set) var order: [String] = []
    private(set) var streams: [String: Stream] = [:]
    private(set) var lastError: String?
    /// Offene Berechtigungsanfragen — treiben das prominente Banner. Werden NUR durch expliziten
    /// menschlichen Tap beantwortet (docs/architecture.md §6 P3#16), nie automatisch.
    private(set) var permissions: [PermissionRequestInfo] = []

    private var timelineSeq = 0
    private let ringCapacity = 800

    func apply(_ msg: SidecarMessage) {
        switch msg {
        case .projectResolved(let info):
            project = info
        case .statusUpdate(let id, let status, let step, let label, let role):
            mutate(id) {
                $0.status = status
                $0.currentStep = step
                if let label, !label.isEmpty { $0.label = label }   // nur überschreiben, wenn geliefert
                if let role, !role.isEmpty { $0.role = role }
            }
        case .costUpdate(let id, let cost, let turns, let inp, let out):
            mutate(id) {
                $0.costUsd = cost
                $0.numTurns = turns
                if let inp { $0.inputTokens = inp }
                if let out { $0.outputTokens = out }
            }
        case .gitStatus(let id, let behind, let ahead, let dirty, let blocked):
            mutate(id) { $0.behind = behind; $0.ahead = ahead; $0.dirty = dirty; $0.syncBlocked = blocked }
        case .prUpdate(let id, let pr):
            mutate(id) { $0.pr = pr }
        case .agentEvent(let id, let event):
            applyAgentEvent(id, event)
        case .agentTimeline(let id, let events):
            // Snapshot-Replay: Timeline dieses Agenten aus dem Verlauf NEU aufbauen (Basis leeren,
            // dann in Reihenfolge anwenden — tool_result trifft so die im Replay erzeugte Karte).
            // Idempotent: spätere Live-Events hängen strikt danach an (kein Duplikat). Die
            // Teil-Agenten-Namen werden mit zurückgesetzt — der Replay trägt ihre `Task`-Aufrufe
            // erneut, und alte Einträge würden sonst über die neue Timeline hinaus bestehen.
            mutate(id) { $0.timeline = []; $0.subAgents = [:] }
            for event in events { applyAgentEvent(id, event) }
        case .agentDone(let id, _, let isError):
            mutate(id) { $0.status = isError ? .error : .done }
        case .needsInput(let id, _, _):
            mutate(id) { $0.status = .waitingInput }
        case .permissionRequest(let req):
            if !permissions.contains(where: { $0.requestId == req.requestId }) {
                permissions.append(req)
                notifyPermission(req)   // aus der Ferne merkbar machen (lokale Notification + Ton)
            }
            mutate(req.agentId) { $0.status = .escalation }
        case .permissionResolved(_, let requestId):
            // Woanders beantwortet (Mac / dieses oder ein anderes Gerät) oder abgebrochen → Karte hier
            // entfernen (auch wenn NICHT dieses Gerät geantwortet hat) und die Notification abräumen.
            // Den Stream-Status NICHT selbst umsetzen: der Sidecar sendet dazu ein eigenes status_update
            // (running bei Antwort, paused bei Interrupt, error bei Stop) — das ist die Wahrheit. Ein
            // eigener .running-Reset würde einen gestoppten Agent fälschlich als „läuft" zeigen und für
            // eine unbekannte agentId sogar einen Geister-Stream anlegen.
            removePermission(requestId: requestId)
        case .permissionsOpen(let agentId, let openRequestIds):
            // Autoritativer Snapshot: Karten dieses Agents entfernen, deren requestId nicht mehr offen ist
            // (z. B. offline aufgelöst → permission_resolved verpasst). Andere Agents unberührt; kein Re-Notify.
            let open = Set(openRequestIds)
            let stale = permissions.filter { $0.agentId == agentId && !open.contains($0.requestId) }
            for p in stale { removePermission(requestId: p.requestId) }
        case .error(_, _, _, let message, _):
            lastError = message
        case .unknown:
            break
        }
    }

    /// Eine (optimistisch) entfernte Berechtigungsanfrage entfernen.
    func removePermission(requestId: String) {
        permissions.removeAll { $0.requestId == requestId }
        LocalNotifications.clear(identifier: requestId)   // beantwortet → toten Prompt aus dem Center räumen
    }

    /// Lokale Benachrichtigung mit Ton für eine NEUE Berechtigungsfrage/Rückfrage. Titel = Stream-Name,
    /// Body = WAS freigegeben werden soll bzw. (bei AskUserQuestion) die Frage — kurz genug fürs
    /// Sperrbild-Banner. Vorher stand dort nur der Tool-Name („Bash braucht deine Erlaubnis"), was
    /// nichts darüber sagte, worum es geht; jetzt derselbe Satz wie im Desktop-Dialog.
    private func notifyPermission(_ req: PermissionRequestInfo) {
        let stream = streams[req.agentId]?.label ?? req.agentId
        let body = req.kind == "ask_user_question"
            ? (req.questions?.first?.question ?? "Rückfrage zur aktuellen Arbeit")
            : req.summary
        LocalNotifications.notify(title: "\(stream) braucht eine Entscheidung", body: body, identifier: req.requestId)
    }

    /// Eine optimistisch entfernte Anfrage wieder einblenden (wenn das Senden der Antwort fehlschlug).
    func restorePermission(_ req: PermissionRequestInfo) {
        if !permissions.contains(where: { $0.requestId == req.requestId }) {
            permissions.append(req)
        }
    }

    /// Einen (Sende-)Fehler für die UI vermerken.
    func noteError(_ message: String) {
        lastError = message
    }

    // MARK: - intern

    private func applyAgentEvent(_ id: String, _ event: AgentEvent) {
        switch event {
        case .userText(let t, let atts): pushTimeline(id, .user(t, atts))
        case .assistantText(let t, let parent): pushTimeline(id, .assistant(t, viaSubAgent: subAgentName(id, parent)))
        case .thinking(let t, let parent): pushTimeline(id, .thinking(t, viaSubAgent: subAgentName(id, parent)))
        case .toolUse(let uid, let name, let input, let parent):
            applyToolUse(id, toolUseId: uid, name: name, input: input, parentToolUseId: parent)
        case .toolResult(let uid, let ok, let summary, let output, _):
            // Wie am Mac: das volle Ergebnis, sonst die Kurzfassung.
            completeTool(id, uid, output: output ?? summary, ok: ok)
        case .assistantDelta, .system, .unknown: break // Deltas/System spiegeln wir (noch) nicht
        }
    }

    /// Ein Werkzeug-Aufruf: To-do-Listen werden zur To-do-Karte, `Task`/`Agent` startet zusätzlich
    /// einen Teil-Agenten, alles andere wird eine Werkzeug-Karte mit Argument (IN).
    private func applyToolUse(
        _ id: String, toolUseId: String, name: String, input: [String: JSONValue], parentToolUseId: String?
    ) {
        if name == "Task" || name == "Agent" {
            // Namen des Teil-Agenten merken, BEVOR seine Aufrufe eintreffen — sonst stünde dort „Teil-Agent".
            let label = ToolText.subAgentLabel(input)
            mutate(id) { $0.subAgents[toolUseId] = label }
        }
        if name == "TodoWrite", let todos = ToolText.todos(input) {
            pushTimeline(id, .todos(todos))
            return
        }
        pushTimeline(id, .tool(ToolCard(
            toolUseId: toolUseId,
            name: name,
            description: input["description"]?.stringValue,
            command: ToolText.command(input),
            running: true,
            viaSubAgent: subAgentName(id, parentToolUseId))))
    }

    /// Anzeigename des Teil-Agenten zu einer parentToolUseId (nil = Hauptloop). Unbekannt (z. B. der
    /// `Task`-Aufruf fiel aus dem Ringpuffer) → neutrales „Teil-Agent", damit die Herkunft trotzdem
    /// sichtbar bleibt.
    private func subAgentName(_ id: String, _ parentToolUseId: String?) -> String? {
        guard let parent = parentToolUseId else { return nil }
        return streams[id]?.subAgents[parent] ?? "Teil-Agent"
    }

    private func pushTimeline(_ id: String, _ kind: TimelineItem.Kind) {
        timelineSeq += 1
        let item = TimelineItem(id: timelineSeq, kind: kind)
        mutate(id) { s in
            s.timeline.append(item)
            if s.timeline.count > ringCapacity {
                s.timeline.removeFirst(s.timeline.count - ringCapacity)
            }
        }
    }

    /// tool_result vervollständigt die passende (jüngste) tool_use-Karte mit Ergebnis und Status,
    /// statt eine neue anzuhängen.
    private func completeTool(_ id: String, _ uid: String, output: String?, ok: Bool) {
        var updated = false
        mutate(id) { s in
            guard let idx = s.timeline.lastIndex(where: {
                if case .tool(let card) = $0.kind { return card.toolUseId == uid } else { return false }
            }), case .tool(var card) = s.timeline[idx].kind else { return }
            card.output = output
            card.ok = ok
            card.running = false
            s.timeline[idx].kind = .tool(card)
            updated = true
        }
        // Ergebnis ohne zugehörigen Aufruf (Ringpuffer übergelaufen) → eigene Karte, statt es
        // stillschweigend zu verlieren. Gleiches Verhalten wie am Mac.
        if !updated {
            pushTimeline(id, .tool(ToolCard(toolUseId: uid, name: "Tool", output: output, ok: ok, running: false)))
        }
    }

    private func mutate(_ id: String, _ body: (inout Stream) -> Void) {
        if streams[id] == nil {
            streams[id] = Stream(id: id)
            order.append(id)
        }
        var s = streams[id]!
        body(&s)
        streams[id] = s
    }
}
