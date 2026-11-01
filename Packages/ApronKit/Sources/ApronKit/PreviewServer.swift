import Foundation

/// An in-memory server that answers a session from a fixed script: the greeting, `auth`,
/// `room_list`, `history` by room, the user's read cursors as `activity` (§4.6), others' typing, and the
/// mutes in effect (§4.5). A `status` mute is echoed back before its `{}`, as servers do. A room's
/// unjoined threads are the script's `unjoinedThreads`. A `room_set` without a `room_id` creates
/// the room as asked, with you its one member, in a `room_update` before its result. Removing
/// someone else (`room_leave` with a `user_id`) is refused, as aprond refuses a member who did
/// not create the room, for the failed command shot. Every other request gets `{}`. A script's `welcome`
/// goes right after the greeting.
/// It never sends anything unasked, so a seeded session stays still.
public actor PreviewServer: FrameTransport {
    public struct Script: Sendable {
        public var greeting: JSONValue
        public var you: JSONValue
        /// `room_list` result: `joined` rooms and `users`.
        public var roomList: JSONValue
        /// `history` result per `room_id`.
        public var histories: [String: JSONValue]
        /// `read_message_id` per `room_id`.
        public var readCursors: [String: String]
        /// Notices (§3.5.3) sent after the `room_list` of joined rooms.
        public var notices: [JSONValue] = []
        /// Others' `activity` (§4.6), such as typing, sent after the notices.
        public var activities: [JSONValue] = []
        /// `status` params (§4.5 `mute`) in effect, sent after the `auth` result.
        public var statuses: [JSONValue] = []
        /// `room_list {parent_room_id, filter: not_joined}` results' `not_joined`, by parent.
        public var unjoinedThreads: [String: JSONValue] = [:]
        /// `room_list {filter: not_joined}` results' `not_joined`: Browse Rooms.
        public var unjoinedRooms: [JSONValue] = []
        /// A `~private` notice without `room_id` sent right after the greeting, before `auth`,
        /// as a server's welcome is (Appendix B.1).
        public var welcome: JSONValue?
        /// The `token` in the `auth` result; none, as for a guest who cannot resume.
        public var token: String? = "preview"
    }

    private let script: Script
    private var inbox: [String] = []
    private var reader: CheckedContinuation<String?, Never>?
    private var closed = false
    private var created = 0

    public init(script: Script) {
        self.script = script
    }

    public func connect() async throws {
        deliver(["method": "server", "params": script.greeting])
        if let welcome = script.welcome { deliver(["method": "message", "params": welcome]) }
    }

    public func send(_ text: String) async throws {
        if closed { throw FrameTransportError.closed }
        let request = try JSONValue(parsing: text)
        guard let id = request["id"] else { return }
        let params = request["params"]
        switch request["method"]?.stringValue {
        case "auth" where params?["token"]?.stringValue == Self.expiredToken:
            deliver(["id": id, "error": ["code": -32001, "message": "Your session expired. Sign in again."]])
        case "auth" where params?["token"] == nil && params?["scheme"]?.stringValue == "external":
            deliver(["id": id, "result": ["url": .string(Self.signInPage)]])
        case "auth" where params?["token"] == nil && params?["scheme"]?.stringValue == "email":
            deliver(["id": id, "result": [:]])
        case "auth":
            var result: [String: JSONValue] = ["you": script.you]
            if let token = script.token { result["token"] = .string(token) }
            deliver(["id": id, "result": .object(result)])
            for status in script.statuses { deliver(["method": "status", "params": status]) }
        case "room_list" where params?["parent_room_id"] != nil:
            deliver(["id": id, "result": ["not_joined": script.unjoinedThreads[params?["parent_room_id"]?.stringValue ?? ""] ?? []]])
        case "room_list" where params?["filter"]?.stringValue == "not_joined":
            deliver(["id": id, "result": ["not_joined": .array(script.unjoinedRooms)]])
        case "room_list":
            deliver(["id": id, "result": script.roomList])
            for (roomID, read) in script.readCursors.sorted(by: { codePointLess($0.key, $1.key) }) {
                deliver(["method": "activity", "params": [
                    "room_id": .string(roomID), "from": ["user_id": script.you["user_id"] ?? nil], "read_message_id": .string(read),
                ]])
            }
            for notice in script.notices { deliver(["method": "message", "params": notice]) }
            for activity in script.activities { deliver(["method": "activity", "params": activity]) }
        case "history":
            let roomID = params?["room_id"]?.stringValue ?? ""
            deliver(["id": id, "result": script.histories[roomID] ?? ["messages": [], "more": false]])
        case "command" where params?["body"]?["text"]?.stringValue == "/help":
            deliver(["method": "message", "params": [
                "room_id": params?["room_id"] ?? "general", "from": ["user_id": "~private", "name": "System message to you"],
                "body": ["text": .string(Self.help), "format": "markdown"],
            ]])
            deliver(["id": id, "result": [:]])
        case "reactions" where params?["emojis"]?.arrayValue?.contains(.string(Self.slowReaction)) == true:
            deliver(["id": id, "error": ["code": -32002, "message": "Posting limit reached",
                                         "data": ["retry_after": 45, "ext": ["limits": "write"]]]])
        case "message" where LimitScope.addsUpload("message", params):
            deliver(["id": id, "error": ["code": -32002, "message": "Daily upload limit reached",
                                         "data": ["retry_after": 7500, "ext": ["limits": "upload"]]]])
        case "room_set" where params?["room_id"] == nil:
            created += 1
            let roomID = "new_\(created)"
            var room = params?.objectValue ?? [:]
            room["room_id"] = .string(roomID)
            room["log_id"] = .string(String(9_000_000_000_000 + created))
            room["members"] = [["user_id": script.you["user_id"] ?? nil]]
            deliver(["method": "room_update", "params": ["joined": [.object(room)]]])
            deliver(["id": id, "result": ["room_id": .string(roomID)]])
        case "room_leave" where params?["user_id"] != nil:
            deliver(["id": id, "error": ["code": -32001,
                                         "message": "Only an admin, the room's creator, or a bot's owner, can remove someone else"]])
        case "status" where params?["mute"] != nil:
            deliver(["method": "status", "params": params ?? [:]])
            deliver(["id": id, "result": [:]])
        default:
            deliver(["id": id, "result": [:]])
        }
    }

    /// A saved token the server refuses, for a session held for its passkey.
    public static let expiredToken = "expired"
    /// The external sign-in page every proposal gets (§4.11.5).
    public static let signInPage = "https://owner.example/sso?p=Qm7x"

    /// A reaction the server refuses as over its posting limit (45 s, `ext:limits` `write`), so a
    /// preview can show sending paused. Any new upload is refused for two hours (`upload`).
    public static let slowReaction = "⏳"

    /// What apron-server-rust's `/help` lists for an account with no roles.
    static let help = """
    - `/avatar`: with one image attached: set your avatar
    - `/help`: list the commands you can use here
    - `/invite-bot`: get a token that signs in as your bot, named after you; again, it replaces the token and renames the bot
    - `/invite-device list|add|remove [<id>]`: list, get or revoke tokens that sign in as you on another device
    - `/passkeys [remove <n>]`: list your account's passkeys, or remove one of them
    """

    public func receive() async throws -> String {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { throw FrameTransportError.closed }
        guard let next = await withCheckedContinuation({ reader = $0 }) else { throw FrameTransportError.closed }
        return next
    }

    public func close() async {
        closed = true
        reader?.resume(returning: nil)
        reader = nil
    }

    private func deliver(_ frame: JSONValue) {
        let text = frame.serialized()
        if let reader {
            self.reader = nil
            reader.resume(returning: text)
        } else {
            inbox.append(text)
        }
    }
}
