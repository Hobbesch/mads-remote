import SwiftUI

/// Treibt eine `InstanceSession`: verbindet beim Erscheinen und rendert je nach Phase
/// (Verbinden → Pairing → Live-Streams → Fehler). Das ist der erste end-to-end-Flow.
struct InstanceDetailView: View {
    @State private var session: InstanceSession

    init(instance: DiscoveredInstance) {
        _session = State(initialValue: InstanceSession(instance: instance))
    }

    var body: some View {
        Group {
            switch session.phase {
            case .idle, .resolving, .connecting:
                ProgressView("Verbinde …")
            case .needsPairing:
                PairingView(session: session)
            case .live:
                StreamsView(session: session)
            case .failed(let reason):
                ContentUnavailableView {
                    Label("Nicht verbunden", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Erneut versuchen") { Task { await session.start() } }
                }
            }
        }
        .navigationTitle(session.instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.start() }
        .onDisappear { Task { await session.disconnect() } }
    }
}
