import Foundation

/// What the composer is writing, as apron-web's `DraftField`: a new message, a reply or an edit,
/// its text, and who it mentions. The composer and its edit mode share it: the `@`, `:` and `#`
/// lists in both, the `/` command list outside an edit only, since an edit is never a command.
///
/// A mention is written as `@` and the name picked, and kept in `mentions` (§3.5.5): the text
/// still showing `@name` is what keeps it when the message goes.
public struct DraftField: Sendable {
    public enum Mode: Sendable {
        case new
        case reply(MessageSnapshot)
        case edit(MessageSnapshot)
    }

    /// What is being typed at the end of the text, for the list above the field.
    public enum Query: Hashable, Sendable {
        /// The command word after `/` (`CommandHelp.query(in:)`).
        case command(String)
        /// The word after `@`, empty when only `@` is typed.
        case mention(String)
        /// The name after `:`, while the word could be a custom emoji's key (`ext:emoji`).
        case emoji(String)
        /// The room id after `#` (`RoomMentions.query(in:)`).
        case room(String)
    }

    public var mode: Mode
    public var text: String
    /// The users this draft mentions, by `user_id`, each with the word written after its `@`.
    public var mentions: [String: String]

    public init(mode: Mode = .new, text: String = "", mentions: [String: String] = [:]) {
        self.mode = mode
        self.text = text
        self.mentions = mentions
    }

    /// An edit of `message`: its text, and the users its `body.mentions` lists whose `@name` or
    /// `@user_id` the text shows, as the row draws them. One the text no longer shows is left out,
    /// as apron-web's editor keeps only the mentions its chips show.
    @MainActor
    public init(editing message: MessageSnapshot, in session: ServerSession) {
        let text = message.plainText
        var mentions: [String: String] = [:]
        for id in message.mentionIDs where mentions[id] == nil {
            let name = session.users.user(id).flatMap(UserObject.init).map(session.displayName(for:)) ?? id
            if let written = [name, id].first(where: { text.contains("@" + $0) }) { mentions[id] = written }
        }
        self.init(mode: .edit(message), text: text, mentions: mentions)
    }

    /// The message a reply or an edit is about.
    public var target: MessageSnapshot? {
        switch mode {
        case .new: nil
        case .reply(let message), .edit(let message): message
        }
    }

    public var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// The query being typed, if any. Each kind needs its own first character, so at most one is.
    public var query: Query? {
        if !isEdit, let command = CommandHelp.query(in: text) { return .command(command) }
        let word = text.split(separator: " ", omittingEmptySubsequences: false).last ?? ""
        if word.hasPrefix("@"), !word.contains("\n") { return .mention(String(word.dropFirst())) }
        if word.hasPrefix(":"), word.count > 1, CustomEmoji.isKey(word + ":") { return .emoji(String(word.dropFirst())) }
        if let room = RoomMentions.query(in: text) { return .room(room) }
        return nil
    }

    /// The text that goes: without leading and trailing whitespace.
    public var sentText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The `user_id`s for `body.mentions`, in order: each mention whose `@` word the text still shows.
    public var sentMentions: [String] {
        let text = sentText
        return mentions.filter { text.contains("@" + $0.value) }.map(\.key).sorted()
    }

    /// Whether Send is on, given the staged files: none still being prepared, the text within
    /// `TextLimit`, and text or a file to send. An edit sends no files.
    public func canSend(readyFiles: Int, preparing: Bool) -> Bool {
        !preparing && !TextLimit(text).isOver && (!sentText.isEmpty || (!isEdit && readyFiles > 0))
    }

    /// Puts `@name ` in place of the `@` word being typed, and mentions the user.
    public mutating func insert(mention userID: String, named name: String) {
        guard let at = text.range(of: "@", options: .backwards) else { return }
        text.replaceSubrange(at.lowerBound..., with: "@\(name) ")
        mentions[userID] = name
    }

    /// Puts the emoji's key in place of the `:name` being typed, then a space.
    public mutating func insert(_ emoji: CustomEmoji) {
        guard let colon = text.range(of: ":", options: .backwards) else { return }
        text.replaceSubrange(colon.lowerBound..., with: emoji.key + " ")
    }

    /// Puts `#room_id ` in place of the `#` being typed.
    public mutating func insert(room roomID: String) {
        text = RoomMentions.insert(roomID, into: text)
    }

    /// Puts `/name ` in the field, for the command's arguments.
    public mutating func insert(_ command: ServerCommand) {
        text = "/\(command.name) "
    }
}

/// The list above the composer for what is being typed: at most one kind, never empty.
public enum DraftSuggestions: Hashable, Sendable {
    case commands([ServerCommand])
    case people([UserObject])
    case emoji([CustomEmoji])
    case rooms([RoomSuggestion])
}

extension ServerSession {
    /// The list for `field`'s query in `roomID`: the commands `/help` gave that start with the
    /// word, up to six of the room's other members whose name or `user_id` contains it (the first
    /// six for a bare `@`), up to six custom emoji, or the `#` list. Nil when nothing matches.
    public func suggestions(for field: DraftField, in roomID: String) -> DraftSuggestions? {
        switch field.query {
        case nil:
            return nil
        case .command(let word):
            guard let found = commands?.matching(word), !found.isEmpty else { return nil }
            return .commands(found)
        case .mention(let word):
            let people = memberSections(roomID).flatMap(\.people).filter { $0.userID != you?.userID }
            let found = word.isEmpty ? Array(people.prefix(6)) : Array(people.filter {
                displayName(for: $0).localizedCaseInsensitiveContains(word) || $0.userID.localizedCaseInsensitiveContains(word)
            }.prefix(6))
            return found.isEmpty ? nil : .people(found)
        case .emoji(let name):
            guard let found = emojiCatalog?.search(name, limit: 6), !found.isEmpty else { return nil }
            return .emoji(found)
        case .room(let id):
            let found = RoomMentions.search(roomSuggestions, id)
            return found.isEmpty ? nil : .rooms(found)
        }
    }

    /// Sends what the composer wrote: a command or a message (queued in the outbox) for a new
    /// message or a reply, or the edit's save, which sends no files.
    public func submit(_ field: DraftField, in roomID: String, attachments: [Attachment]) async throws {
        let text = field.sentText
        let mentions = field.sentMentions
        switch field.mode {
        case .new, .reply:
            let replyTo = field.target?.messageID
            if Draft(text: text).isCommand {
                try await send(text, in: roomID, replyTo: replyTo, mentions: mentions, attachments: attachments)
            } else {
                post(text, in: roomID, replyTo: replyTo, mentions: mentions, attachments: attachments)
            }
        case .edit(let target):
            try await edit(target, text: text, mentions: mentions)
        }
    }
}
