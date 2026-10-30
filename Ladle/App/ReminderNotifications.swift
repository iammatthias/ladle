import ApronKit
import UIKit
import UserNotifications

/// Reminders as local notifications (`ReminderNotifier`). Ladle asks to notify the first time a
/// reminder is set, never at launch. Nothing goes through a server: this is not push.
struct LocalReminderNotifier: ReminderNotifier {
    func schedule(_ reminder: Reminder) async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        case .denied:
            return false
        default:
            break
        }
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.userInfo = reminder.key.userInfo
        // A calendar trigger for a time already past never fires; one picked just before Set still alerts.
        let trigger: UNNotificationTrigger = reminder.due.timeIntervalSinceNow > 1
            ? UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.due),
                                            repeats: false)
            : UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: reminder.key.identifier, content: content, trigger: trigger)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func cancel(_ identifiers: [String]) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// The reminder whose notification was tapped, for `RootView` to open its message.
@MainActor
@Observable
final class ReminderRoutes {
    static let shared = ReminderRoutes()
    var opened: ReminderKey?
}

/// Takes the notification center's delegate at launch, so a tap that launched the app is not
/// lost: a reminder's notification opens its message, and one due while Ladle is open shows as a
/// banner.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let key = ReminderKey(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { ReminderRoutes.shared.opened = key }
    }
}
