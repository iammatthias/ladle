import Foundation
import Observation

/// The offer to turn notifications on, as apron-web's `NotifyPrompt`: at the first mention you'd
/// hear (who and where), or, where push works, as soon as you sign in (neither).
public struct NotifyOffer: Hashable, Sendable {
    public var from: String?
    public var room: String?

    public init(from: String? = nil, room: String? = nil) {
        self.from = from
        self.room = room
    }
}

/// What Send a test notification did, as apron-web's `NotificationTestResult`.
public enum NotifyTestResult: Sendable, Hashable {
    case sent, denied, failed
}

/// What Ladle alerts about as messages arrive on its connections, as apron-web's `arrivalAlerts`
/// with the page's notification settings: notifications from the messages each session hands
/// over (`ServerSession.onArrivals`), closed as you read (`onRead`), the app badge, the first-
/// mention offer, and the one Notifications switch. Owned by `SessionStore`.
@MainActor
@Observable
public final class MessageAlerts {
    public let settings: NotificationSettings
    public private(set) var permission: NotifyPermission = .notDetermined
    /// The offer showing, until answered.
    public private(set) var offer: NotifyOffer?
    /// Ladle is in front, so a room on screen is being read.
    @ObservationIgnored public var appActive = true
    @ObservationIgnored private let notifier: any MessageNotifier
    /// The newest message each group (`MessageAlert.group`) notified about: an older one never
    /// shows under it, as apron-web's `newestNotified`.
    @ObservationIgnored private var marks: [String: LogID] = [:]
    @ObservationIgnored private var badge: Int?

    public init(settings: NotificationSettings, notifier: any MessageNotifier) {
        self.settings = settings
        self.notifier = notifier
    }

    /// Notifications are on here: the switch, and iOS allows them.
    public var isOn: Bool { settings.enabled == true && permission == .authorized }

    /// Whether to offer notifications, as apron-web's `offersNotifications`: only until they are
    /// turned on or off here or the offer is answered, and not once iOS refuses them.
    public var offers: Bool { settings.enabled == nil && permission != .denied }

    /// Reads what iOS allows now: at launch, and coming back from Settings.
    public func refreshPermission() async {
        permission = await notifier.permission()
    }

    /// Messages that just arrived on one session's connection. Without a choice made, the first
    /// mention you'd hear offers notifications. While they are on, each room's newest mention,
    /// else its newest message, that the account's scopes cover notifies, unless notifications
    /// are silenced (paused, do not disturb) or you are reading its room.
    public func arrived(_ arrivals: [Arrival]) async {
        let heard = arrivals.filter { $0.facts.mentioned && !$0.facts.muted && !$0.facts.silenced && !reading($0) }
        if offer == nil, offers, let first = heard.first { offer = NotifyOffer(from: first.sender, room: first.room) }
        guard isOn else { return }
        let selected = arrivals.filter { arrival in
            !arrival.facts.silenced && !reading(arrival) && arrival.facts.selected(by: settings.scopes(of: arrival.account))
        }
        for arrival in Self.byRoom(selected) {
            let pushID = settings.pushID(of: arrival.account)
            let alert = MessageAlert(title: arrival.title, body: arrival.body,
                                     place: ReminderKey(server: arrival.server, roomID: arrival.roomID, messageID: arrival.messageID),
                                     pushID: pushID, mention: arrival.facts.mentioned)
            if let mark = marks[alert.group], mark >= arrival.messageID { continue }
            marks[alert.group] = arrival.messageID
            _ = await notifier.post(alert)
        }
    }

    /// One per room for a batch, as apron-web's `notificationsByRoom`: its newest mention, else its newest message.
    static func byRoom(_ arrivals: [Arrival]) -> [Arrival] {
        var chosen: [String: Arrival] = [:]
        var order: [String] = []
        for arrival in arrivals {
            let key = "\(arrival.account)\n\(arrival.roomID)"
            guard let current = chosen[key] else {
                chosen[key] = arrival
                order.append(key)
                continue
            }
            if arrival.facts.mentioned || !current.facts.mentioned { chosen[key] = arrival }
        }
        return order.compactMap { chosen[$0] }
    }

    private func reading(_ arrival: Arrival) -> Bool { appActive && arrival.facts.onScreen }

    /// You read a room through `messageID`, here or on another device: its notifications up to
    /// there close, as chat apps clear what you've seen.
    public func read(_ roomID: String, through messageID: LogID, account: String) async {
        guard let pushID = settings.pushIDs[account] else { return }
        await notifier.close(group: MessageAlert.group(pushID: pushID, roomID: roomID), through: messageID)
    }

    /// Shows `unread` as the app badge while notifications are on; off, the badge goes.
    public func setBadge(_ unread: Int) async {
        let count = isOn ? unread : 0
        guard count != badge else { return }
        badge = count
        await notifier.setBadge(count)
    }

    /// The Notifications switch, or the offer's Turn on: asks iOS from this tap, and is on only
    /// once it allows them.
    public func turnOn() async {
        offer = nil
        permission = await notifier.requestPermission()
        settings.setEnabled(permission == .authorized)
    }

    /// The switch turned off: nothing more notifies here, and the badge goes.
    public func turnOff() async {
        offer = nil
        settings.setEnabled(false)
        await setBadge(0)
    }

    /// The offer's Not now: a choice too, so it isn't offered again on this device.
    public func decline() {
        offer = nil
        settings.setEnabled(false)
    }

    /// Signed in where push works here: offer notifications without waiting for a mention, as
    /// apron-web's `offersAtSignIn` does in an installed app.
    public func offerAtSignIn() {
        if offer == nil, offers { offer = NotifyOffer() }
    }

    /// Send a test notification, through the same path as a message's.
    public func sendTest() async -> NotifyTestResult {
        if permission == .notDetermined { permission = await notifier.requestPermission() }
        guard permission == .authorized else { return .denied }
        return await notifier.postTest() ? .sent : .failed
    }
}
