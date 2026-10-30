import Foundation
import Observation
import Synchronization

/// The message a reminder is for: one per server, room and message.
public struct ReminderKey: Hashable, Sendable {
    public var server: UUID
    public var roomID: String
    public var messageID: LogID

    public init(server: UUID, roomID: String, messageID: LogID) {
        self.server = server
        self.roomID = roomID
        self.messageID = messageID
    }

    /// The local notification's identifier, so removing the reminder cancels it.
    public var identifier: String { "reminder:\(server.uuidString):\(messageID.text):\(roomID)" }

    /// The notification's `userInfo`, which a tap reads back to open the message.
    public var userInfo: [String: String] { ["server": server.uuidString, "room": roomID, "message": messageID.text] }

    /// The key a tapped notification's `userInfo` names, or nil for any other notification.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let server = (userInfo["server"] as? String).flatMap(UUID.init(uuidString:)), let roomID = userInfo["room"] as? String,
              let messageID = (userInfo["message"] as? String).flatMap(LogID.init) else { return nil }
        self.init(server: server, roomID: roomID, messageID: messageID)
    }
}

/// A reminder about a message, kept on this device and delivered as a local notification at
/// `due`: never sent to a server. `title` and `body` are the notification's words.
public struct Reminder: Hashable, Sendable, Codable {
    public var key: ReminderKey
    public var due: Date
    public var title: String
    public var body: String

    public init(key: ReminderKey, due: Date, title: String, body: String) {
        self.key = key
        self.due = due
        self.title = title
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case server, room, message, due, title, body }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decode(String.self, forKey: .message)
        guard let messageID = LogID(message) else {
            throw DecodingError.dataCorruptedError(forKey: .message, in: container, debugDescription: "not a message id")
        }
        key = ReminderKey(server: try container.decode(UUID.self, forKey: .server), roomID: try container.decode(String.self, forKey: .room),
                          messageID: messageID)
        due = try container.decode(Date.self, forKey: .due)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.server, forKey: .server)
        try container.encode(key.roomID, forKey: .room)
        try container.encode(key.messageID.text, forKey: .message)
        try container.encode(due, forKey: .due)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
    }

    /// What the message's row says: "Due in 5 min", "Due in 1 hr", "Due in 2 days", then
    /// "Due now" once `due` has passed. Minutes round up, hours and days to the nearest.
    public static func label(due: Date, now: Date) -> String {
        let seconds = due.timeIntervalSince(now)
        guard seconds > 0 else { return "Due now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "Due in \(minutes) min" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return "Due in \(hours) hr" }
        let days = Int((seconds / 86_400).rounded())
        return days == 1 ? "Due in 1 day" : "Due in \(days) days"
    }
}

/// The times the message menu's Remind Me offers, besides a custom one.
public enum ReminderChoice: CaseIterable, Sendable {
    case in5Minutes, in30Minutes, in1Hour, in3Hours, tomorrow

    public var title: String {
        switch self {
        case .in5Minutes: "In 5 Minutes"
        case .in30Minutes: "In 30 Minutes"
        case .in1Hour: "In 1 Hour"
        case .in3Hours: "In 3 Hours"
        case .tomorrow: "Tomorrow"
        }
    }

    /// When it is due, picked at `now`; Tomorrow is 09:00 the next day in `calendar`'s time zone.
    public func due(after now: Date, calendar: Calendar) -> Date {
        switch self {
        case .in5Minutes: now.addingTimeInterval(5 * 60)
        case .in30Minutes: now.addingTimeInterval(30 * 60)
        case .in1Hour: now.addingTimeInterval(3600)
        case .in3Hours: now.addingTimeInterval(3 * 3600)
        case .tomorrow:
            calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: now) ?? now) ?? now
        }
    }
}

/// Delivers reminders as local notifications. The app's is UserNotifications; tests and the
/// renderer use their own.
public protocol ReminderNotifier: Sendable {
    /// Schedules the reminder's notification, replacing one with the same identifier, and asks
    /// for permission the first time. False when the user does not let the app notify.
    func schedule(_ reminder: Reminder) async -> Bool
    func cancel(_ identifiers: [String]) async
}

/// For tests and the renderer: notifies nothing, and says it may.
public struct SilentReminderNotifier: ReminderNotifier {
    public init() {}
    public func schedule(_ reminder: Reminder) async -> Bool { true }
    public func cancel(_ identifiers: [String]) async {}
}

/// Where reminders are kept on this device.
public protocol ReminderStore: Sendable {
    func load() -> [Reminder]
    func save(_ reminders: [Reminder])
}

/// `reminders.json` in the store's directory, beside `servers.json`: a list written whole and
/// atomically. A file that cannot be read is treated as empty.
public struct FileReminderStore: ReminderStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "reminders.json")
    }

    public func load() -> [Reminder] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Reminder].self, from: data)) ?? []
    }

    public func save(_ reminders: [Reminder]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(reminders) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// For tests and previews.
public final class InMemoryReminderStore: ReminderStore {
    private let kept: Mutex<[Reminder]>

    public init(_ reminders: [Reminder] = []) { kept = Mutex(reminders) }

    public func load() -> [Reminder] { kept.withLock { $0 } }
    public func save(_ reminders: [Reminder]) { kept.withLock { $0 = reminders } }
}

/// The reminders on this device, one per message, kept in a `ReminderStore` and delivered by a
/// `ReminderNotifier`. Setting one replaces the message's earlier one; removing one cancels its
/// notification.
@MainActor
@Observable
public final class Reminders {
    public private(set) var byKey: [ReminderKey: Reminder]
    @ObservationIgnored private let store: any ReminderStore
    @ObservationIgnored private let notifier: any ReminderNotifier

    public init(store: any ReminderStore, notifier: any ReminderNotifier) {
        self.store = store
        self.notifier = notifier
        byKey = Dictionary(store.load().map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    public subscript(key: ReminderKey) -> Reminder? { byKey[key] }

    /// Keeps the reminder and schedules its notification. Returns false when the user does not
    /// let the app notify: the reminder is kept, and shows on its message, without an alert.
    @discardableResult
    public func set(_ reminder: Reminder) async -> Bool {
        byKey[reminder.key] = reminder
        save()
        return await notifier.schedule(reminder)
    }

    public func remove(_ key: ReminderKey) async {
        guard byKey.removeValue(forKey: key) != nil else { return }
        save()
        await notifier.cancel([key.identifier])
    }

    /// Removes every reminder for a server, as when the server is removed.
    public func removeAll(server: UUID) async {
        let gone = byKey.keys.filter { $0.server == server }
        guard !gone.isEmpty else { return }
        for key in gone { byKey[key] = nil }
        save()
        await notifier.cancel(gone.map(\.identifier))
    }

    private func save() {
        store.save(byKey.values.sorted { $0.due < $1.due })
    }
}

extension ServerSession {
    /// The reminder key for one of this server's messages.
    public func reminderKey(for message: MessageSnapshot) -> ReminderKey {
        ReminderKey(server: record.id, roomID: message.roomID, messageID: message.messageID)
    }

    /// A reminder about `message` at `due`: the notification's title names the sender and the
    /// room, and its body is the message's first line.
    public func reminder(for message: MessageSnapshot, due: Date) -> Reminder {
        let room = (store.room(message.roomID)?.parentRoomID == nil ? "#" : "") + title(of: message.roomID)
        let preview = MessageText.snippet(message.body)
        return Reminder(key: reminderKey(for: message), due: due,
                        title: "\(displayName(for: message.from)) in \(room)",
                        body: preview.isEmpty ? "Attachment" : preview)
    }
}

/// Remind Me in one timeline: the reminder on each of the session's messages, setting and
/// removing one, and whether to say that notifications are off. That notice shows from the
/// first refusal until it is dismissed, in this timeline only.
@MainActor
@Observable
public final class MessageReminders {
    @ObservationIgnored public let session: ServerSession
    @ObservationIgnored public let reminders: Reminders
    /// The user did not let the app notify when a reminder was last set here.
    public var notificationsOff = false

    public init(session: ServerSession, reminders: Reminders) {
        self.session = session
        self.reminders = reminders
    }

    /// Custom…'s first time: an hour from `now`.
    public static func customStart(after now: Date) -> Date { now.addingTimeInterval(3600) }

    public func reminder(on message: MessageSnapshot) -> Reminder? {
        reminders[session.reminderKey(for: message)]
    }

    /// Sets the message's reminder, replacing an earlier one, and notes a refusal to notify.
    @discardableResult
    public func remind(_ message: MessageSnapshot, at due: Date) -> Task<Void, Never> {
        let reminder = session.reminder(for: message, due: due)
        return Task {
            if !(await reminders.set(reminder)) { notificationsOff = true }
        }
    }

    @discardableResult
    public func forget(_ message: MessageSnapshot) -> Task<Void, Never> {
        let key = session.reminderKey(for: message)
        return Task { await reminders.remove(key) }
    }
}
