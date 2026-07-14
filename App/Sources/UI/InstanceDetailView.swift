import SwiftUI

/// Treibt eine `InstanceSession`: verbindet beim Erscheinen und rendert je nach Phase
/// (Verbinden → Pairing → Live-Streams → Fehler). Das ist der erste end-to-end-Flow.
struct InstanceDetailView: View {
    @State private var session: InstanceSession
    @Environment(\.scenePhase) private var scenePhase

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
                    // „Neu koppeln" verwirft den (evtl. widerrufenen) Token → PairingView (frische PIN).
                    // Das ist der Ausweg aus „Gerät widerrufen"; „Erneut versuchen" allein wiederholte
                    // nur den toten Token.
                    Button("Neu koppeln") { Task { await session.repair() } }
                        .buttonStyle(.borderedProminent)
                    Button("Erneut versuchen") { Task { await session.start() } }
                }
            }
        }
        .navigationTitle(session.instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.start() }
        // KEIN `onDisappear { disconnect }` — das feuerte im NavigationStack auch beim PUSH eines
        // Streams (StreamDetailView) und kappte die Verbindung → keine Live-Events im Detail. Die
        // Verbindung bleibt jetzt übers interne Navigieren offen; beim VERLASSEN der Instanz (Pop)
        // dealloziert die Session → SocketConnection.deinit schließt die URLSession sauber.
        .onChange(of: scenePhase) { _, newPhase in
            // Vordergrund → neu verbinden (iOS hat den WS im Hintergrund gekappt, §8.5).
            if newPhase == .active { Task { await session.reconnect() } }
        }
    }
}
