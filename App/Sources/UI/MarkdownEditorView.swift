import SwiftUI

/// Markdown-Quell-Editor über file-rpc mit Optimistic-Concurrency + Konflikt-Sheet (§8.4). Vorschau
/// vorerst als inline-`AttributedString` (rich Preview / CodeMirror-6-in-WKWebView folgt, OE-R7).
struct MarkdownEditorView: View {
    let session: InstanceSession
    let path: String
    let title: String

    @State private var file: OpenFile?
    @State private var loadError: String?
    @State private var saving = false
    @State private var saveError: String?
    @State private var conflict: ConflictContext?
    @State private var showPreview = false

    private struct ConflictContext: Identifiable {
        let id = UUID()
        let disk: FileText
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { await load() }
            .sheet(item: $conflict) { ctx in conflictSheet(ctx.disk) }
            .alert("Speichern fehlgeschlagen", isPresented: alertBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        if let file {
            if showPreview {
                ScrollView {
                    Text(preview(file.buffer))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                TextEditor(text: Binding(get: { file.buffer }, set: { file.buffer = $0 }))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } else if let loadError {
            ContentUnavailableView("Konnte Datei nicht laden", systemImage: "doc.questionmark", description: Text(loadError))
        } else {
            ProgressView()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showPreview.toggle() } label: {
                Image(systemName: showPreview ? "pencil" : "eye")
            }
            .disabled(file == nil)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await save() } } label: {
                if saving { ProgressView() } else { Text("Speichern") }
            }
            .disabled(!(file?.isDirty ?? false) || saving)
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    // MARK: - Aktionen

    private func load() async {
        guard file == nil else { return }
        switch await session.readFile(path) {
        case .text(let t)?: file = OpenFile(path: path, file: t)
        case .binary?: loadError = "Keine Textdatei."
        case .none: loadError = session.store.lastError ?? "Datei nicht erreichbar."
        }
    }

    private func save() async {
        guard let file, file.isDirty, !saving else { return }
        saving = true
        defer { saving = false }
        let sent = file.buffer // erfassen, was WIRKLICH gesendet wird (Puffer kann während des await driften)
        switch await session.writeFile(
            path: file.path, content: sent,
            baseMtimeMs: file.baseMtimeMs, baseSize: file.baseSize, baseHash: file.baseHash
        ) {
        case .saved(let m, let s, let h)?:
            file.markSaved(savedText: sent, mtimeMs: m, size: s, hash: h)
        case .conflict?:
            if case .text(let disk)? = await session.readFile(file.path) {
                conflict = ConflictContext(disk: disk)
            } else {
                saveError = "Konflikt erkannt, aber der aktuelle Stand ließ sich nicht laden — bitte die Datei neu öffnen."
            }
        case .none:
            // Echten Grund zeigen (Server-Fehler wurde in store.lastError vermerkt), nicht „nicht gesendet" raten.
            saveError = session.store.lastError ?? "Speichern fehlgeschlagen."
        }
    }

    @ViewBuilder private func conflictSheet(_ disk: FileText) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Die Datei wurde auf dem Mac geändert, seit du sie geöffnet hast.")
                    .font(.callout)
                Button("Neu laden (meine Änderungen verwerfen)") {
                    file?.reload(from: disk)
                    conflict = nil
                }
                Button("Meine Version behalten") {
                    file?.rebaseKeepingBuffer(disk) // dirty bleibt; nächstes Speichern überschreibt bewusst
                    conflict = nil
                }
                Button("Jetzt überschreiben", role: .destructive) {
                    file?.rebaseKeepingBuffer(disk)
                    conflict = nil
                    Task { await save() } // Basis == Disk → speichert jetzt durch
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Konflikt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { conflict = nil } } }
        }
        .presentationDetents([.medium])
    }

    private func preview(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}
