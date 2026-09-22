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
    case permissionResolved(agentId: String, requestId: String)  // woanders beantwortet/abgebrochen → Karte weg
    case permissionsOpen(agentId: String, requestIds: [String])  // autoritative offene requestIds → veraltete Karten prunen
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

/// `parentToolUseId` (auf allen Arten, die ein Teil-Agent erzeugen kann): gesetzt, wenn das Event
/// aus einem SUB-AGENTEN (Task/Agent-Tool) stammt — dann ist es die toolUseId des Task-Aufrufs, der
/// ihn startete. Ohne die Marke sieht ein Werkzeug-Aufruf eines Teil-Agenten in der Timeline
/// genauso aus wie einer des Streams selbst (derselbe Befund wie im mads-Frontend).
enum AgentEvent: Sendable {
    case userText(text: String, attachments: [TimelineAttachment])  // Anweisung vom Menschen (Mac ODER Remote)
    case assistantText(String, parentToolUseId: String? = nil)
    case assistantDelta(String)
    case thinking(String, parentToolUseId: String? = nil)
    case toolUse(toolUseId: String, name: String, input: [String: JSONValue] = [:], parentToolUseId: String? = nil)
    case toolResult(toolUseId: String, ok: Bool, summary: String? = nil, output: String? = nil, parentToolUseId: String? = nil)
    case system(subtype: String)
    case unknown(kind: String)
}

/// Ein Bild-Anhang einer User-Nachricht. Es kommt NUR das kleine Inline-Thumbnail an — das Vollbild
/// bleibt am Mac auf Platte (`.mads` ist über die Bridge bewusst nicht lesbar), und ein mehrere MB
/// grosses Bild soll nicht durch Ringpuffer/Snapshot-Replay/WSS wandern.
struct TimelineAttachment: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let mediaType: String
    var thumbBase64: String? = nil
}

struct PermissionRequestInfo: Sendable, Hashable {
    let agentId: String
    let requestId: String
    let toolName: String
    let kind: String         // tool | ask_user_question
    /// Der ROHE Werkzeug-Input (Befehl, Pfad, Suchmuster …). Ohne ihn stand auf der Karte nur der
    /// Tool-Name — man sollte also „Bash" freigeben, ohne den Befehl zu kennen.
    var input: [String: JSONValue] = [:]
    /// Warum Claude Code fragt (z. B. „Befehl schreibt ausserhalb des Worktrees").
    var decisionReason: String? = nil
    /// Der Pfad, an dem die Freigabe hängt (bei Datei-Tools).
    var blockedPath: String? = nil
    /// Bash-Kategorie (network/pkg/secret/git/write/danger/outward) — hier nur zur Einordnung
    /// ANGEZEIGT: „Immer erlauben" gibt es auf dem Gerät bewusst nicht, siehe `PermissionBanner`.
    var commandKind: String? = nil
    var questions: [AskQuestion]? = nil   // nur bei ask_user_question: Fragen samt Optionen (zum Beantworten aus der Ferne)

    /// Ein Satz, der erklärt, was freigegeben werden soll — identisch zum Desktop-Dialog.
    var summary: String { ToolText.description(tool: toolName, input: input) }
    /// Der rohe Befehl/Pfad für die Code-Zeile der Karte.
    var command: String? { ToolText.command(input) }
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
    case scope, code, recoverable, project, requestId, requestIds, toolName, kind, label, role, questions
    case input, decisionReason, blockedPath, commandKind
}

extension AgentEvent: Decodable {
    private enum K: String, CodingKey {
        case kind, text, toolUseId, name, ok, summary, output, subtype, attachments, input, parentToolUseId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        // Input/Parent tolerant dekodieren: ein unerwartetes Feld darf die Nachricht nie sprengen —
        // lieber eine Karte ohne Detail als eine verworfene Zeile.
        let parent = (try? c.decodeIfPresent(String.self, forKey: .parentToolUseId)) ?? nil
        switch kind {
        case "user_text":
            // Anhänge tolerant dekodieren: ein kaputter Anhang darf die Nachricht nicht sprengen.
            self = .userText(
                text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                attachments: ((try? c.decodeIfPresent([TimelineAttachment].self, forKey: .attachments)) ?? nil) ?? [])
        case "assistant_text":
            self = .assistantText(try c.decodeIfPresent(String.self, forKey: .text) ?? "", parentToolUseId: parent)
        case "assistant_delta": self = .assistantDelta(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(try c.decodeIfPresent(String.self, forKey: .text) ?? "", parentToolUseId: parent)
        case "tool_use":
            self = .toolUse(
                toolUseId: try c.decodeIfPresent(String.self, forKey: .toolUseId) ?? "",
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                input: ((try? c.decodeIfPresent([String: JSONValue].self, forKey: .input)) ?? nil) ?? [:],
                parentToolUseId: parent)
        case "tool_result":
            self = .toolResult(
                toolUseId: try c.decodeIfPresent(String.self, forKey: .toolUseId) ?? "",
                ok: try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false,
                summary: try c.decodeIfPresent(String.self, forKey: .summary),
                output: try c.decodeIfPresent(String.self, forKey: .output),
                parentToolUseId: parent)
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
                // Input tolerant dekodieren: ein unerwarteter Wert darf die Anfrage nicht verwerfen —
                // sonst verschwände die ganze Karte und der Stream bliebe ohne Entscheidung hängen.
                input: ((try? c.decodeIfPresent([String: JSONValue].self, forKey: .input)) ?? nil) ?? [:],
                decisionReason: try c.decodeIfPresent(String.self, forKey: .decisionReason),
                blockedPath: try c.decodeIfPresent(String.self, forKey: .blockedPath),
                commandKind: try c.decodeIfPresent(String.self, forKey: .commandKind),
                // Fragen tolerant dekodieren: kaputte/fehlende Optionen dürfen die Nachricht nicht sprengen
                // (Fallback im UI = „nur ablehnbar").
                questions: (try? c.decodeIfPresent([AskQuestion].self, forKey: .questions)) ?? nil))
        case "permission_resolved":
            self = .permissionResolved(
                agentId: try agentId(),
                requestId: try c.decodeIfPresent(String.self, forKey: .requestId) ?? "")
        case "permissions_open":
            self = .permissionsOpen(
                agentId: try agentId(),
                requestIds: try c.decodeIfPresent([String].self, forKey: .requestIds) ?? [])
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
