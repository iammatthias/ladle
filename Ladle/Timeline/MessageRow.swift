import ApronKit
import SwiftUI

/// The web's Message: an avatar in a 32 pt gutter, the sender and time, the reply it answers
/// above, the text, embeds, and reactions. A message that mentions you sits on accent-soft with
/// an accent bar, as the web marks it. One a link opened to is highlighted on `hover`, as the
/// web's `ap-msg-highlighted`. One with a reminder has an accent edge and says when it is due.
struct MessageRow: View {
    let session: ServerSession
    let message: MessageSnapshot
    let continues: Bool
    var highlighted = false
    var reminderDue: Date?
    var onClearReminder: () -> Void = {}
    var onReact: (String) -> Void = { _ in }
    var onAddReaction: () -> Void = {}
    var onJump: (LogID) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.fixedTypeSize) private var fixedTypeSize
    @Environment(\.liveSessions) private var liveSessions
    @Environment(\.openURL) private var openURL

    var body: some View {
        let row = MessageRowModel(message, in: session, sessions: liveSessions.find)
        let name = row.name
        // At accessibility sizes the avatar gutter gives its width back to the text: a small face
        // rides in the name line instead.
        let compact = (fixedTypeSize ?? typeSize).isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            if let reminderDue {
                ReminderBadge(due: reminderDue, clear: onClearReminder)
                    .padding(.leading, compact ? 0 : Tokens.AvatarSize.md + Tokens.Space.s3)
            }
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
                            head(row)
                        }
                    }
                    content(row)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, Tokens.Space.s1)
        .padding(.horizontal, Tokens.Space.s2)
        .background(highlighted ? Palette.hover : row.mentionsYou ? Palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay {
            if reminderDue != nil {
                RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.accent, lineWidth: 1.5).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .leading) {
            if row.mentionsYou {
                Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, Tokens.Space.s1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.spoken(reminderDue: reminderDue, now: .now))
        .task(id: session.server?.emojiCatalogURL) {
            if session.needsEmojiCatalog(message) { await session.loadEmojiCatalog() }
        }
    }

    private func head(_ row: MessageRowModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            Text(row.name).apText(.body, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
                .layoutPriority(1)
            if !row.roles.isEmpty {
                RoleBadges(roles: row.roles).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
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
    private func content(_ row: MessageRowModel) -> some View {
        if !message.plainText.isEmpty {
            EmojiText(text: styled(row.text), catalog: session.emojiCatalog)
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
        if !row.cards.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                ForEach(row.cards) { card in
                    PlaceCardView(card: card) { card.link.webURL.map { openURL($0) } }
                }
            }
            .padding(.top, Tokens.Space.s2)
        }
        if !row.embeds.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                ForEach(row.embeds, id: \.index) { index, embed in
                    let view = EmbedView(session: session, embed: embed, mediaID: MediaItem.id(message, index))
                    if let unfurl = row.unfurl, index == row.unfurledEmbed {
                        FetchedLinkCard(url: unfurl) { view }
                    } else {
                        view
                    }
                }
            }
            .padding(.top, Tokens.Space.s2)
        }
        if let unfurl = row.unfurl, row.unfurledEmbed == nil {
            FetchedLinkCard(url: unfurl, inset: Tokens.Space.s2) { EmptyView() }
        }
        if let reactions = session.store.reactions(on: message.messageID) {
            ReactionBar(session: session, reactions: reactions, onReact: onReact, onAdd: onAddReaction)
                .padding(.top, Tokens.Space.s1)
        }
    }
}

/// Rendered text (`MessageText.attributed`) with its chips drawn as the web's: a room
/// (`RoomReferenceKey`) and a mention (`MentionKey`) in denim on denim-soft, a mention of you in
/// on-accent on accent.
func styled(_ text: AttributedString) -> AttributedString {
    var out = text
    for run in out.runs where run[RoomReferenceKey.self] != nil {
        out[run.range].backgroundColor = Palette.denimSoft
        out[run.range].foregroundColor = Palette.denim
        out[run.range].inlinePresentationIntent = .stronglyEmphasized
    }
    for run in out.runs {
        guard let chip = run[MentionKey.self] else { continue }
        out[run.range].backgroundColor = chip.isYou ? Palette.accent : Palette.denimSoft
        out[run.range].foregroundColor = chip.isYou ? Palette.onAccent : Palette.denim
        out[run.range].inlinePresentationIntent = .stronglyEmphasized
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
                let label = ReactionEntry.label(reaction.emoji, catalog: session.emojiCatalog)
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
