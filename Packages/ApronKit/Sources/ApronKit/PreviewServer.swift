import Foundation

/// An in-memory server that answers a session from a fixed script: the greeting, `auth`,
/// `room_list`, `history` by room, and the user's read cursors as `activity` (§4.6). A room's
/// unjoined threads are none, since the script joins every room. Every other request gets `{}`.
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
    }

    private let script: Script
    private var inbox: [String] = []
    private var reader: CheckedContinuation<String?, Never>?
    private var closed = false

    public init(script: Script) {
        self.script = script
    }

    public func connect() async throws {
        deliver(["method": "server", "params": script.greeting])
    }

    public func send(_ text: String) async throws {
        if closed { throw FrameTransportError.closed }
        let request = try JSONValue(parsing: text)
        guard let id = request["id"] else { return }
        let params = request["params"]
        switch request["method"]?.stringValue {
        case "auth":
            deliver(["id": id, "result": ["you": script.you, "token": "preview"]])
        case "room_list" where params?["parent_room_id"] != nil:
            deliver(["id": id, "result": ["not_joined": []]])
        case "room_list":
            deliver(["id": id, "result": script.roomList])
            for (roomID, read) in script.readCursors.sorted(by: { codePointLess($0.key, $1.key) }) {
                deliver(["method": "activity", "params": [
                    "room_id": .string(roomID), "from": ["user_id": script.you["user_id"] ?? nil], "read_message_id": .string(read),
                ]])
            }
            for notice in script.notices { deliver(["method": "message", "params": notice]) }
        case "history":
            let roomID = params?["room_id"]?.stringValue ?? ""
            deliver(["id": id, "result": script.histories[roomID] ?? ["messages": [], "more": false]])
        case "command" where params?["body"]?["text"]?.stringValue == "/help":
            deliver(["method": "message", "params": [
                "room_id": params?["room_id"] ?? "general", "from": ["user_id": "~private", "name": "System message to you"],
                "body": ["text": .string(Self.help), "format": "markdown"],
            ]])
            deliver(["id": id, "result": [:]])
        default:
            deliver(["id": id, "result": [:]])
        }
    }

    /// What apron-server-rust's `/help` lists for an account with no roles.
    static let help = """
    - `/help`: list the commands you can use here
    - `/avatar`: with one image attached: set your avatar
    - `/invite-device <name>`: get a token that signs in as you on another device, named <name>; at most 3 names, and a name again replaces its token
    - `/invite-bot`: get a token that signs in as your bot, named after you; again, it replaces the token and renames the bot
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
