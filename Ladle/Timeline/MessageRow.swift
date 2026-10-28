import ApronKit
import SwiftUI

/// The web's Message: an avatar in a 32 pt gutter, the sender and time, the reply it answers
/// above, the text, embeds, and reactions. A message that mentions you sits on accent-soft with
/// an accent bar, as the web marks it.
struct MessageRow: View {
    let session: ServerSession
    let message: MessageSnapshot
    let continues: Bool
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
            if let target = message.replyTo, !message.isTombstone {
                ReplyQuote(session: session, target: target, onJump: onJump)
                    .padding(.leading, compact ? 0 : Tokens.AvatarSize.md + Tokens.Space.s3 - Tokens.Space.s1)
            }
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                if compact {
                    EmptyView()
                } else if continues {
                    Color.clear.frame(width: Tokens.AvatarSize.md, height: 1)
                } else {
                    Avatar(name: name, userID: message.from.userID).padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !continues {
                        HStack(alignment: .center, spacing: Tokens.Space.s2) {
                            if compact { Avatar(name: name, userID: message.from.userID, size: .sm) }
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
        .background(mentionsYou ? Palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(alignment: .leading) {
            if mentionsYou {
                Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, Tokens.Space.s1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(name: name, mentionsYou: mentionsYou))
    }

    private func head(_ name: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            Text(name).apText(.body, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
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
        if message.isTombstone {
            Text("Message deleted").apText(.body).italic().foregroundStyle(Palette.inkMuted)
        } else {
            if !message.plainText.isEmpty {
                Text(rendered(message.body, mentions: mentionNames, you: session.you?.userID))
                    .apText(.body)
                    .foregroundStyle(Palette.ink)
                    .tint(Palette.denim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let room = message.prevRoomID {
                Text("Moved from \(Text(session.title(of: room)).foregroundStyle(Palette.denim))")
                    .apText(.sm).italic().foregroundStyle(Palette.inkMuted)
                    .padding(.top, Tokens.Space.s1)
            }
            if !message.embeds.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    ForEach(Array(message.embeds.enumerated()), id: \.offset) { _, embed in EmbedCard(embed: embed) }
                }
                .padding(.top, Tokens.Space.s2)
            }
            if let reactions = session.store.reactions(on: message.messageID) {
                ReactionBar(session: session, reactions: reactions, onReact: onReact, onAdd: onAddReaction)
                    .padding(.top, Tokens.Space.s1)
            }
        }
    }

    /// Each mentioned user's names, as `@name` may appear in the text.
    private var mentionNames: [String: String] {
        Dictionary(message.mentionIDs.map { id in
            (id, session.users.user(id).flatMap(UserObject.init).map(session.displayName(for:)) ?? id)
        }, uniquingKeysWith: { first, _ in first })
    }

    private func accessibilityText(name: String, mentionsYou: Bool) -> String {
        var parts = [name]
        if mentionsYou { parts.append("mentions you") }
        if message.replyTo != nil, !message.isTombstone {
            let target = message.replyTo.flatMap(session.store.message)
            parts.append("replying to " + (target.map { session.displayName(for: $0.from) } ?? "an unavailable message"))
        }
        parts.append(message.isTombstone ? "Message deleted" : message.plainText)
        if let room = message.prevRoomID { parts.append("moved from \(session.title(of: room))") }
        for embed in message.embeds { parts.append(EmbedCard.summary(embed)) }
        if message.isEdited { parts.append("edited") }
        parts.append(message.date.formatted(date: .omitted, time: .shortened))
        if let reactions = session.store.reactions(on: message.messageID), !message.isTombstone {
            parts.append(reactions.map { "\($0.emoji) \($0.userIDs.count)" }.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }
}

/// `markdown` bodies render inline CommonMark; raw HTML shows as text (§3.5.2). Mentions show as
/// the web's chips: denim on denim-soft, and accent with on-accent for you.
func rendered(_ body: JSONValue?, mentions: [String: String] = [:], you: String? = nil) -> AttributedString {
    let text = body?["text"]?.stringValue ?? ""
    var out: AttributedString
    if body?["format"]?.stringValue == "markdown" {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        out = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    } else {
        out = AttributedString(text)
    }
    for (id, name) in mentions {
        for token in Set(["@" + name, "@" + id]) {
            var search = out.startIndex ..< out.endIndex
            while let range = out[search].range(of: token) {
                out[range].backgroundColor = id == you ? Palette.accent : Palette.denimSoft
                out[range].foregroundColor = id == you ? Palette.onAccent : Palette.denim
                out[range].inlinePresentationIntent = .stronglyEmphasized
                search = range.upperBound ..< out.endIndex
            }
        }
    }
    return out
}

/// The web's ReplyPreview: a bent line, the quoted sender's face and name, and one line of their
/// text. Tapping it jumps to the message. A target this client does not have says so.
struct ReplyQuote: View {
    let session: ServerSession
    let target: LogID
    var onJump: (LogID) -> Void = { _ in }

    var body: some View {
        let quoted = session.store.message(target)
        Button { onJump(target) } label: {
            HStack(spacing: Tokens.Space.s1) {
                Image(systemName: "arrow.turn.up.right").imageScale(.small).foregroundStyle(Palette.lineStrong)
                    .scaleEffect(x: -1)
                if let quoted {
                    Avatar(name: session.displayName(for: quoted.from), userID: quoted.from.userID, size: .xs)
                    Text(session.displayName(for: quoted.from)).fontWeight(.medium).foregroundStyle(Palette.ink)
                    Text(quoted.isTombstone ? AttributedString("Message deleted") : rendered(quoted.body))
                        .lineLimit(1)
                } else {
                    Text("Message unavailable").italic()
                }
            }
            .apText(.ui)
            .foregroundStyle(Palette.inkMuted)
            .frame(minHeight: Tokens.Size.touchTarget * 0.6, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(quoted == nil)
        .accessibilityLabel("In reply to " + (quoted.map { session.displayName(for: $0.from) } ?? "a message that is unavailable"))
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
            ForEach(reactions, id: \.emoji) { reaction in
                let mine = session.you.map { reaction.userIDs.contains($0.userID) } ?? false
                let names = reaction.userIDs.map { session.users.user($0).flatMap(UserObject.init).map(session.displayName(for:)) ?? $0 }
                Button { onReact(reaction.emoji) } label: {
                    chip(mine: mine) {
                        Text(reaction.emoji)
                        Text("\(reaction.userIDs.count)").monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Section("\(reaction.emoji) from") { ForEach(names, id: \.self) { Text($0) } }
                }
                .accessibilityLabel("\(reaction.emoji), \(names.joined(separator: ", "))")
                .accessibilityAddTraits(mine ? .isSelected : [])
                .accessibilityHint(mine ? "Removes your reaction" : "Adds your reaction")
            }
            if session.server?.has("reactions") == true {
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

/// An embed (§4.8). OpenGraph renders as the web's LinkCard. Every other kind, including
/// `iframe` and `html`, which Ladle does not load, renders as the labeled fallback card §3.5.2
/// requires: the kind, and its title, URL or text.
struct EmbedCard: View {
    let embed: JSONValue

    var body: some View {
        let og = embed["og"]
        let url = embed["url"]?.stringValue.flatMap(URL.init(string:))
        let card = VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            if let og, og["title"] != nil || og["description"] != nil {
                if let site = og["site_name"]?.stringValue ?? url?.host() {
                    Text(site).apText(.sm).foregroundStyle(Palette.inkMuted)
                }
                if let title = og["title"]?.stringValue {
                    Text(title).apText(.ui, .semibold).foregroundStyle(Palette.denim)
                }
                if let description = og["description"]?.stringValue {
                    Text(description).apText(.ui).foregroundStyle(Palette.ink).lineLimit(3)
                }
            } else {
                Label(Self.kindLabel(embed), systemImage: embed["kind"]?.stringValue == "upload" ? "doc" : "square.dashed")
                    .apText(.sm, .semibold).foregroundStyle(Palette.inkMuted)
                if let title = embed["title"]?.stringValue {
                    Text(title).apText(.ui, .semibold).foregroundStyle(Palette.ink)
                }
                if let detail = embed["text"]?.stringValue ?? url?.absoluteString {
                    Text(detail).apText(.ui).foregroundStyle(url == nil ? Palette.ink : Palette.denim).lineLimit(3)
                }
            }
        }
        .frame(maxWidth: Tokens.Size.embedMaxW, alignment: .leading)
        .padding(Tokens.Space.s3)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        if let url, ["http", "https"].contains(url.scheme ?? "") {
            Link(destination: url) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }

    static func kindLabel(_ embed: JSONValue) -> String {
        let kind = embed["kind"]?.stringValue ?? "embed"
        return kind == "upload" ? "File" : kind.prefix(1).uppercased() + kind.dropFirst()
    }

    static func summary(_ embed: JSONValue) -> String {
        [embed["og"]?["title"]?.stringValue ?? kindLabel(embed), embed["url"]?.stringValue].compactMap { $0 }.joined(separator: ", ")
    }
}
