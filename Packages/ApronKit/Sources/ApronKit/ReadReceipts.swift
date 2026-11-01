import Foundation
import Observation

/// Read Receipts on this device, as apron-web's `ReceiptSettings` (#187): on by default, for
/// every server, kept in `read-receipts.json` beside `servers.json`. Off, this device neither
/// sends your read cursor in private rooms, where the server would show it to the other
/// members, nor shows theirs.
@MainActor
@Observable
public final class ReceiptSettings {
    public private(set) var isOn = true
    /// Called when Read Receipts come back on (`SessionStore` sends the cursors held back).
    @ObservationIgnored public var onTurnedOn: (@MainActor () -> Void)?
    @ObservationIgnored private let fileURL: URL?

    /// `directory` nil keeps the choice in memory only.
    public init(directory: URL? = nil) {
        fileURL = directory?.appending(path: "read-receipts.json")
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let json = try? JSONValue(parsing: data) else { return }
        isOn = json["on"]?.boolValue ?? true
    }

    public func set(_ on: Bool) {
        let was = isOn
        isOn = on
        if on, !was { onTurnedOn?() }
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONValue.object(["on": .bool(on)]).serializedData().write(to: fileURL, options: .atomic)
    }
}

/// Someone's face under a message they have read through (`ServerSession.receipts`).
public struct Reader: Hashable, Sendable {
    public var user: UserObject
    public var name: String
}

extension ServerInfo {
    /// The server shows a private room's members each other's read cursors:
    /// `ext.settings.read_receipts` is `"private"` under `ext:settings` (shazow/apron#102).
    public var showsReadReceipts: Bool {
        has("ext:settings") && ext?["settings"]?["read_receipts"]?.stringValue == "private"
    }
}

extension ServerSession {
    /// Preferences > Profile offers Read Receipts: the server shows them, and this account
    /// can sign back in (apron-web shows it to a registered session only).
    public var offersReadReceipts: Bool { server?.showsReadReceipts == true && resumable }

    /// Your cursor in `roomID` stays on this device: Read Receipts are off, and the server
    /// would show it to the private room's members.
    func withholdsRead(_ roomID: String) -> Bool {
        !receiptSettings.isOn && server?.showsReadReceipts == true && store.room(roomID)?.isPrivate == true
    }

    /// Read Receipts came back on: how far you read while they were off goes now, as it would
    /// have, as apron-web's `setReadReceipts(true)`.
    public func readReceiptsTurnedOn() async {
        guard receiptSettings.isOn, status == .signedIn, resumable, let server, server.keepsReadCursors, server.showsReadReceipts,
              let connection else { return }
        for (roomID, cursor) in readCursors.sorted(by: { codePointLess($0.key, $1.key) })
        where store.room(roomID)?.isPrivate == true && readSent[roomID] != cursor {
            readSent[roomID] = cursor
            try? await connection.notify("activity", params: ["room_id": .string(roomID), "read_message_id": cursor.json])
        }
    }

    /// Read receipts in a private room, as apron-web's `receiptsByMessage`: each other member
    /// under the newest message shown (not a system one) they have read through, by
    /// `message_id`, in `user_id` order. None where the server shows none, outside private
    /// rooms, with Read Receipts off, for you, for someone whose cursor is older than everything
    /// shown, or for someone no longer a member where the members are known.
    public func receipts(in roomID: String, shown messages: [MessageSnapshot]) -> [LogID: [Reader]] {
        guard receiptSettings.isOn, server?.showsReadReceipts == true, store.room(roomID)?.isPrivate == true,
              let cursors = readers[roomID], !cursors.isEmpty else { return [:] }
        let ids = messages.filter { !$0.from.userID.hasPrefix("~") }.map(\.messageID)
        guard !ids.isEmpty else { return [:] }
        let members = store.members(of: roomID)
        var placed: [LogID: [Reader]] = [:]
        for (userID, through) in cursors.sorted(by: { codePointLess($0.key, $1.key) }) where !isYou(userID) {
            guard let at = ids.filter({ $0 <= through }).max() else { continue }
            let member = members?.first { $0.userID == userID }
            if members != nil, member == nil { continue }
            let user = member ?? users.user(userID).flatMap(UserObject.init) ?? UserObject(["user_id": .string(userID)])!
            placed[at, default: []].append(Reader(user: user, name: displayName(for: user)))
        }
        return placed
    }
}

/// How VoiceOver and the long press name the readers: "Seen by Ada, Bram and 2 more".
public enum SeenBy {
    public static func words(_ names: [String]) -> String {
        func list(_ items: [String]) -> String {
            items.count < 2 ? (items.first ?? "") : items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
        return "Seen by " + (names.count <= 3 ? list(names) : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more")
    }
}
