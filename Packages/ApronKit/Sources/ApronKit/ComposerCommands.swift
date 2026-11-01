import Foundation

/// What the composer does with its text (§4.1), as apron-web's `composerAction`. With capability
/// `command`, text that starts with one `/` is a command: `/nick`, `/join`, `/leave`, `/topic`,
/// `/kick` and `/invite` are the requests they spell (all but the first need capability
/// `rooms`), and anything else goes to the server as a `command`. `//` posts a message starting
/// with `/`. Without capability `command`, every text is a message.
public enum ComposerAction: Hashable, Sendable {
    case message(String)
    case command(String)
    /// `me {name}` (§3.3.2).
    case nick(String)
    /// `room_join`, by the room's id or title (§4.2.2).
    case join(String)
    /// `room_leave` of the room named, else the one written in.
    case leave(String?)
    /// `room_set` with the room's new `description` (§4.2.4).
    case topic(String)
    /// `room_leave` with the `user_id` of the member to remove (§4.2.2).
    case kick(String)
    /// `room_join` with the `user_id` of the user to add (§4.2.2).
    case invite(String)

    /// `members`: adding and removing others is worth trying; once the server answered it
    /// `unsupported`, `/kick` and `/invite` go to the server as commands. `mentions` are the
    /// draft's picked mentions the text still shows, by `user_id`, each with the word written
    /// after its `@`: one written as the argument names that user exactly, where the text alone
    /// would not (a name has spaces, and an id in text ends with a letter, a digit or `_`).
    public init(_ text: String, command: Bool, rooms: Bool, members: Bool = true, mentions: [String: String] = [:]) {
        guard command else { self = .message(text); return }
        if text.hasPrefix("//") { self = .message(String(text.dropFirst())); return }
        guard text.hasPrefix("/"), let match = text.trimmingSuffix().wholeMatch(of: Self.shape) else { self = .message(text); return }
        let name = match.1.lowercased()
        let argument = (match.2.map(String.init) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "nick", !argument.isEmpty { self = .nick(argument); return }
        if rooms {
            let room = argument.hasPrefix("#") ? String(argument.dropFirst()) : argument
            if name == "join", !argument.isEmpty { self = .join(room); return }
            if name == "leave" { self = .leave(argument.isEmpty ? nil : room); return }
            if name == "topic", !argument.isEmpty { self = .topic(argument); return }
            // Only a bare user maps to a request: a reason is something only the server's own command can carry.
            if members, let user = Self.user(argument, mentions: mentions) {
                if name == "kick" { self = .kick(user); return }
                if name == "invite" { self = .invite(user); return }
            }
        }
        self = .command(text)
    }

    /// `/name`, then the argument after whitespace, if any (apron-web's `^\/(\S+)(?:\s+([\s\S]*))?$`).
    nonisolated(unsafe) private static let shape = /\/(\S+)(?:\s+([\s\S]*))?/
    /// A lone user argument, `@user_id` or the bare id, as Appendix A.3 ends an id in text
    /// (apron-web's `USER_ARGUMENT`).
    nonisolated(unsafe) private static let userArgument = /@?([A-Za-z0-9_](?:[A-Za-z0-9_.+@:-]*[A-Za-z0-9_])?)[.+@:-]*/

    private static func user(_ argument: String, mentions: [String: String]) -> String? {
        if mentions.count == 1, let only = mentions.first, argument == "@" + only.value { return only.key }
        return argument.wholeMatch(of: userArgument).map { String($0.1) }
    }

    /// Whether the server runs it: a `command` request, or one of the requests a command spells.
    public var isCommand: Bool {
        if case .message = self { return false }
        return true
    }
}

private extension String {
    func trimmingSuffix() -> Substring {
        self[..<(lastIndex { !$0.isWhitespace }.map(index(after:)) ?? startIndex)]
    }
}

/// A command that failed: its reason shows as a notice where it was written, and the draft it
/// was written in goes back to the composer (`Drafts.restore`), as apron-web gives it back.
public struct CommandFailure: Error, Hashable, Sendable {
    public let reason: String
    public let draft: ComposerDraft
}

extension ServerSession {
    /// The action `field` is in `roomID`, as the server allows it. With files attached, only a
    /// message or the server's own `command` takes them, as apron-web's `sendFiles`.
    public func action(for field: DraftField, withFiles: Bool) -> ComposerAction {
        let text = field.sentText
        let shown = field.mentions.filter { text.contains("@" + $0.value) }
        let action = ComposerAction(text, command: server?.has("command") == true, rooms: !withFiles && server?.has("rooms") == true,
                                    members: !memberChangesUnsupported, mentions: shown)
        if withFiles, action.isCommand { return .command(text) }
        return action
    }

    /// Runs a command written in `roomID`, as apron-web's `sendMessage`. Returns the room to show
    /// after it: the one `/join` named, or a thread's room after `/leave` left the thread. A
    /// failure shows as a `~private` notice in `roomID`, where a command's replies land too, and
    /// comes back as a `CommandFailure` holding `draft`.
    func run(_ action: ComposerAction, from draft: ComposerDraft, in roomID: String, mentions: [String]) async throws -> String? {
        let attachments = draft.files.compactMap(\.attachment)
        do {
            switch action {
            case .message:
                return nil
            case .command(let text):
                try await send(text, in: roomID, replyTo: draft.field.replyTo, mentions: mentions, attachments: attachments)
            case .nick(let name):
                try await updateProfile(["name": .string(name)])
            case .join(let name):
                return try await join(named: name)
            case .leave(let named):
                let leaving = named ?? roomID
                let parent = leaving == roomID ? store.room(roomID)?.parentRoomID : nil
                try await leave(leaving)
                return parent
            case .topic(let description):
                try await editRoom(roomID, title: editableTitle(of: roomID), description: description)
            case .kick(let user), .invite(let user):
                do {
                    if case .kick = action { try await removeMember(user, from: roomID) } else { try await addMember(user, to: roomID) }
                } catch let error as RPCError where error.code == RPCError.Code.unsupported {
                    // The server may still have the command itself (§4.1): it gets the text as typed.
                    try await send(draft.field.sentText, in: roomID, replyTo: draft.field.replyTo, mentions: mentions, attachments: attachments)
                }
            }
        } catch {
            let reason = errorText(error)
            notices.append(Notice(roomID: roomID, from: UserObject(["user_id": "~private"])!, body: ["text": .string(reason), "format": "plain"]))
            throw CommandFailure(reason: reason, draft: draft)
        }
        return nil
    }

    /// `/join`, as apron-web's `joinByName`: a room you're in, by id or then by title (ignoring
    /// case), is only shown; another the session has a record of is joined by id, else by title;
    /// anything else is joined as an id. Returns the room to show.
    func join(named name: String) async throws -> String {
        let wanted = name.lowercased()
        let titled = { (id: String) in self.store.room(id)?.title?.stringValue?.lowercased() == wanted }
        let joined = joinedRoomIDs.sorted(by: codePointLess)
        if let room = joined.first(where: { $0 == name }) ?? joined.first(where: titled) { return room }
        let known = store.roomIDs.filter { store.room($0) != nil }
        let target = known.first { $0 == name } ?? known.first(where: titled) ?? name
        try await join(target)
        return target
    }
}
