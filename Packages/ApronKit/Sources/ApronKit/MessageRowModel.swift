import Foundation

/// What a message's row shows, worked out once from the session: the text with its link,
/// emoji, room and mention chips, whether it mentions you, its place cards, the embeds a card
/// does not already show, the link this device may fetch a preview for and the `link` embed that
/// preview replaces, and what VoiceOver reads.
public struct MessageRowModel {
    public let message: MessageSnapshot
    public let name: String
    public let roles: [String]
    /// The message lists you in `body.mentions` and someone else sent it.
    public let mentionsYou: Bool
    /// The body as `MessageText` renders it, in blocks, mentions marked with `MentionKey`.
    public let blocks: [MessageBlock]
    public let cards: [PlaceCard]
    /// The embeds to draw with their index in the message, which names their media; a sender's
    /// preview of a place a card shows is left out (`PlaceCard.previews`), and so is an `append`,
    /// whose text continues the body (§4.8.5).
    public let embeds: [(index: Int, embed: Embed)]
    /// The message's `append` embed while this device may read it: its text so far follows
    /// `body.text` in `blocks`, as one text in the body's format, Markdown cut off mid-construct
    /// settled while it arrives (`LiveMarkdown`), as apron-web's `appendedBody`. The row follows it.
    public let liveAppend: LiveText?
    /// The live text is still arriving: "Writing…" under the text.
    @MainActor public var isWriting: Bool { liveAppend?.isLive == true }
    /// The message's `append` embed has no `url` yet, its write not started (§4.8.5): "Waiting
    /// to stream…" under the text, as apron-web's `waiting`, and nothing is read.
    public let isWaiting: Bool
    /// What shows under the text, and VoiceOver reads after it, while an append is live.
    @MainActor public var liveLine: String? { isWriting ? "Writing…" : isWaiting ? "Waiting to stream…" : nil }
    /// The link to fetch a preview for (`unfurlURL`).
    public let unfurl: URL?
    /// The `link` embed for `unfurl`, which the fetched preview takes the place of. Without one,
    /// the preview goes under the embeds.
    public let unfurledEmbed: Int?
    private let spokenText: String
    private let replyLine: String?
    private let movedFrom: String?
    private let reactions: String?

    @MainActor
    public init(_ message: MessageSnapshot, in session: ServerSession, sessions: (URL) -> ServerSession? = { _ in nil }) {
        self.message = message
        name = session.displayName(for: message.from)
        roles = session.roles(of: message.from)
        mentionsYou = session.you.map { message.mentions($0.userID) && message.from.userID != $0.userID } ?? false
        let names = Dictionary(message.mentionIDs.map { id in
            (id, session.users.user(id).flatMap(UserObject.init).map(session.displayName(for:)) ?? id)
        }, uniquingKeysWith: { first, _ in first })
        liveAppend = session.appendedText(of: message)
        isWaiting = message.embedList.first(where: \.isAppend)?.isWaitingForWriter == true
        let shown = Self.appended(message, liveAppend)
        blocks = MessageText.blocks(shown.body, emoji: session.emojiCatalog, rooms: session.referencedTitle, links: session.linkChip, mentions: names,
                                      you: session.you?.userID)
        cards = session.placeCards(in: message, sessions: sessions)
        embeds = message.embedList.enumerated()
            .filter { [cards] in !$0.element.isAppend && !PlaceCard.previews($0.element, in: cards, from: session.record.url) }
            .map { (index: $0.offset, embed: $0.element) }
        unfurl = message.unfurlURL
        unfurledEmbed = unfurl.flatMap { [embeds] url in embeds.first { $0.embed.kind == "link" && $0.embed.url == url }?.index }
        spokenText = EmojiKeys.spoken(Self.chipsSpoken(shown.plainText, in: blocks, session: session), catalog: session.emojiCatalog)
        replyLine = message.replyTo.map { target in
            let quoted = session.store.message(target)
            return "replying to " + (quoted.map { $0.isTombstone ? "a deleted message" : session.displayName(for: $0.from) } ?? "an unavailable message")
        }
        movedFrom = message.prevRoomID.map { "moved from \(session.title(of: $0))" }
        reactions = session.store.reactions(on: message.messageID).map { summaries in
            summaries.map { "\(ReactionEntry.label($0.emoji, catalog: session.emojiCatalog)) \($0.userIDs.count)" }.joined(separator: ", ")
        }
    }

    /// The message with an append's streamed text after `body.text`.
    @MainActor
    private static func appended(_ message: MessageSnapshot, _ live: LiveText?) -> MessageSnapshot {
        guard let live, !live.text.isEmpty, case .object(var body) = message.body else { return message }
        let text = (body["text"]?.stringValue ?? "") + live.text
        let markdown = body["format"]?.stringValue == "markdown"
        body["text"] = .string(markdown && live.isLive ? LiveMarkdown.settle(text) : text)
        var shown = message
        shown.body = .object(body)
        return shown
    }

    /// The text with each link drawn as a chip read as its words, as the row shows it.
    @MainActor
    private static func chipsSpoken(_ text: String, in blocks: [MessageBlock], session: ServerSession) -> String {
        var out = text
        let shown = MessageBlock.flattened(blocks)
        for (link, range) in shown.runs[\.link] {
            guard let link, shown[range].runs.contains(where: { $0[LinkChipKey.self] != nil || $0[MentionKey.self] != nil }),
                  let chip = session.linkChip(link) else { continue }
            out = out.replacingOccurrences(of: link.absoluteString.removingPercentEncoding ?? link.absoluteString, with: chip.spoken)
        }
        return out
    }

    /// What VoiceOver reads for the row: the reminder's due line, the sender and roles, the
    /// mention, the reply, the text, the move, the cards and embeds, the edit, the time and the
    /// reactions.
    public func spoken(reminderDue: Date?, now: Date) -> String {
        var parts = (reminderDue.map { [Reminder.label(due: $0, now: now)] } ?? []) + [name] + roles
        if mentionsYou { parts.append("mentions you") }
        if let replyLine { parts.append(replyLine) }
        parts.append(spokenText)
        if let movedFrom { parts.append(movedFrom) }
        parts += cards.map(\.spoken)
        parts += embeds.map(\.embed.summary)
        if message.isEdited { parts.append("edited") }
        parts.append(message.date.formatted(date: .omitted, time: .shortened))
        if let reactions { parts.append(reactions) }
        return parts.joined(separator: ", ")
    }
}

extension EmojiKeys {
    /// Plain text as VoiceOver reads it: each custom emoji key the catalog has as its `alt`.
    public static func spoken(_ text: String, catalog: EmojiCatalog?) -> String {
        guard let catalog else { return text }
        var out = text
        for range in ranges(in: text, known: { catalog[$0] != nil }).reversed() {
            out.replaceSubrange(range, with: catalog[String(text[range])]?.label ?? "")
        }
        return out
    }
}

extension ReactionEntry {
    /// What VoiceOver reads for a reaction: the emoji, a custom emoji's `alt` or key, or the key.
    public static func label(_ entry: String, catalog: EmojiCatalog?) -> String {
        catalog?[entry]?.label ?? entry
    }
}

extension PlaceCard {
    /// The card as VoiceOver reads it, alone or inside its message's row.
    public var spoken: String {
        var parts: [String]
        switch content {
        case .message(let sender, let preview): parts = ["Message from \(sender) in \(roomTitle)", preview]
        case .room: parts = ["\(isThread ? "Thread" : "Room") \(roomTitle)"]
        }
        if isPrivate { parts.append("private") }
        if case .room = content, let memberCount { parts.append(memberCount == 1 ? "1 member" : "\(memberCount) members") }
        return parts.joined(separator: ", ")
    }
}

extension Embed {
    /// The embed's kind in words: an upload's, else its `kind` capitalized.
    public var kindLabel: String {
        switch upload {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .file, .pending: "File"
        case nil: kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    /// The embed as VoiceOver reads it in its message's row: its kind, then its picture's `alt`
    /// or its name.
    public var summary: String {
        [kindLabel, og?.image?.alt ?? name].compactMap { $0 }.joined(separator: ", ")
    }
}
