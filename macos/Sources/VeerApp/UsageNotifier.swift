import Foundation
import UserNotifications

/// Posts usage alerts as system notifications, asking for permission the first time.
enum UsageNotifier {
    static func post(_ alert: (title: String, body: String)) {
        // Notifications need an app bundle; `swift run` and tests have none.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let (title, body) = alert
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
