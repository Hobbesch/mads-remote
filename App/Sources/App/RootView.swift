import SwiftUI

/// Wurzel-Ansicht. P2.1: Instanz-Browser (Bonjour-Discovery). Wird in P2.x zu einer
/// NavigationSplitView (iPad) / NavigationStack (iPhone) mit Streams/Inspector ausgebaut.
struct RootView: View {
    @State private var browser = InstanceBrowser()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            InstanceListView(browser: browser)
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        // Aus dem Hintergrund zurück → Suche neu aufsetzen. `onAppear` feuert dabei NICHT (die View
        // verschwindet ja nie), und der `NWBrowser` überlebt eine Suspendierung nicht: ohne das
        // zeigt die Liste nach jedem längeren App-Wechsel den eingefrorenen Stand von vorhin.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            browser.restart()
        }
    }
}
