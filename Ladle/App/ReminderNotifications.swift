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
            guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return false }
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

/// The message whose notification was tapped (a reminder's, or a message's, #203), for `RootView` to open.
@MainActor
@Observable
final class ReminderRoutes {
    static let shared = ReminderRoutes()
    var opened: ReminderKey?
    /// A tapped push's `userInfo`, whose `push_id` names the server (`NotificationSettings.place(ofPush:)`).
    var pushed: [String: String]?
}

/// Takes the notification center's delegate at launch, so a tap that launched the app is not
/// lost: a reminder's or a message's notification opens its message, revealed and highlighted
/// (apron-web #203), and one raised while Ladle is open shows as a banner. A push that comes
/// while Ladle is in front shows nothing: the connection brings the message, and alerts for it
/// itself where it should.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if PushDevice.shared.environment != nil { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushDevice.shared.token = deviceToken }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        notification.request.trigger is UNPushNotificationTrigger ? [] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if let key = ReminderKey(userInfo: userInfo) {
            await MainActor.run { ReminderRoutes.shared.opened = key }
        } else if let payload = userInfo["apron"] as? String {
            await MainActor.run { ReminderRoutes.shared.pushed = ["apron": payload] }
        }
    }
}
