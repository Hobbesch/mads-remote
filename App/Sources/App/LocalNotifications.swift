import UserNotifications

/// Lokale Benachrichtigungen (mit Ton), wenn der Mac eine Berechtigungsfrage oder Rückfrage schickt —
/// damit man aus der Ferne merkt, dass eine Entscheidung ansteht, auch wenn die App im Hintergrund
/// liegt. Funktioniert, solange die WSS-Verbindung noch lebt (iOS hält sie ~30 s nach dem Wegwischen);
/// für den komplett-geschlossenen Fall bräuchte es echten Push (APNs) — bewusst nicht Teil hiervon.
enum LocalNotifications {
    /// Beim App-Start: Vordergrund-Presenter setzen + einmal Erlaubnis (Banner + Ton) einholen.
    @MainActor static func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = ForegroundPresenter.shared
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Eine Benachrichtigung mit Ton posten. `identifier` = requestId → dieselbe Anfrage wird nicht
    /// doppelt gemeldet, und beim Beantworten lässt sie sich gezielt entfernen (`clear`).
    static func notify(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "mads-permission"
        // Es wartet jemand auf eine Entscheidung → zeitkritisch. Durchbricht Fokus/Stumm nur, wenn in
        // Xcode das „Time Sensitive Notifications"-Entitlement aktiv ist; sonst degradiert iOS still
        // auf eine normale Benachrichtigung (Banner + Ton, wenn nicht stumm) — kein Fehler.
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Eine beantwortete/entfernte Anfrage aus dem Notification-Center räumen (kein toter Prompt).
    static func clear(identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

/// Zeigt Benachrichtigungen auch im VORDERGRUND (Ton + Banner), damit ein Prompt nicht untergeht,
/// während man gerade in einem anderen Stream/View ist.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ForegroundPresenter()
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
