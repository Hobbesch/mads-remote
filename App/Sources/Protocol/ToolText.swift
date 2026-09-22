import Foundation

/// Menschlich lesbare Beschreibung eines Werkzeug-Aufrufs — Port von `src/toolText.ts` aus mads,
/// damit Handy und Mac denselben Satz zeigen. Bash & einige Tools liefern selbst eine
/// `description` mit (genau das, was Claude Code anzeigt); für die übrigen wird aus Tool-Name +
/// Schlüssel-Argument ein Satz abgeleitet.
///
/// Bewusst zustandslos und ohne SwiftUI-Bezug, damit es ohne laufende App testbar bleibt.
enum ToolText {

    // MARK: - Aufruf-Argument und Beschreibung (Desktop: toolCommand / toolDescription)

    /// Der rohe Befehl/Pfad/Suchmuster eines Aufrufs — die „IN"-Zeile der Timeline-Karte.
    static func command(_ input: [String: JSONValue]) -> String? {
        // Reihenfolge wie im Desktop: command ?? path ?? file_path ?? pattern; `null` zählt als fehlend.
        let candidate = [input["command"], input["path"], input["file_path"], input["pattern"]]
            .compactMap { $0 }
            .first { !$0.isNull }
        if let s = candidate?.stringValue { return s }
        guard !input.isEmpty else { return nil }
        // Kein bekanntes Schlüssel-Argument → der Input selbst, gekappt (Desktop: slice(0, 600)).
        return String(JSONValue.object(input).compactJSON.prefix(600))
    }

    /// Ein Satz, der erklärt, was der Aufruf tut (Berechtigungskarte + Benachrichtigung).
    static func description(tool: String, input: [String: JSONValue]) -> String {
        // Bash (und manche Tools) liefern eine eigene Klartext-Beschreibung mit.
        if let own = input["description"]?.stringValue, !own.trimmed.isEmpty { return own.trimmed }

        let str = { (key: String) -> String? in input[key]?.stringValue }
        switch tool {
        case "Bash":
            guard let c = str("command") else { return "Shell-Befehl ausführen" }
            return "Shell-Befehl ausführen: \(firstLine(c))"
        case "Read":
            return str("file_path").map { "Datei lesen: \(basename($0))" } ?? "Datei lesen"
        case "Edit", "MultiEdit":
            return str("file_path").map { "Datei bearbeiten: \(basename($0))" } ?? "Datei bearbeiten"
        case "Write":
            return str("file_path").map { "Datei schreiben: \(basename($0))" } ?? "Datei schreiben"
        case "NotebookEdit":
            return str("notebook_path").map { "Notebook bearbeiten: \(basename($0))" } ?? "Notebook bearbeiten"
        case "Glob":
            return str("pattern").map { "Dateien suchen: \($0)" } ?? "Dateien suchen"
        case "Grep":
            return str("pattern").map { "Im Code suchen: \($0)" } ?? "Im Code suchen"
        case "WebFetch":
            return str("url").map { "Webseite abrufen: \($0)" } ?? "Webseite abrufen"
        case "WebSearch":
            return str("query").map { "Web-Suche: \($0)" } ?? "Web-Suche"
        // Der SDK benennt „Task" intern in „Agent" um — beide Namen kommen real an.
        case "Task", "Agent":
            return str("description").map { "Subagent starten: \($0)" } ?? "Subagent starten"
        case "TodoWrite":
            return "To-do-Liste aktualisieren"
        default:
            return "\(tool) ausführen"
        }
    }

    // MARK: - Teil-Agenten (Desktop: subAgents.ts)

    private static let detailMax = 110

    /// Name des Teil-Agenten, den ein `Task`/`Agent`-Aufruf startet — markiert später dessen
    /// Werkzeug-Aufrufe in der Timeline („▸ Label"), damit sie nicht wie Aufrufe des Streams selbst
    /// aussehen.
    static func subAgentLabel(_ input: [String: JSONValue]) -> String {
        let str = { (key: String) -> String in (input[key]?.stringValue ?? "").trimmed }

        let description = str("description")
        if !description.isEmpty { return clip(description, detailMax) }

        let type = str("subagent_type")
        if !type.isEmpty { return type }

        let prompt = str("prompt")
        if !prompt.isEmpty {
            // Erste Zeile mit Inhalt; bei langen Briefings am Satzende kappen statt mitten im Wort.
            let line = prompt.split(separator: "\n", omittingEmptySubsequences: false)
                .first { !$0.trimmed.isEmpty }.map(String.init) ?? prompt
            return clip(firstSentence(line), 70)
        }
        return "Teil-Agent"
    }

    // MARK: - To-do-Liste (Desktop: TodoWrite → eigene Timeline-Karte)

    /// Die To-dos aus einem `TodoWrite`-Input. nil = kein brauchbarer Input (dann bleibt es eine
    /// normale Werkzeug-Karte, statt eine leere Liste zu zeigen).
    static func todos(_ input: [String: JSONValue]) -> [TodoItem]? {
        guard let raw = input["todos"]?.arrayValue else { return nil }
        return raw.compactMap { entry in
            guard let o = entry.objectValue else { return nil }
            return TodoItem(
                content: o["content"]?.stringValue ?? "",
                status: o["status"]?.stringValue ?? "pending",
                activeForm: o["activeForm"]?.stringValue)
        }
    }

    // MARK: - Helfer

    /// Letztes Pfad-Segment (Desktop: `base`).
    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Erste nicht-leere Zeile, auf 120 Zeichen gekappt (Desktop: `firstLine`).
    private static func firstLine(_ s: String) -> String {
        let line = s.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmed.isEmpty }.map(String.init) ?? s
        return line.count > 120 ? "\(line.prefix(120))…" : line
    }

    /// Bis zum ersten Satzende (`.`/`!`/`?`/`:` gefolgt von Leerraum).
    private static func firstSentence(_ s: String) -> String {
        var out = ""
        var previous: Character?
        for ch in s {
            if let p = previous, ".!?:".contains(p), ch.isWhitespace { return out }
            out.append(ch)
            previous = ch
        }
        return out
    }

    /// Leerraum zusammenziehen und auf `max` kappen (Desktop: `clip`).
    private static func clip(_ s: String, _ max: Int) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > max ? "\(flat.prefix(max))…" : flat
    }
}

/// Ein Eintrag der To-do-Liste eines Streams (Desktop: `TodoItem` in store.ts).
struct TodoItem: Sendable, Hashable {
    let content: String
    let status: String        // pending | in_progress | completed
    let activeForm: String?
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
