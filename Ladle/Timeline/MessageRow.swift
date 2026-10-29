import ApronKit
import SwiftUI

/// The web's Message: an avatar in a 32 pt gutter, the sender and time, the reply it answers
/// above, the text, embeds, and reactions. A message that mentions you sits on accent-soft with
/// an accent bar, as the web marks it. One a link opened to is highlighted on `hover`, as the
/// web's `ap-msg-highlighted`.
struct MessageRow: View {
    let session: ServerSession
    let message: MessageSnapshot
    let continues: Bool
    var highlighted = false
    var onReact: (String) -> Void = { _ in }
    var onAddReaction: () -> Void = {}
    var onJump: (LogID) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.fixedTypeSize) private var fixedTypeSize

    var body: some View {
        let name = session.displayName(for: message.from)
        // At accessibility sizes the avatar gutter gives its width back to the text: a small face
        // rides in the name line instead.
        let compact = (fixedTypeSize ?? typeSize).isAccessibilitySize
        let mentionsYou = session.you.map { message.mentions($0.userID) && message.from.userID != $0.userID } ?? false
        VStack(alignment: .leading, spacing: 0) {
            if let target = message.replyTo {
                ReplyQuote(session: session, target: target, onJump: onJump)
                    .padding(.leading, compact ? 0 : Tokens.AvatarSize.md + Tokens.Space.s3 - Tokens.Space.s1)
            }
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                if compact {
                    EmptyView()
                } else if continues {
                    Color.clear.frame(width: Tokens.AvatarSize.md, height: 1)
                } else {
                    Avatar(name: name, userID: message.from.userID, image: session.avatarURL(of: message.from.userID)).padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !continues {
                        HStack(alignment: .center, spacing: Tokens.Space.s2) {
                            if compact { Avatar(name: name, userID: message.from.userID, size: .sm, image: session.avatarURL(of: message.from.userID)) }
                            head(name)
                        }
                    }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, Tokens.Space.s1)
        .padding(.horizontal, Tokens.Space.s2)
        .background(highlighted ? Palette.hover : mentionsYou ? Palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(alignment: .leading) {
            if mentionsYou {
                Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, Tokens.Space.s1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(name: name, mentionsYou: mentionsYou))
        .task(id: session.server?.emojiCatalogURL) {
            if session.needsEmojiCatalog(message) { await session.loadEmojiCatalog() }
        }
    }

    private func head(_ name: String) -> some View {
        let roles = session.roles(of: message.from)
        return HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            Text(name).apText(.body, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
                .layoutPriority(1)
            if !roles.isEmpty {
                RoleBadges(roles: roles).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            HStack(spacing: Tokens.Space.s2) {
                Text(message.date, format: .dateTime.hour().minute())
                if message.isEdited { Text("edited") }
            }
            .apText(.sm)
            .monospacedDigit()
            .foregroundStyle(Palette.inkMuted)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !message.plainText.isEmpty {
            EmojiText(text: rendered(message.body, mentions: mentionNames, you: session.you?.userID, emoji: session.emojiCatalog),
                      catalog: session.emojiCatalog)
                .apText(.body)
                .foregroundStyle(Palette.ink)
                .tint(Palette.denim)
                .fixedSize(horizontal: false, vertical: true)
                .written(in: TextDirection(of: message.plainText))
        }
        if let room = message.prevRoomID {
            Text("Moved from \(Text(TextDirection.isolated(session.title(of: room))).foregroundStyle(Palette.denim))")
                .apText(.sm).italic().foregroundStyle(Palette.inkMuted)
                .padding(.top, Tokens.Space.s1)
        }
        let unfurl = message.unfurlURL
        let embeds = message.embedList
        // A fetched preview takes the place of the `link` embed for the same URL, if any.
        let unfurledEmbed = unfurl.flatMap { url in embeds.firstIndex { $0.kind == "link" && $0.url == url } }
        if !embeds.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                ForEach(Array(embeds.enumerated()), id: \.offset) { index, embed in
                    let view = EmbedView(session: session, embed: embed, mediaID: MediaItem.id(message, index))
                    if let unfurl, index == unfurledEmbed {
                        FetchedLinkCard(url: unfurl) { view }
                    } else {
                        view
                    }
                }
            }
            .padding(.top, Tokens.Space.s2)
        }
        if let unfurl, unfurledEmbed == nil {
            FetchedLinkCard(url: unfurl, inset: Tokens.Space.s2) { EmptyView() }
        }
        if let reactions = session.store.reactions(on: message.messageID) {
            ReactionBar(session: session, reactions: reactions, onReact: onReact, onAdd: onAddReaction)
                .padding(.top, Tokens.Space.s1)
        }
    }

    /// Each mentioned user's names, as `@name` may appear in the text.
    private var mentionNames: [String: String] {
        Dictionary(message.mentionIDs.map { id in
            (id, session.users.user(id).flatMap(UserObject.init).map(session.displayName(for:)) ?? id)
        }, uniquingKeysWith: { first, _ in first })
    }

    private func accessibilityText(name: String, mentionsYou: Bool) -> String {
        var parts = [name] + session.roles(of: message.from)
        if mentionsYou { parts.append("mentions you") }
        if message.replyTo != nil {
            let target = message.replyTo.flatMap(session.store.message)
            parts.append("replying to " + (target.map { $0.isTombstone ? "a deleted message" : session.displayName(for: $0.from) } ?? "an unavailable message"))
        }
        parts.append(spoken(message.plainText, session.emojiCatalog))
        if let room = message.prevRoomID { parts.append("moved from \(session.title(of: room))") }
        for embed in message.embedList { parts.append(EmbedCard.summary(embed)) }
        if message.isEdited { parts.append("edited") }
        parts.append(message.date.formatted(date: .omitted, time: .shortened))
        if let reactions = session.store.reactions(on: message.messageID) {
            parts.append(reactions.map { "\(ReactionGlyph.label($0.emoji, session.emojiCatalog)) \($0.userIDs.count)" }.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }
}

/// Plain text as VoiceOver reads it: each custom emoji key the catalog has as its `alt`.
func spoken(_ text: String, _ catalog: EmojiCatalog?) -> String {
    guard let catalog else { return text }
    var out = text
    for range in EmojiKeys.ranges(in: text, known: { catalog[$0] != nil }).reversed() {
        out.replaceSubrange(range, with: catalog[String(text[range])]?.label ?? "")
    }
    return out
}

/// The body as `MessageText` renders it, links and custom emoji keys included. Mentions outside
/// links show as the web's chips: denim on denim-soft, and accent with on-accent for you.
func rendered(_ body: JSONValue?, mentions: [String: String] = [:], you: String? = nil, emoji: EmojiCatalog? = nil) -> AttributedString {
    var out = MessageText.attributed(body, emoji: emoji)
    for (id, name) in mentions {
        for token in Set(["@" + name, "@" + id]) {
            var search = out.startIndex ..< out.endIndex
            while let range = out[search].range(of: token) {
                search = range.upperBound ..< out.endIndex
                if out[range].runs.contains(where: { $0.link != nil }) { continue }
                out[range].backgroundColor = id == you ? Palette.accent : Palette.denimSoft
                out[range].foregroundColor = id == you ? Palette.onAccent : Palette.denim
                out[range].inlinePresentationIntent = .stronglyEmphasized
            }
        }
    }
    return out
}

/// A one-line preview of a body inside a control (a reply quote, a room or thread row): its
/// first line as plain text (`MessageText.snippet`, so markdown shows without its syntax), with
/// no links, so a tap goes to the control and the line keeps its color, isolated from the words
/// around it (§3.5.2).
func previewText(_ body: JSONValue?) -> AttributedString {
    AttributedString("\u{2068}" + MessageText.snippet(body) + "\u{2069}")
}

extension View {
    /// Lays out a block of what someone wrote in its own direction (§3.5.2): a paragraph written
    /// against the app's direction starts at its own side.
    func written(in direction: TextDirection?) -> some View {
        modifier(WrittenDirection(direction: direction))
    }
}

private struct WrittenDirection: ViewModifier {
    let direction: TextDirection?
    @Environment(\.layoutDirection) private var layout

    func body(content: Content) -> some View {
        let against = direction.map { ($0 == .rightToLeft) != (layout == .rightToLeft) } ?? false
        content
            .multilineTextAlignment(against ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: against ? .trailing : .leading)
    }
}

/// The web's ReplyPreview: a bent line, the quoted sender's face and name, and one line of their
/// text. Tapping it jumps to the message. A target this client does not have, or one deleted
/// since, says so and leaves out who wrote it, as the timeline leaves the message out.
struct ReplyQuote: View {
    let session: ServerSession
    let target: LogID
    var onJump: (LogID) -> Void = { _ in }

    var body: some View {
        let stored = session.store.message(target)
        let quoted = stored?.isTombstone == true ? nil : stored
        let missing = stored == nil ? "Message unavailable" : "Original message deleted"
        Button { onJump(target) } label: {
            HStack(spacing: Tokens.Space.s1) {
                Image(systemName: "arrow.turn.up.right").imageScale(.small).foregroundStyle(Palette.lineStrong)
                    .scaleEffect(x: -1)
                if let quoted {
                    Avatar(name: session.displayName(for: quoted.from), userID: quoted.from.userID, size: .xs,
                           image: session.avatarURL(of: quoted.from.userID))
                    Text(session.displayName(for: quoted.from)).fontWeight(.medium).foregroundStyle(Palette.ink)
                    Text(previewText(quoted.body)).lineLimit(1)
                } else {
                    Text(missing).italic()
                }
            }
            .apText(.ui)
            .foregroundStyle(Palette.inkMuted)
            .frame(minHeight: Tokens.Size.touchTarget * 0.6, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(quoted == nil)
        .accessibilityLabel("In reply to " + (quoted.map { session.displayName(for: $0.from) } ?? missing.lowercased()))
        .accessibilityHint(quoted == nil ? "" : "Shows the message")
    }
}

/// The web's ReactionBar: 26 pt chips, yours on accent-soft with an accent edge. Each chip takes
/// a 44 pt target. A long press lists who reacted.
struct ReactionBar: View {
    let session: ServerSession
    let reactions: [ReplayStore.ReactionSummary]
    let onReact: (String) -> Void
    let onAdd: () -> Void

    var body: some View {
        FlowLayout(spacing: Tokens.Space.s1) {
            ForEach(reactions, id: \.key) { reaction in
                let mine = session.you.map { reaction.userIDs.contains($0.userID) } ?? false
                let names = reaction.userIDs.map { session.users.user($0).flatMap(UserObject.init).map(session.displayName(for:)) ?? $0 }
                let label = ReactionGlyph.label(reaction.emoji, session.emojiCatalog)
                Button { onReact(reaction.emoji) } label: {
                    chip(mine: mine) {
                        ReactionGlyph(entry: reaction.emoji, catalog: session.emojiCatalog)
                        Text("\(reaction.userIDs.count)").monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .disabled(!session.mayWrite)
                .contextMenu {
                    Section("\(label) from") { ForEach(names, id: \.self) { Text($0) } }
                }
                .accessibilityLabel("\(label), \(names.joined(separator: ", "))")
                .accessibilityAddTraits(mine ? .isSelected : [])
                .accessibilityHint(mine ? "Removes your reaction" : "Adds your reaction")
            }
            if session.server?.has("reactions") == true, session.mayWrite {
                Button(action: onAdd) {
                    chip(mine: false) { Image(systemName: "face.smiling").imageScale(.small) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a reaction")
            }
        }
    }

    private func chip<Label: View>(mine: Bool, @ViewBuilder _ label: () -> Label) -> some View {
        HStack(spacing: Tokens.Space.s1) { label() }
            .apText(.ui)
            .foregroundStyle(mine ? Palette.ink : Palette.inkMuted)
            .padding(.horizontal, Tokens.Space.s2)
            .frame(height: Tokens.Size.chipH)
            .background(mine ? Palette.accentSoft : Palette.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(mine ? Palette.accent : Palette.line))
            .padding(.vertical, (Tokens.Size.touchTarget - Tokens.Size.chipH) / 2)
            .contentShape(Rectangle())
    }
}

/// Lays out children in rows, wrapping as the web's reaction bar does.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in rows(bounds.width, subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (points, CGSize(width: widest, height: y + rowHeight))
    }
}
