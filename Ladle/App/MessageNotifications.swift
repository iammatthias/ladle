import ApronKit
import UIKit
import UserNotifications

/// Message notifications and the app badge through UserNotifications (`MessageNotifier`). Each
/// notification's identifier is the one a pushed notification of the same message has (§4.9.3),
/// and its thread is its room, so a room shows its newest and reading it closes them.
@MainActor
final class LocalMessageNotifier: MessageNotifier {
    private let center = UNUserNotificationCenter.current()

    func permission() async -> NotifyPermission {
        Self.permission(await center.notificationSettings().authorizationStatus)
    }

    func requestPermission() async -> NotifyPermission {
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        return await permission()
    }

    static func permission(_ status: UNAuthorizationStatus) -> NotifyPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    func post(_ alert: MessageAlert) async -> Bool {
        let delivered = await center.deliveredNotifications()
        // A push of the same message already shows it: it stays, rather than alerting twice.
        if delivered.contains(where: { $0.request.identifier == alert.identifier }) { return true }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.group
        content.userInfo = alert.userInfo
        do {
            try await center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
        } catch {
            return false
        }
        center.removeDeliveredNotifications(withIdentifiers: Self.inGroup(delivered, alert.group) { $0 < alert.place.messageID })
        return true
    }

    func postTest() async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "Ladle"
        content.body = "Notifications are on. Messages will look like this."
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: "ladle:test", content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    func close(group: String, through messageID: LogID) async {
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: Self.inGroup(delivered, group) { $0 <= messageID })
    }

    func setBadge(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }

    /// The identifiers of a group's notifications whose message `matches`.
    private static func inGroup(_ delivered: [UNNotification], _ group: String, _ matches: (LogID) -> Bool) -> [String] {
        delivered.compactMap { notification in
            let content = notification.request.content
            guard content.threadIdentifier == group, let key = ReminderKey(userInfo: content.userInfo), matches(key.messageID) else { return nil }
            return notification.request.identifier
        }
    }
}
