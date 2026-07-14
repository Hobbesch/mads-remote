import SwiftUI

/// App-Entry (docs/architecture.md §3a). SwiftUI-Lifecycle, iOS 18+, Swift 6 strict concurrency.
@main
struct MadsRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // Beim Start die Benachrichtigungs-Erlaubnis einholen + Vordergrund-Presenter setzen,
                // damit Berechtigungsfragen/Rückfragen mit Ton gemeldet werden (garantiert @MainActor).
                .task { LocalNotifications.bootstrap() }
        }
    }
}
