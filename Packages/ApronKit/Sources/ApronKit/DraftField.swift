import Foundation

/// What the composer is writing, as apron-web's `DraftField`: a new message, a reply or an edit,
/// its text, and who it mentions. The composer and its edit mode share it: the `@`, `:` and `#`
/// lists in both, the `/` command list outside an edit only, since an edit is never a command.
///
/// A mention is written as `@` and the name picked, and kept in `mentions` (§3.5.5): the text
/// still showing `@name` is what keeps it when the message goes. A role is written `@&role`, as
/// sent, and mentions everyone else in the room who holds it when the message goes.
public struct DraftField: Hashable, Sendable {
    /// A reply names its message by id alone, as apron-web's kept `reply`: the composer shows
    /// whatever the session holds of it, so a reply kept across a relaunch still goes.
    public enum Mode: Hashable, Sendable {
        case new
        case reply(LogID)
        case edit(MessageEdit)
    }

    /// What is being typed at the end of the text, for the list above the field.
    public enum Query: Hashable, Sendable {
        /// The command word after `/` (`CommandHelp.query(in:)`).
        case command(String)
        /// The word after `@`, empty when only `@` is typed.
        case mention(String)
        /// The shortcode after `:` (`StandardEmoji.query(in:)`), for standard and custom emoji.
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
        self.init(mode: .edit(MessageEdit(message)), text: text, mentions: mentions)
    }

    /// The message a reply answers.
    public var replyTo: LogID? {
        if case .reply(let messageID) = mode { return messageID }
        return nil
    }

    /// The message an edit changes.
    public var editing: MessageSnapshot? { edit?.message }

    /// An edit's changes besides the text. Setting it outside an edit does nothing.
    public var edit: MessageEdit? {
        get {
            if case .edit(let edit) = mode { return edit }
            return nil
        }
        set {
            if isEdit, let newValue { mode = .edit(newValue) }
        }
    }

    public var isEdit: Bool { editing != nil }

    /// The query being typed, if any. Each kind needs its own first character, so at most one is.
    public var query: Query? {
        if !isEdit, let command = CommandHelp.query(in: text) { return .command(command) }
        let word = text.split(separator: " ", omittingEmptySubsequences: false).last ?? ""
        if word.hasPrefix("@"), !word.contains("\n") { return .mention(String(word.dropFirst())) }
        if let shortcode = StandardEmoji.query(in: text) { return .emoji(shortcode) }
        if let room = RoomMentions.query(in: text) { return .room(room) }
        return nil
    }

    /// The text that goes: without leading and trailing whitespace.
    public var sentText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The `user_id`s for `body.mentions` in the order the text names them, each once, as
    /// apron-web's `draftMentions`: each mention whose `@` word the text still shows, and for each
    /// `@&role` written, the holders `holders` gives for it (the room's, without you).
    public func sentMentions(holders: [String: [String]] = [:]) -> [String] {
        let text = sentText
        var named: [(offset: Int, ids: [String])] = []
        for (id, word) in mentions {
            guard let at = text.range(of: "@" + word) else { continue }
            named.append((text.unicodeScalars.distance(from: text.startIndex, to: at.lowerBound), [id]))
        }
        for written in RoleMentions.written(in: text) {
            if let ids = holders[written.role] { named.append((written.offset, ids)) }
        }
        var seen = Set<String>()
        return named.sorted { $0.offset != $1.offset ? $0.offset < $1.offset : codePointLess($0.ids[0], $1.ids[0]) }
            .flatMap(\.ids).filter { seen.insert($0).inserted }
    }

    /// Whether Send is on, given the staged files: none still being prepared, the text within
    /// `TextLimit`, and text or a file to send. An edit sends no files, and may keep only its
    /// embeds.
    public func canSend(readyFiles: Int, preparing: Bool) -> Bool {
        let other = edit.map(\.keepsEmbeds) ?? (readyFiles > 0)
        return !preparing && !TextLimit(text).isOver && (!sentText.isEmpty || other)
    }

    /// Puts `@name ` in place of the `@` word being typed, and mentions the user.
    public mutating func insert(mention userID: String, named name: String) {
        guard let at = text.range(of: "@", options: .backwards) else { return }
        text.replaceSubrange(at.lowerBound..., with: "@\(name) ")
        mentions[userID] = name
    }

    /// Puts `@&role ` in place of the `@` word being typed: everyone else here who holds the
    /// role is mentioned when the message goes.
    public mutating func insert(role: String) {
        guard let at = text.range(of: "@", options: .backwards) else { return }
        text.replaceSubrange(at.lowerBound..., with: "@&\(role) ")
    }

    /// Mentions a user picked elsewhere, as a profile card's Mention: `@name ` at the end of the
    /// text, after a space when the text does not end in one.
    public mutating func mention(_ userID: String, named name: String) {
        if let last = text.last, !last.isWhitespace { text += " " }
        text += "@\(name) "
        mentions[userID] = name
    }

    /// Puts the emoji, or a custom emoji's key, in place of the `:shortcode` being typed, as
    /// apron-web's `pickEmoji` (no space after it).
    public mutating func insert(_ emoji: EmojiSuggestion) {
        guard let colon = text.range(of: ":", options: .backwards) else { return }
        text.replaceSubrange(colon.lowerBound..., with: emoji.inserted)
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
    case mentions([MentionSuggestion])
    case emoji([EmojiSuggestion])
    case rooms([RoomSuggestion])
}

extension ServerSession {
    /// The most rows the `@` list shows (apron-web's `MENTION_MATCHES_MAX`).
    public static let mentionRows = 8

    /// The list for `field`'s query in `roomID`: the commands `/help` gave that start with the
    /// word, the `@` list (`mentionSuggestions`), up to eight emoji (the server's custom ones
    /// first, `StandardEmoji.suggestions`), or the `#` list. Nil when nothing matches.
    public func suggestions(for field: DraftField, in roomID: String) -> DraftSuggestions? {
        switch field.query {
        case nil:
            return nil
        case .command(let word):
            guard let found = commands?.matching(word), !found.isEmpty else { return nil }
            return .commands(found)
        case .mention(let word):
            let found = mentionSuggestions(word, in: roomID)
            return found.isEmpty ? nil : .mentions(found)
        case .emoji(let name):
            let found = StandardEmoji.suggestions(name, catalog: emojiCatalog)
            return found.isEmpty ? nil : .emoji(found)
        case .room(let id):
            let found = RoomMentions.search(roomSuggestions, id)
            return found.isEmpty ? nil : .rooms(found)
        }
    }

    /// The `@` list for the word after `@`, as apron-web's `matching`: the room's other members
    /// whose name or `user_id` contains it (all of them for a bare `@`), and the roles
    /// (`mentionableRoles`) whose name starts with it. Whoever and whatever it names exactly
    /// comes first, then people, then roles, which keep up to `RoleMentions.placesKept` places
    /// when people fill the list. `@&` lists roles alone.
    public func mentionSuggestions(_ word: String, in roomID: String) -> [MentionSuggestion] {
        let limit = Self.mentionRows
        let roles = RoleMentions.search(mentionableRoles(in: roomID), word)
        if word.hasPrefix("&") { return roles.prefix(limit).map(MentionSuggestion.role) }
        let exact = word.lowercased()
        let people = memberSections(roomID).flatMap(\.people).filter { person in
            person.userID != you?.userID
                && (word.isEmpty || displayName(for: person).localizedCaseInsensitiveContains(word) || person.userID.localizedCaseInsensitiveContains(word))
        }
        let isNamed = { (person: UserObject) in !exact.isEmpty && (self.displayName(for: person).lowercased() == exact || person.userID.lowercased() == exact) }
        let named = people.filter(isNamed), rest = people.filter { !isNamed($0) }
        let exactRoles = roles.filter { !exact.isEmpty && $0.role.lowercased() == exact }
        let otherRoles = roles.filter { !exactRoles.contains($0) }
        let free = limit - named.count - exactRoles.count - rest.count
        let roleCount = min(otherRoles.count, max(RoleMentions.placesKept, free))
        let shown = named.map(MentionSuggestion.person) + exactRoles.map(MentionSuggestion.role)
            + rest.prefix(max(0, limit - named.count - exactRoles.count - roleCount)).map(MentionSuggestion.person)
            + otherRoles.prefix(roleCount).map(MentionSuggestion.role)
        return Array(shown.prefix(limit))
    }

    /// Sends what the composer wrote, as apron-web's `sendMessage`: for a new message or a reply,
    /// a command (`ComposerAction`, the draft's files going with the server's own `command`) or a
    /// message queued in the outbox with the files and the previews of its links still on the
    /// draft (`DraftLinkPreviews`); for an edit, its save, which sends no files.
    /// Returns the room to show after a command, such as the one `/join` named. A failed command
    /// throws `CommandFailure`, holding `draft` to give back.
    @discardableResult
    public func submit(_ draft: ComposerDraft, in roomID: String) async throws -> String? {
        let field = draft.field
        let text = field.sentText
        let holders = Dictionary(mentionableRoles(in: roomID).map { ($0.role, $0.members) }, uniquingKeysWith: { first, _ in first })
        let mentions = field.sentMentions(holders: holders)
        if let target = field.edit {
            try await edit(target, text: text, mentions: mentions)
            return nil
        }
        let attachments = draft.files.compactMap(\.attachment)
        let action = action(for: field, withFiles: !attachments.isEmpty)
        guard action.isCommand else {
            let links = linkPreviews.embeds(in: text, dismissed: draft.dismissedPreviews)
            post(text, in: roomID, replyTo: field.replyTo, mentions: mentions, links: links, attachments: attachments)
            return nil
        }
        return try await run(action, from: draft, in: roomID, mentions: mentions)
    }
}
