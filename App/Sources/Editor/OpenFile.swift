import Observation

/// Geöffnete Markdown-Datei mit Optimistic-Concurrency (docs/architecture.md §8.4). Beim Öffnen
/// werden `{mtimeMs,size,hash}` gemerkt und beim Speichern mitgeschickt; die Bridge meldet `saved`
/// oder `conflict` (Datei driftete auf dem Mac). `isDirty` ist abgeleitet (Puffer ≠ geladener Text).
@Observable
@MainActor
final class OpenFile {
    let path: String
    private(set) var loadedText: String
    var buffer: String
    private(set) var baseMtimeMs: Double
    private(set) var baseSize: Int
    private(set) var baseHash: String
    private(set) var truncated: Bool

    var isDirty: Bool { buffer != loadedText }

    init(path: String, file: FileText) {
        self.path = path
        self.loadedText = file.text
        self.buffer = file.text
        self.baseMtimeMs = file.mtimeMs
        self.baseSize = file.size
        self.baseHash = file.hash
        self.truncated = file.truncated
    }

    /// Nach erfolgreichem Speichern: geladener Stand = der TATSÄCHLICH gesendete Text (`savedText`),
    /// NICHT der aktuelle Puffer — sonst würden während des Speicher-Roundtrips getippte Zeichen
    /// still als „gespeichert" verbucht und wären verloren. So bleibt `isDirty` korrekt.
    func markSaved(savedText: String, mtimeMs: Double, size: Int, hash: String) {
        loadedText = savedText
        baseMtimeMs = mtimeMs
        baseSize = size
        baseHash = hash
    }

    /// Konflikt-Auflösung „Neu laden": Disk-Stand übernehmen, lokale Änderungen verwerfen.
    func reload(from file: FileText) {
        loadedText = file.text
        buffer = file.text
        baseMtimeMs = file.mtimeMs
        baseSize = file.size
        baseHash = file.hash
        truncated = file.truncated
    }

    /// Konflikt-Auflösung „Meine Version behalten/Überschreiben": Puffer unverändert lassen, aber die
    /// Basis auf den aktuellen Disk-Stand heben — ein erneutes Speichern überschreibt dann bewusst.
    func rebaseKeepingBuffer(_ file: FileText) {
        baseMtimeMs = file.mtimeMs
        baseSize = file.size
        baseHash = file.hash
    }
}
