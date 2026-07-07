import Observation

/// Ein Stream (== mads-`AgentVM`), aus dem Event-/Snapshot-Strom abgeleitet.
struct Stream: Identifiable, Sendable {
    let id: String
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
}

/// Ein Timeline-Eintrag mit stabiler, monoton steigender ID (für SwiftUI-`ForEach`).
struct TimelineItem: Identifiable, Sendable {
    let id: Int
    var kind: Kind
    enum Kind: Sendable {
        case assistant(String)
        case thinking(String)
        case tool(id: String, name: String, ok: Bool?)
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

    private var timelineSeq = 0
    private let ringCapacity = 800

    func apply(_ msg: SidecarMessage) {
        switch msg {
        case .projectResolved(let info):
            project = info
        case .statusUpdate(let id, let status, let step):
            mutate(id) { $0.status = status; $0.currentStep = step }
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
        case .agentDone(let id, _, let isError):
            mutate(id) { $0.status = isError ? .error : .done }
        case .needsInput(let id, _, _):
            mutate(id) { $0.status = .waitingInput }
        case .permissionRequest(let req):
            mutate(req.agentId) { $0.status = .escalation }
        case .error(_, _, _, let message, _):
            lastError = message
        case .unknown:
            break
        }
    }

    // MARK: - intern

    private func applyAgentEvent(_ id: String, _ event: AgentEvent) {
        switch event {
        case .assistantText(let t): pushTimeline(id, .assistant(t))
        case .thinking(let t): pushTimeline(id, .thinking(t))
        case .toolUse(let uid, let name): pushTimeline(id, .tool(id: uid, name: name, ok: nil))
        case .toolResult(let uid, let ok, _): updateTool(id, uid, ok: ok)
        case .assistantDelta, .system, .unknown: break // Deltas/System spiegeln wir (noch) nicht
        }
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

    /// tool_result aktualisiert die passende (jüngste) tool_use-Karte statt eine neue anzuhängen.
    private func updateTool(_ id: String, _ uid: String, ok: Bool) {
        mutate(id) { s in
            guard let idx = s.timeline.lastIndex(where: {
                if case .tool(let tid, _, _) = $0.kind { return tid == uid } else { return false }
            }), case .tool(let tid, let name, _) = s.timeline[idx].kind else { return }
            s.timeline[idx].kind = .tool(id: tid, name: name, ok: ok)
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
