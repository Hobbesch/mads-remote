import SwiftUI

/// Live-Streams-Übersicht einer verbundenen Instanz (spiegelt den `InstanceStore`) mit dem
/// prominenten Permission-Banner darüber.
struct StreamsView: View {
    let session: InstanceSession

    private var store: InstanceStore { session.store }

    var body: some View {
        VStack(spacing: 0) {
            if !store.permissions.isEmpty {
                ScrollView { PermissionBanner(session: session) }
                    .frame(maxHeight: 220)
            }
            List {
                if let project = store.project {
                    Section("Projekt") {
                        Text("\(project.owner)/\(project.repo)").font(.headline)
                        NavigationLink {
                            FileBrowserView(session: session, path: project.repoRoot, title: "Dateien")
                        } label: {
                            Label("Dateien durchsuchen", systemImage: "folder")
                        }
                    }
                }
                Section("Streams") {
                    if store.order.isEmpty {
                        Text("Keine aktiven Streams").foregroundStyle(.secondary)
                    } else {
                        ForEach(store.order, id: \.self) { id in
                            if let stream = store.streams[id] {
                                NavigationLink {
                                    StreamDetailView(session: session, streamId: id)
                                } label: {
                                    StreamRow(stream: stream)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct StreamRow: View {
    let stream: Stream

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                StatusDot(status: stream.status)
                Text(stream.id).font(.subheadline).bold()
                Spacer()
                if stream.costUsd > 0 {
                    Text(String(format: "$%.2f", stream.costUsd)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let step = stream.currentStep {
                Text(step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                if stream.behind > 0 { Label("\(stream.behind)", systemImage: "arrow.down").font(.caption2) }
                if stream.ahead > 0 { Label("\(stream.ahead)", systemImage: "arrow.up").font(.caption2) }
                if stream.dirty { Image(systemName: "pencil").font(.caption2) }
                if let pr = stream.pr { Label("#\(pr.number)", systemImage: "arrow.triangle.pull").font(.caption2) }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct StatusDot: View {
    let status: AgentStatus
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    private var color: Color {
        switch status {
        case .running, .starting: return .green
        case .waitingInput, .paused, .queued: return .yellow
        case .escalation, .error: return .red
        case .done: return .gray
        }
    }
}
