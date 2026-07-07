import SwiftUI

/// Wurzel-Ansicht. P2.1: Instanz-Browser (Bonjour-Discovery). Wird in P2.x zu einer
/// NavigationSplitView (iPad) / NavigationStack (iPhone) mit Streams/Inspector ausgebaut.
struct RootView: View {
    @State private var browser = InstanceBrowser()

    var body: some View {
        NavigationStack {
            InstanceListView(browser: browser)
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }
}
