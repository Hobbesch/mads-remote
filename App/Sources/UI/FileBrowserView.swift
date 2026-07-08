import SwiftUI

/// Datei-Baum einer Instanz über file-rpc (§7.5). Registriert den Pfad (idempotent, innerhalb des
/// repoRoot ohne neue Rechte) und listet ihn; Ordner navigieren tiefer, `.md`-Dateien öffnen den
/// Editor. Pfade kommen IMMER vom Host — die App originiert nie eigene Pfade (§12).
struct FileBrowserView: View {
    let session: InstanceSession
    let path: String
    let title: String

    @State private var nodes: [DirNode] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorText {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Dateizugriff fehlgeschlagen", systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.orange)
                    Text(errorText).font(.caption).foregroundStyle(.secondary)
                    Text(path).font(.caption2).monospaced().foregroundStyle(.tertiary)
                    Button("Erneut versuchen") { Task { await load() } }
                }
            } else if nodes.isEmpty {
                Text("Leer").foregroundStyle(.secondary)
            }
            ForEach(nodes) { node in
                row(node)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        errorText = nil
        switch await session.loadDir(path) {
        case .ok(let n): nodes = n
        case .failed(let e): errorText = e
        }
        loading = false
    }

    @ViewBuilder
    private func row(_ node: DirNode) -> some View {
        if node.isDir {
            NavigationLink {
                FileBrowserView(session: session, path: node.path, title: node.name)
            } label: {
                Label(node.name, systemImage: node.isSymlink ? "folder.badge.questionmark" : "folder")
            }
        } else if node.name.lowercased().hasSuffix(".md") {
            NavigationLink {
                MarkdownEditorView(session: session, path: node.path, title: node.name)
            } label: {
                Label(node.name, systemImage: "doc.text")
            }
        } else {
            Label(node.name, systemImage: "doc")
                .foregroundStyle(.secondary)
        }
    }
}
