import Foundation

/// Spiegel des mads-Modellkatalogs (`src/modelCatalog.ts`) für die Auswahl am Gerät.
///
/// BEWUSST eine Kopie, keine Ableitung: die App spricht nur das NDJSON-Protokoll, und der Katalog
/// steht dort nirgends drin — mads schickt Modell-IDs, keine Liste wählbarer Modelle. Die Kopie ist
/// darum die einzige Möglichkeit, hier Klarnamen statt roher IDs zu zeigen.
///
/// Driftschutz: `label(for:)` fällt auf die ID zurück. Ein Modell, das mads kennt und diese Liste
/// noch nicht, erscheint also als ID — sichtbar, aber nie falsch benannt. Beim Umstellen sendet die
/// App nur die ID; welche Modelle real zulässig sind, entscheidet ohnehin mads.
struct ModelOption: Identifiable, Sendable, Hashable {
    let id: String
    let label: String
    /// Effort-Stufen, die dieses Modell unterstützt (leer = kein Effort-Regler, z. B. Haiku).
    let effort: [EffortMode]
}

enum ModelCatalog {
    private static let full: [EffortMode] = [.low, .medium, .high, .xhigh, .ultracode]

    /// Reihenfolge = Anzeige im Menü (identisch zu `MODELS` in `src/modelCatalog.ts`).
    static let models: [ModelOption] = [
        ModelOption(id: "claude-fable-5-1", label: "Fable 5.1", effort: full),
        ModelOption(id: "claude-fable-5", label: "Fable 5", effort: full),
        ModelOption(id: "claude-opus-5", label: "Opus 5", effort: full),
        ModelOption(id: "opusplan", label: "Opus+Plan", effort: full),
        ModelOption(id: "claude-opus-4-8", label: "Opus 4.8", effort: full),
        ModelOption(id: "claude-sonnet-5", label: "Sonnet 5", effort: full),
        ModelOption(id: "claude-sonnet-4-6", label: "Sonnet 4.6", effort: [.low, .medium, .high]),
        ModelOption(id: "claude-haiku-4-5", label: "Haiku 4.5", effort: []),
    ]

    /// Klarname einer Modell-ID; unbekannt → die ID selbst (siehe Driftschutz oben).
    static func label(for id: String?) -> String {
        guard let id, !id.isEmpty else { return "—" }
        return models.first { $0.id == id }?.label ?? id
    }

    /// Effort-Stufen, die das Modell unterstützt (leer = kein Regler anzeigen).
    static func effortLevels(for id: String?) -> [EffortMode] {
        guard let id else { return [] }
        return models.first { $0.id == id }?.effort ?? []
    }
}

extension EffortMode {
    /// Beschriftung wie im Mac-Picker (`EFFORT_LABEL`).
    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Xhigh"
        case .ultracode: return "Ultracode"
        }
    }
}

extension PermissionMode {
    /// Beschriftung wie im Mac-Picker (`Inspector.tsx`).
    var label: String {
        switch self {
        case .default: return "Standard — fragt immer"
        case .acceptEdits: return "Auto-Edits"
        case .plan: return "Plan"
        case .auto: return "Auto — nur Risiko fragen"
        case .bypassPermissions: return "Bypass — nie fragen"
        case .dontAsk: return "Nie fragen"
        }
    }

    /// Kurzform für die enge Statuszeile.
    var shortLabel: String {
        switch self {
        case .default: return "Standard"
        case .acceptEdits: return "Auto-Edits"
        case .plan: return "Plan"
        case .auto: return "Auto"
        case .bypassPermissions: return "Bypass"
        case .dontAsk: return "Nie fragen"
        }
    }

    /// Die Modi, die der Mac-Picker anbietet — `dontAsk` gehört zum Typ, steht dort aber nicht zur
    /// Wahl, also hier auch nicht.
    static let selectable: [PermissionMode] = [.default, .acceptEdits, .plan, .auto, .bypassPermissions]

    /// Läuft in diesem Modus Werkzeug-Arbeit OHNE Rückfrage? Treibt die Warnung im Menü — aus der
    /// Ferne ist das die Entscheidung mit der größten Tragweite.
    var runsUnattended: Bool {
        switch self {
        case .auto, .acceptEdits, .bypassPermissions, .dontAsk: return true
        case .default, .plan: return false
        }
    }
}

extension SandboxMode {
    var label: String {
        switch self {
        case .on: return "Sandbox an"
        case .targets: return "Untersuchungs-Modus"
        case .off: return "Sandbox aus (Freigang)"
        }
    }

    var shortLabel: String {
        switch self {
        case .on: return "Sandbox"
        case .targets: return "Untersuchen"
        case .off: return "Freigang"
        }
    }

    var symbol: String {
        switch self {
        case .on: return "lock.shield"
        case .targets: return "magnifyingglass.circle"
        case .off: return "lock.open.trianglebadge.exclamationmark"
        }
    }
}
