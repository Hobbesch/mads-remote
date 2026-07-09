import Foundation

/// Codable-Spiegel der mads-`SidecarMessage`-Typen (shared/protocol.ts), die die App zum Spiegeln
/// braucht. Nur decodiert (mads → App). Unbekannte `type`-Werte fallen graceful auf `.unknown`,
/// damit neue Protokoll-Nachrichten die App nicht brechen (Forward-Kompatibilität).
enum SidecarMessage: Sendable {
    case projectResolved(ProjectInfo)
    case statusUpdate(agentId: String, status: AgentStatus, currentStep: String?, label: String?, role: String?)
    case costUpdate(agentId: String, totalCostUsd: Double, numTurns: Int, inputTokens: Int?, outputTokens: Int?)
    case gitStatus(agentId: String, behind: Int, ahead: Int, dirty: Bool, syncBlocked: Bool?)
    case prUpdate(agentId: String, pr: PullRequestInfo?)
    case agentEvent(agentId: String, event: AgentEvent)
    case agentTimeline(agentId: String, events: [AgentEvent])
    case needsInput(agentId: String, reason: String, message: String?)
    case permissionRequest(PermissionRequestInfo)
    case agentDone(agentId: String, subtype: String, isError: Bool)
    case error(agentId: String?, scope: String, code: String, message: String, recoverable: Bool)
    case unknown(type: String)
}

struct ProjectInfo: Codable, Sendable, Hashable {
    let projectId: String
    let repoRoot: String
    let owner: String
    let repo: String
    let defaultBranch: String
}

enum AgentStatus: String, Codable, Sendable {
    case starting, running
    case waitingInput = "waiting_input"
    case paused, escalation, error, done, queued
}

struct PullRequestInfo: Codable, Sendable, Hashable {
    let number: Int
    let url: String
    let state: String        // OPEN | CLOSED | MERGED
    let isDraft: Bool
    let headRefName: String
    let mergeable: String
    let mergeStateStatus: String
    let reviewDecision: String?
    let checksState: String?
}

enum AgentEvent: Sendable {
    case assistantText(String)
    case assistantDelta(String)
    case thinking(String)
    case toolUse(toolUseId: String, name: String)
    case toolResult(toolUseId: String, ok: Bool, summary: String?)
    case system(subtype: String)
    case unknown(kind: String)
}

struct PermissionRequestInfo: Codable, Sendable, Hashable {
    let agentId: String
    let requestId: String
    let toolName: String
    let kind: String         // tool | ask_user_question
    var questions: [AskQuestion]? = nil   // nur bei ask_user_question: Fragen samt Optionen (zum Beantworten aus der Ferne)
}

/// Eine Antwort-Option einer AskUserQuestion-Frage (Label + Erklärung).
struct AskOption: Codable, Sendable, Hashable {
    let label: String
    let description: String?
}

/// Eine AskUserQuestion-Rückfrage: Fragetext + Kurz-Header + wählbare Optionen.
struct AskQuestion: Codable, Sendable, Hashable {
    let question: String
    let header: String?
    let multiSelect: Bool?
    let options: [AskOption]
}

// MARK: - Decoding

private enum MsgKey: String, CodingKey {
    case type, agentId, status, currentStep, totalCostUsd, numTurns, inputTokens, outputTokens
    case behind, ahead, dirty, syncBlocked, pr, event, events, reason, message, subtype, isError
    case scope, code, recoverable, project, requestId, toolName, kind, label, role, questions
}

extension AgentEvent: Decodable {
    private enum K: String, CodingKey { case kind, text, toolUseId, name, ok, summary, subtype }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        switch kind {
        case "assistant_text": self = .assistantText(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "assistant_delta": self = .assistantDelta(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking": self = .thinking(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "tool_use":
            self = .toolUse(
                toolUseId: try c.decodeIfPresent(String.self, forKey: .toolUseId) ?? "",
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "")
        case "tool_result":
            self = .toolResult(
                toolUseId: try c.decodeIfPresent(String.self, forKey: .toolUseId) ?? "",
                ok: try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false,
                summary: try c.decodeIfPresent(String.self, forKey: .summary))
        case "system": self = .system(subtype: try c.decodeIfPresent(String.self, forKey: .subtype) ?? "")
        default: self = .unknown(kind: kind)
        }
    }
}

extension SidecarMessage: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MsgKey.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "unknown"

        func agentId() throws -> String { try c.decodeIfPresent(String.self, forKey: .agentId) ?? "" }

        switch type {
        case "project_resolved":
            self = .projectResolved(try c.decode(ProjectInfo.self, forKey: .project))
        case "status_update":
            self = .statusUpdate(
                agentId: try agentId(),
                status: try c.decodeIfPresent(AgentStatus.self, forKey: .status) ?? .running,
                currentStep: try c.decodeIfPresent(String.self, forKey: .currentStep),
                label: try c.decodeIfPresent(String.self, forKey: .label),
                role: try c.decodeIfPresent(String.self, forKey: .role))
        case "cost_update":
            self = .costUpdate(
                agentId: try agentId(),
                totalCostUsd: try c.decodeIfPresent(Double.self, forKey: .totalCostUsd) ?? 0,
                numTurns: try c.decodeIfPresent(Int.self, forKey: .numTurns) ?? 0,
                inputTokens: try c.decodeIfPresent(Int.self, forKey: .inputTokens),
                outputTokens: try c.decodeIfPresent(Int.self, forKey: .outputTokens))
        case "git_status":
            self = .gitStatus(
                agentId: try agentId(),
                behind: try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0,
                ahead: try c.decodeIfPresent(Int.self, forKey: .ahead) ?? 0,
                dirty: try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? false,
                syncBlocked: try c.decodeIfPresent(Bool.self, forKey: .syncBlocked))
        case "pr_update":
            self = .prUpdate(agentId: try agentId(), pr: try c.decodeIfPresent(PullRequestInfo.self, forKey: .pr))
        case "agent_event":
            self = .agentEvent(agentId: try agentId(), event: try c.decode(AgentEvent.self, forKey: .event))
        case "agent_timeline":
            self = .agentTimeline(
                agentId: try agentId(),
                events: try c.decodeIfPresent([AgentEvent].self, forKey: .events) ?? [])
        case "needs_input":
            self = .needsInput(
                agentId: try agentId(),
                reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "",
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "permission_request":
            self = .permissionRequest(PermissionRequestInfo(
                agentId: try agentId(),
                requestId: try c.decodeIfPresent(String.self, forKey: .requestId) ?? "",
                toolName: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? "tool",
                // Fragen tolerant dekodieren: kaputte/fehlende Optionen dürfen die Nachricht nicht sprengen
                // (Fallback im UI = „nur ablehnbar").
                questions: (try? c.decodeIfPresent([AskQuestion].self, forKey: .questions)) ?? nil))
        case "agent_done":
            self = .agentDone(
                agentId: try agentId(),
                subtype: try c.decodeIfPresent(String.self, forKey: .subtype) ?? "success",
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false)
        case "error":
            self = .error(
                agentId: try c.decodeIfPresent(String.self, forKey: .agentId),
                scope: try c.decodeIfPresent(String.self, forKey: .scope) ?? "sidecar",
                code: try c.decodeIfPresent(String.self, forKey: .code) ?? "",
                message: try c.decodeIfPresent(String.self, forKey: .message) ?? "",
                recoverable: try c.decodeIfPresent(Bool.self, forKey: .recoverable) ?? true)
        default:
            self = .unknown(type: type)
        }
    }
}
