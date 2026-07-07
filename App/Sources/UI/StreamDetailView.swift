import SwiftUI

/// Chat-/Timeline-Ansicht eines Streams. Beobachtet den `InstanceStore` und schlägt den Stream per
/// id nach → aktualisiert live, wenn neue Events eintreffen.
struct StreamDetailView: View {
    let store: InstanceStore
    let streamId: String

    private var stream: Stream? { store.streams[streamId] }

    var body: some View {
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
        .navigationTitle(streamId)
        .navigationBarTitleDisplayMode(.inline)
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
            Text(text)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
        case .tool(_, let name, let ok):
            HStack(spacing: 6) {
                Image(systemName: toolIcon(ok))
                    .foregroundStyle(toolColor(ok))
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
