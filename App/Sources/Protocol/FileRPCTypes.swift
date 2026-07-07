import Foundation

/// Codable-Spiegel der file-rpc-Ergebnisse der Bridge (src-tauri/src/files.rs, camelCase).

/// Verzeichnis-Eintrag (`read_dir`).
struct DirNode: Codable, Identifiable, Sendable, Hashable {
    let name: String
    let path: String
    let isDir: Bool
    let isSymlink: Bool
    var id: String { path }
}

/// Text-Datei-Inhalt + Optimistic-Concurrency-Basis (`read_file`, kind == "text").
struct FileText: Sendable, Equatable {
    let text: String
    let mtimeMs: Double
    let size: Int
    let hash: String
    let truncated: Bool
}

/// `read_file`-Ergebnis: Core entscheidet Text vs. Binär.
enum FileRead: Sendable {
    case text(FileText)
    case binary(mtimeMs: Double, size: Int, hash: String, truncated: Bool)
}

extension FileRead: Decodable {
    private enum K: String, CodingKey { case kind, text, mtimeMs, size, hash, truncated }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let mtimeMs = try c.decodeIfPresent(Double.self, forKey: .mtimeMs) ?? 0
        let size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        let hash = try c.decodeIfPresent(String.self, forKey: .hash) ?? ""
        let truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        if try c.decode(String.self, forKey: .kind) == "text" {
            self = .text(FileText(
                text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                mtimeMs: mtimeMs, size: size, hash: hash, truncated: truncated))
        } else {
            self = .binary(mtimeMs: mtimeMs, size: size, hash: hash, truncated: truncated)
        }
    }
}

/// `write_file`-Ergebnis: gespeichert oder Konflikt (Optimistic-Concurrency).
enum WriteResult: Sendable, Equatable {
    case saved(mtimeMs: Double, size: Int, hash: String)
    case conflict
}

extension WriteResult: Decodable {
    private enum K: String, CodingKey { case kind, mtimeMs, size, hash }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        if try c.decode(String.self, forKey: .kind) == "saved" {
            self = .saved(
                mtimeMs: try c.decodeIfPresent(Double.self, forKey: .mtimeMs) ?? 0,
                size: try c.decodeIfPresent(Int.self, forKey: .size) ?? 0,
                hash: try c.decodeIfPresent(String.self, forKey: .hash) ?? "")
        } else {
            self = .conflict
        }
    }
}

// MARK: - file-rpc-reply-Hüllen ({ ok, result, error })

struct OkEnvelope: Decodable { let ok: Bool; let error: String? }
struct FileRPCEnvelope<T: Decodable>: Decodable { let ok: Bool; let result: T?; let error: String? }
