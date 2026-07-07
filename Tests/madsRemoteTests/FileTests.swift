import Foundation
import Testing
@testable import mads_remote

/// Decoding der file-rpc-Ergebnisse (spiegeln die Bridge-Serialisierung).
struct FileRPCTypeTests {
    @Test func decodesDirNodes() throws {
        let json = #"[{"name":"a.md","path":"/r/a.md","isDir":false,"isSymlink":false},{"name":"sub","path":"/r/sub","isDir":true,"isSymlink":false}]"#
        let nodes = try JSONDecoder().decode([DirNode].self, from: Data(json.utf8))
        #expect(nodes.count == 2)
        #expect(nodes[0].name == "a.md")
        #expect(nodes[1].isDir)
    }

    @Test func decodesFileReadText() throws {
        let json = #"{"kind":"text","text":"hallo welt","mtimeMs":123,"size":4,"hash":"abc","truncated":false}"#
        let fr = try JSONDecoder().decode(FileRead.self, from: Data(json.utf8))
        guard case .text(let t) = fr else { Issue.record("nicht text"); return }
        #expect(t.text == "hallo welt")
        #expect(t.hash == "abc")
    }

    @Test func decodesWriteResults() throws {
        let saved = try JSONDecoder().decode(WriteResult.self, from: Data(#"{"kind":"saved","mtimeMs":9,"size":4,"hash":"h"}"#.utf8))
        #expect(saved == .saved(mtimeMs: 9, size: 4, hash: "h"))
        let conflict = try JSONDecoder().decode(WriteResult.self, from: Data(#"{"kind":"conflict"}"#.utf8))
        #expect(conflict == .conflict)
    }

    @Test func decodesEnvelope() throws {
        let json = #"{"ok":true,"result":[{"name":"x","path":"/x","isDir":false,"isSymlink":false}]}"#
        let env = try JSONDecoder().decode(FileRPCEnvelope<[DirNode]>.self, from: Data(json.utf8))
        #expect(env.ok)
        #expect(env.result?.count == 1)
    }
}

/// Optimistic-Concurrency-Logik des Editors (§8.4).
@MainActor
struct OpenFileTests {
    private func sample() -> OpenFile {
        OpenFile(path: "/r/a.md", file: FileText(text: "hello", mtimeMs: 1, size: 5, hash: "h0", truncated: false))
    }

    @Test func dirtyDerivedFromBuffer() {
        let f = sample()
        #expect(!f.isDirty)
        f.buffer = "hello world"
        #expect(f.isDirty)
    }

    @Test func markSavedClearsDirtyAndUpdatesBase() {
        let f = sample()
        f.buffer = "changed"
        f.markSaved(savedText: "changed", mtimeMs: 2, size: 7, hash: "h1")
        #expect(!f.isDirty)
        #expect(f.baseHash == "h1")
        #expect(f.loadedText == "changed")
    }

    /// Review-Fix (HIGH): tippt der Nutzer WÄHREND des Speicherns weiter, darf `markSaved` mit dem
    /// GESENDETEN Text den späteren Puffer nicht als gespeichert verbuchen — der Edit bleibt erhalten.
    @Test func markSavedUsesSentTextNotLaterEdits() {
        let f = sample()
        f.buffer = "v1" // gesendet wird v1
        f.buffer = "v2" // während des Speicherns getippt
        f.markSaved(savedText: "v1", mtimeMs: 2, size: 2, hash: "h1")
        #expect(f.isDirty) // v2 ≠ loadedText(v1) → weiterhin dirty (Edit NICHT verloren)
        #expect(f.loadedText == "v1")
    }

    @Test func reloadDiscardsLocalEdits() {
        let f = sample()
        f.buffer = "mine"
        f.reload(from: FileText(text: "theirs", mtimeMs: 3, size: 6, hash: "h2", truncated: false))
        #expect(f.buffer == "theirs")
        #expect(!f.isDirty)
        #expect(f.baseHash == "h2")
    }

    @Test func rebaseKeepsBufferButLiftsBase() {
        let f = sample()
        f.buffer = "mine"
        f.rebaseKeepingBuffer(FileText(text: "theirs", mtimeMs: 3, size: 6, hash: "h2", truncated: false))
        #expect(f.buffer == "mine") // Puffer bleibt
        #expect(f.isDirty) // noch ungespeichert
        #expect(f.baseHash == "h2") // Basis == Disk → nächstes Speichern überschreibt bewusst
    }
}
