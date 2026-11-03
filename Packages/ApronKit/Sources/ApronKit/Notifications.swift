import Foundation
import Observation

/// What to notify about, as apron-web's `NOTIFY_SCOPES`: one choice for the alerts Ladle raises
/// from its own connection and for push. They are §4.9.4's wake scopes.
public enum NotifyScope: String, CaseIterable, Sendable, Identifiable {
    case mentions, replies, `private`, joined

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mentions: "Mentions"
        case .replies: "Replies to my messages"
        case .private: "All messages in private rooms"
        case .joined: "All messages in joined rooms"
        }
    }

    /// Until an account chooses: mentions, replies, and every message in a private room.
    public static let defaults: [NotifyScope] = [.mentions, .replies, .private]

    /// Stored scopes as a choice, as apron-web's `notifyScopesOf`: the known ones in order, else the defaults.
    public static func chosen(_ stored: [String]?) -> [NotifyScope] {
        let scopes = allCases.filter { stored?.contains($0.rawValue) == true }
        return scopes.isEmpty ? defaults : scopes
    }

    /// The `wake` a push registration sends (§4.9.4), as apron-web's `pushWake`: the checked
    /// scopes the server lists, or nil when it lists none, so its defaults apply.
    public static func wake(_ scopes: [NotifyScope], offered: [String]) -> [String]? {
        offered.isEmpty ? nil : scopes.map(\.rawValue).filter(offered.contains)
    }

    /// The note beside each checked scope, as apron-web's `notifyScopeNotes`: while push is on,
    /// one the server doesn't push alerts only while Ladle is open.
    public static func notes(_ scopes: [NotifyScope], offered: [String], pushOn: Bool) -> [NotifyScope: String] {
        guard pushOn, !offered.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: scopes.filter { !offered.contains($0.rawValue) }.map { ($0, "Only while open") })
    }
}

/// What a session knows about a message from someone else that just arrived on its connection.
public struct ArrivalFacts: Hashable, Sendable {
    /// Its `body.mentions` list you, or an edit added you.
    public var mentioned = false
    /// It replies to one of your messages that is loaded here.
    public var repliesToYou = false
    /// Its room, or a thread's room, is private.
    public var inPrivate = false
    /// Its room, or a thread's room, is joined.
    public var inJoined = false
    /// Its room, or a thread's room, is muted (§4.5): nothing there notifies, mentions included.
    public var muted = false
    /// Your notifications are paused, or your status is do not disturb: nothing notifies here.
    public var silenced = false
    /// Its room is on screen; with the app active, you are reading it.
    public var onScreen = false

    public init(mentioned: Bool = false, repliesToYou: Bool = false, inPrivate: Bool = false, inJoined: Bool = false,
                muted: Bool = false, silenced: Bool = false, onScreen: Bool = false) {
        self.mentioned = mentioned
        self.repliesToYou = repliesToYou
        self.inPrivate = inPrivate
        self.inJoined = inJoined
        self.muted = muted
        self.silenced = silenced
        self.onScreen = onScreen
    }

    /// Whether the checked scopes cover it, as apron-web's `inNotifyScopes`. A muted room covers nothing.
    public func selected(by scopes: [NotifyScope]) -> Bool {
        guard !muted else { return false }
        return scopes.contains { scope in
            switch scope {
            case .mentions: mentioned
            case .replies: repliesToYou
            case .private: inPrivate
            case .joined: inJoined
            }
        }
    }
}

/// A message from someone else that arrived live: what a notification about it says and opens.
public struct Arrival: Hashable, Sendable {
    public var server: UUID
    /// Whose scopes and `push_id` apply (`NotificationSettings.account`).
    public var account: String
    public var roomID: String
    public var messageID: LogID
    /// Who sent it, by name.
    public var sender: String
    /// Its room's or thread's title.
    public var room: String
    /// Its room is a private conversation named for its members.
    public var namedForMembers = false
    public var body: String
    public var facts: ArrivalFacts

    public init(server: UUID, account: String, roomID: String, messageID: LogID, sender: String, room: String,
                namedForMembers: Bool = false, body: String, facts: ArrivalFacts) {
        self.server = server
        self.account = account
        self.roomID = roomID
        self.messageID = messageID
        self.sender = sender
        self.room = room
        self.namedForMembers = namedForMembers
        self.body = body
        self.facts = facts
    }

    public var title: String { Arrival.title(sender: sender, room: room, namedForMembers: namedForMembers) }

    /// A notification's title, as apron-web's `notificationTitle`: who and where, or who alone in a
    /// private conversation named for them, where "Bram · Bram" would say it twice.
    public static func title(sender: String, room: String, namedForMembers: Bool) -> String {
        namedForMembers && room == sender ? sender : "\(sender) · \(room)"
    }

    /// A message as a notification's body, as apron-web's `notificationBody`: its text as one
    /// line of at most 180 characters, else what its embeds are, else "New message".
    public static func body(of body: JSONValue?) -> String {
        let line = MessageText.plain(body).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if line.count > 180 { return String(line.prefix(179)) + "…" }
        return line.isEmpty ? MessageText.embedsLabel(body) ?? "New message" : line
    }
}

/// A notification about a message, as `MessageNotifier` shows it: one per `push_id` and
/// `message_id` (§4.9.3), the same identifier a pushed one would have, grouped by room.
public struct MessageAlert: Hashable, Sendable {
    public var title: String
    public var body: String
    public var place: ReminderKey
    public var pushID: String
    /// It mentions you.
    public var mention: Bool

    public init(title: String, body: String, place: ReminderKey, pushID: String, mention: Bool) {
        self.title = title
        self.body = body
        self.place = place
        self.pushID = pushID
        self.mention = mention
    }

    /// apron-web's `messageNotificationTag`: a pushed notification of the same message replaces this one.
    public var identifier: String { MessageAlert.identifier(pushID: pushID, messageID: place.messageID) }
    /// apron-web's `notificationGroup`: one room of one account, which shows only its newest.
    public var group: String { MessageAlert.group(pushID: pushID, roomID: place.roomID) }

    public static func identifier(pushID: String, messageID: LogID) -> String { "apron:\(pushID):\(messageID.text)" }
    public static func group(pushID: String, roomID: String) -> String { "\(pushID):\(roomID)" }

    /// The notification's `userInfo`: the message to open (`ReminderKey`) and the account's `push_id`.
    public var userInfo: [String: String] { place.userInfo.merging(["push_id": pushID]) { $1 } }
}

/// Whether iOS lets Ladle notify.
public enum NotifyPermission: Sendable, Hashable {
    case notDetermined, authorized, denied
}

/// Shows and closes message notifications and sets the app badge: UserNotifications in the app,
/// silent in tests.
@MainActor
public protocol MessageNotifier: AnyObject {
    func permission() async -> NotifyPermission
    /// Asks iOS, from a tap; answers what it allowed.
    func requestPermission() async -> NotifyPermission
    /// Shows a notification and closes its group's notifications of older messages; one already
    /// showing for the same message (a push's) stays as it is. False when it couldn't show.
    func post(_ alert: MessageAlert) async -> Bool
    /// Shows a sample notification (Send a test notification); false when it couldn't.
    func postTest() async -> Bool
    /// Closes a room's notifications of messages up to `through` (`MessageAlert.group`).
    func close(group: String, through: LogID) async
    func setBadge(_ count: Int) async
}

/// Notifies nothing, for tests and previews; it records what it was asked.
@MainActor
public final class RecordingMessageNotifier: MessageNotifier {
    public var granted: NotifyPermission
    public private(set) var posted: [MessageAlert] = []
    public private(set) var closed: [(group: String, through: LogID)] = []
    public private(set) var badges: [Int] = []
    public private(set) var tests = 0

    public init(permission: NotifyPermission = .notDetermined) { granted = permission }

    public func permission() async -> NotifyPermission { granted }
    public func requestPermission() async -> NotifyPermission {
        if granted == .notDetermined { granted = .authorized }
        return granted
    }
    public func post(_ alert: MessageAlert) async -> Bool {
        posted.append(alert)
        return true
    }
    public func postTest() async -> Bool {
        tests += 1
        return granted == .authorized
    }
    public func close(group: String, through: LogID) async { closed.append((group, through)) }
    public func setBadge(_ count: Int) async { badges.append(count) }
}

/// Notifications on this device, kept in `notifications.json` beside `servers.json`: the one
/// Notifications switch (nil until turned on or off here, or the offer answered), what each
/// account notifies about, each account's `push_id` (§4.9.1), and the push relay.
@MainActor
@Observable
public final class NotificationSettings {
    /// The switch: nil until chosen on this device.
    public private(set) var enabled: Bool?
    public private(set) var scopes: [String: [NotifyScope]] = [:]
    public private(set) var pushIDs: [String: String] = [:]
    /// Where push registers this device's APNs token (docs/PUSH.md); nil keeps push off.
    public private(set) var relay: URL?
    /// What the relay gave this device's APNs token; nil until it answers.
    public private(set) var endpoint: RelayEndpoint?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let makePushID: () -> String

    /// `directory` nil keeps the settings in memory only.
    public init(directory: URL? = nil, makePushID: @escaping () -> String = NotificationSettings.randomPushID) {
        self.makePushID = makePushID
        fileURL = directory?.appending(path: "notifications.json")
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let json = try? JSONValue(parsing: data) else { return }
        enabled = json["on"]?.boolValue
        for (account, value) in json["scopes"]?.objectValue ?? [:] {
            scopes[account] = NotifyScope.chosen(value.arrayValue?.compactMap(\.stringValue))
        }
        for (account, value) in json["push_ids"]?.objectValue ?? [:] {
            if let id = value.stringValue { pushIDs[account] = id }
        }
        relay = json["relay"]?.stringValue.flatMap(URL.init(string:))
        endpoint = RelayEndpoint(json: json["endpoint"])
    }

    /// The account scopes and `push_id`s are kept for, as apron-web's `notifyAccount`: one per
    /// account on each server, one for its guests, whose `user_id`s change with each connection.
    public static func account(server: UUID, userID: String?, guest: Bool) -> String {
        "\(server.uuidString)\n\(guest ? "~guest" : userID ?? "~guest")"
    }

    /// 12 random bytes in base64url: 16 characters that show neither the server nor the account.
    public nonisolated static func randomPushID() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    public func scopes(of account: String) -> [NotifyScope] { scopes[account] ?? NotifyScope.defaults }

    /// Checks or unchecks a scope; the last one checked stays.
    public func set(_ scope: NotifyScope, _ on: Bool, for account: String) {
        var chosen = Set(scopes(of: account))
        if on { chosen.insert(scope) } else { chosen.remove(scope) }
        guard !chosen.isEmpty else { return }
        scopes[account] = NotifyScope.allCases.filter(chosen.contains)
        save()
    }

    /// The account's `push_id`, made and kept the first time.
    public func pushID(of account: String) -> String {
        if let id = pushIDs[account] { return id }
        let id = makePushID()
        pushIDs[account] = id
        save()
        return id
    }

    /// The account whose `push_id` this is, for a pushed notification.
    public func account(ofPushID pushID: String) -> String? {
        pushIDs.first { $0.value == pushID }?.key
    }

    /// The message a tapped push names (docs/PUSH.md: the relay puts the §4.9.3 payload's JSON
    /// text under `apron`), on the server whose account has its `push_id`; nil for a push this
    /// device doesn't know (§4.9.3: dropped).
    public func place(ofPush userInfo: [AnyHashable: Any]) -> ReminderKey? {
        guard let text = userInfo["apron"] as? String, let payload = try? JSONValue(parsing: text),
              let pushID = payload["push_id"]?.stringValue, let account = account(ofPushID: pushID),
              let server = account.split(separator: "\n").first.flatMap({ UUID(uuidString: String($0)) }),
              let roomID = payload["message"]?["room_id"]?.stringValue, let messageID = LogID(payload["message"]?["message_id"]) else { return nil }
        return ReminderKey(server: server, roomID: roomID, messageID: messageID)
    }

    public func setEnabled(_ on: Bool) {
        enabled = on
        save()
    }

    /// Forgets the scopes and `push_id`s of every account on a server, as when its record is
    /// removed; another record on the same URL keeps its own.
    public func removeAll(server: UUID) {
        let prefix = server.uuidString + "\n"
        let before = scopes.count + pushIDs.count
        scopes = scopes.filter { !$0.key.hasPrefix(prefix) }
        pushIDs = pushIDs.filter { !$0.key.hasPrefix(prefix) }
        if scopes.count + pushIDs.count != before { save() }
    }

    /// A new relay drops the endpoint the old one gave.
    public func setRelay(_ url: URL?) {
        if url != relay { endpoint = nil }
        relay = url
        save()
    }

    public func setEndpoint(_ endpoint: RelayEndpoint?) {
        self.endpoint = endpoint
        save()
    }

    private func save() {
        guard let fileURL else { return }
        var json: [String: JSONValue] = [
            "scopes": .object(scopes.mapValues { .array($0.map { .string($0.rawValue) }) }),
            "push_ids": .object(pushIDs.mapValues(JSONValue.string)),
        ]
        if let enabled { json["on"] = .bool(enabled) }
        if let relay { json["relay"] = .string(relay.absoluteString) }
        if let endpoint { json["endpoint"] = endpoint.json }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONValue.object(json).serializedData().write(to: fileURL, options: .atomic)
    }
}
