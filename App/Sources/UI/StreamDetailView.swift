import SwiftUI

/// Chat-/Timeline-Ansicht eines Streams mit Composer (send_input) + Aktions-Menü (P3.1). Beobachtet
/// den `InstanceStore` und schlägt den Stream per id nach → aktualisiert live.
struct StreamDetailView: View {
    let session: InstanceSession
    let streamId: String

    @State private var draft = ""
    @State private var confirmCreatePR = false
    @State private var confirmIntegrate = false
    @State private var confirmStop = false

    private var store: InstanceStore { session.store }
    private var stream: Stream? { store.streams[streamId] }

    var body: some View {
        VStack(spacing: 0) {
            timeline
            composer
        }
        .navigationTitle(streamTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { actionMenu } }
        .confirmationDialog("Pull Request erstellen?", isPresented: $confirmCreatePR, titleVisibility: .visible) {
            Button("PR erstellen") { Task { await session.streamAction("create_pr", agentId: streamId) } }
        } message: { Text("Erstellt einen außen sichtbaren Pull Request aus diesem Stream.") }
        .confirmationDialog("Integrieren (nach main mergen)?", isPresented: $confirmIntegrate, titleVisibility: .visible) {
            Button("Integrieren", role: .destructive) { Task { await session.streamAction("integrate_pr", agentId: streamId) } }
        } message: { Text("Merged diesen Stream nach main. Irreversibel.") }
        .confirmationDialog("Stream stoppen?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stoppen", role: .destructive) { Task { await session.stopAgent(agentId: streamId) } }
        }
    }

    private var timeline: some View {
        ScrollView {
            if let stream {
                VStack(alignment: .leading, spacing: 10) {
                    header(stream)
                    ForEach(stream.timeline) { item in
                        TimelineItemView(item: item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            } else {
                Text("Stream nicht mehr vorhanden").foregroundStyle(.secondary).padding()
            }
        }
    }

    private var streamTitle: String { stream?.label ?? streamId }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Nachricht an den Stream …", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                let text = draft
                Task {
                    // Feld erst leeren, wenn die Nachricht wirklich rausging (sonst geht sie verloren).
                    if await session.sendInput(agentId: streamId, text: text) {
                        draft = ""
                    }
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(8)
        .background(.bar)
    }

    private var actionMenu: some View {
        Menu {
            Button { Task { await session.interrupt(agentId: streamId) } } label: {
                Label("Unterbrechen", systemImage: "stop.circle")
            }
            Button { Task { await session.streamAction("sync_branch", agentId: streamId) } } label: {
                Label("Sync (rebase)", systemImage: "arrow.triangle.2.circlepath")
            }
            Button { Task { await session.streamAction("gate_task", agentId: streamId) } } label: {
                Label("Gate ausführen", systemImage: "checkmark.seal")
            }
            Button { confirmCreatePR = true } label: {
                Label("PR erstellen", systemImage: "arrow.triangle.pull")
            }
            Divider()
            Button(role: .destructive) { confirmIntegrate = true } label: {
                Label("Integrieren", systemImage: "arrow.triangle.merge")
            }
            Button(role: .destructive) { confirmStop = true } label: {
                Label("Stream stoppen", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func header(_ stream: Stream) -> some View {
        HStack(spacing: 8) {
            StatusDot(status: stream.status)
            Text(String(describing: stream.status)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(stream.numTurns) Turns · $\(String(format: "%.2f", stream.costUsd))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

private struct TimelineItemView: View {
    let item: TimelineItem

    var body: some View {
        switch item.kind {
        case .assistant(let text):
            Text(text)
                .padding(10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(let text):
            Text(text).font(.callout).italic().foregroundStyle(.secondary)
        case .tool(_, let name, let ok):
            HStack(spacing: 6) {
                Image(systemName: toolIcon(ok)).foregroundStyle(toolColor(ok))
                Text(name).font(.system(.footnote, design: .monospaced))
            }
        case .notice(let text):
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func toolIcon(_ ok: Bool?) -> String {
        switch ok {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "xmark.circle.fill"
        case .none: return "circle.dotted"
        }
    }
    private func toolColor(_ ok: Bool?) -> Color {
        switch ok {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }
}
