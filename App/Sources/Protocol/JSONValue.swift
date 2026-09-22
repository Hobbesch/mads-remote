import Foundation

/// Ein beliebiger JSON-Wert — für die `Record<string, unknown>`-Felder des mads-Protokolls
/// (`tool_use.input`, `permission_request.input`). Die App interpretiert diese Felder nicht
/// typisiert, muss sie aber ANZEIGEN können: ohne den Input bleibt von einem Werkzeug-Aufruf nur
/// sein Name übrig („Bash"), und genau das machte Timeline und Berechtigungskarte inhaltslos.
///
/// Die Werte sind am Mac bereits redigiert (`redactForEgress` im Sidecar, vor stdout/Bridge) — die
/// App zeigt also dasselbe wie der Desktop und bekommt keine Secrets zu sehen, die dort verborgen
/// wären.
enum JSONValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool VOR Double: JSONDecoder liefert für `true` keinen Double, aber die Reihenfolge hält
        // die Absicht explizit (und schützt vor einer künftigen, laxeren Decoder-Implementierung).
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unbekannter JSON-Wert")
    }
}

extension JSONValue {
    /// Der String-Wert — oder nil, wenn es kein String ist (wie `typeof x === "string"` im Desktop).
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// `null` unterscheidet sich von „Feld fehlt" nicht, wo der Desktop `??` nutzt — beides gilt
    /// als „nicht gesetzt".
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Kompakte JSON-Schreibweise für den Fallback in `ToolText.command` (Desktop: `JSON.stringify`).
    /// Schlüssel SORTIERT statt in Einfüge-Reihenfolge: Swift-Dictionaries haben keine, und so ist
    /// die Ausgabe deterministisch (und damit testbar).
    var compactJSON: String {
        switch self {
        case .string(let s): return Self.quoted(s)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .number(let d):
            // Ganzzahlen ohne „.0" schreiben — sonst liest sich jeder Zähler als Fliesskommazahl.
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .array(let a):
            return "[" + a.map(\.compactJSON).joined(separator: ",") + "]"
        case .object(let o):
            let body = o.keys.sorted().map { "\(Self.quoted($0)):\(o[$0]!.compactJSON)" }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }
}
