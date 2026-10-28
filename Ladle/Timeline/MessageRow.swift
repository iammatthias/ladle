import ApronKit
import SwiftUI

/// One message in the direction's layout: a flat log, a dense IRC-style line, or a bubble.
struct MessageRow: View {
    let session: ServerSession
    let message: MessageSnapshot
    let continues: Bool
    let onReact: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        switch theme.layout {
        case .log: LogMessage(session: session, message: message, continues: continues, onReact: onReact)
        case .dense: DenseMessage(session: session, message: message)
        case .bubbles: BubbleMessage(session: session, message: message, continues: continues, onReact: onReact)
        }
    }
}

/// `markdown` bodies render inline CommonMark; AttributedString shows raw HTML as text (§3.5.2).
func rendered(_ body: JSONValue?) -> AttributedString {
    let text = body?["text"]?.stringValue ?? ""
    guard body?["format"]?.stringValue == "markdown" else { return AttributedString(text) }
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

private struct LogMessage: View {
    let session: ServerSession
    let message: MessageSnapshot
    let continues: Bool
    let onReact: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let palette = theme.palette
        HStack(alignment: .top, spacing: 10) {
            if continues {
                Color.clear.frame(width: theme.avatarSize, height: 1)
            } else {
                Avatar(name: session.displayName(for: message.from), userID: message.from.userID,
                       presence: session.presence(of: message.from.userID), size: theme.avatarSize)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !continues {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.displayName(for: message.from))
                            .font(theme.font(.subheadline, weight: .semibold))
                            .foregroundStyle(palette.text.color)
                        Text(message.date, format: .dateTime.hour().minute())
                            .font(theme.font(.caption).monospacedDigit())
                            .foregroundStyle(palette.secondary.color)
                    }
                }
                if let target = message.replyTo {
                    ReplyQuote(session: session, target: target)
                }
                MessageBody(message: message)
                    .foregroundStyle(palette.text.color)
                if let reactions = session.store.reactions(on: message.messageID) {
                    ReactionChips(reactions: reactions, you: session.you?.userID, onReact: onReact)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DenseMessage: View {
    let session: ServerSession
    let message: MessageSnapshot
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let palette = theme.palette
        let mine = message.from.userID == session.you?.userID
        // At accessibility sizes the time gutter moves above the line, so text keeps the width.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            Text(message.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(theme.font(.caption, .mono))
                .foregroundStyle(palette.secondary.color)
            VStack(alignment: .leading, spacing: 2) {
                if let target = message.replyTo {
                    ReplyQuote(session: session, target: target)
                }
                let nick = Text(session.displayName(for: message.from))
                    .font(theme.font(.callout, .mono, weight: .bold))
                    .foregroundStyle(mine ? palette.accent.color : palette.text.color)
                let presence = session.presence(of: message.from.userID).map {
                    Text(Image(systemName: $0.symbol)).font(theme.font(.caption2)).foregroundStyle($0.tint)
                } ?? Text("")
                if message.isTombstone {
                    Text("\(presence) \(nick) \(Text("deleted a message").italic().foregroundStyle(palette.secondary.color))")
                        .font(theme.font(.callout))
                } else {
                    Text("\(presence) \(nick)  \(Text(rendered(message.body)).foregroundStyle(palette.text.color))\(message.isEdited ? Text(" (edited)").foregroundStyle(palette.secondary.color) : Text(""))")
                        .font(theme.font(.callout))
                        .textSelection(.enabled)
                }
                if let reactions = session.store.reactions(on: message.messageID) {
                    Text(reactions.map { "\($0.emoji) \($0.userIDs.count)" }.joined(separator: "   "))
                        .font(theme.font(.caption, .mono))
                        .foregroundStyle(palette.secondary.color)
                        .accessibilityLabel(reactions.map { "\($0.emoji), \($0.userIDs.count)" }.joined(separator: "; "))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BubbleMessage: View {
    let session: ServerSession
    let message: MessageSnapshot
    let continues: Bool
    let onReact: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let palette = theme.palette
        let mine = message.from.userID == session.you?.userID
        HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 56) }
            if !mine {
                if continues {
                    Color.clear.frame(width: theme.avatarSize, height: 1)
                } else {
                    Avatar(name: session.displayName(for: message.from), userID: message.from.userID,
                           presence: session.presence(of: message.from.userID), size: theme.avatarSize, rounded: true)
                        .padding(.top, 20)
                }
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !continues && !mine {
                    Text(session.displayName(for: message.from))
                        .font(theme.font(.caption, weight: .semibold))
                        .foregroundStyle(palette.secondary.color)
                        .padding(.leading, 12)
                }
                if message.isTombstone {
                    Text("Message deleted")
                        .font(theme.font(.subheadline).italic())
                        .foregroundStyle(palette.secondary.color)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(palette.secondary.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if let target = message.replyTo {
                            ReplyQuote(session: session, target: target, onBubble: mine)
                        }
                        Text(rendered(message.body))
                            .font(theme.font(.body))
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(mine ? palette.onMine.color : palette.text.color)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(mine ? palette.mine.color : palette.theirs.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                if let reactions = session.store.reactions(on: message.messageID) {
                    ReactionChips(reactions: reactions, you: session.you?.userID, onReact: onReact)
                }
                if !continues || message.isEdited {
                    HStack(spacing: 4) {
                        Text(message.date, format: .dateTime.hour().minute())
                        if message.isEdited { Text("· Edited") }
                    }
                    .font(theme.font(.caption2).monospacedDigit())
                    .foregroundStyle(palette.secondary.color)
                    .padding(.horizontal, 12)
                }
            }
            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// The text, or the deleted and edited markers, for the log layout.
private struct MessageBody: View {
    let message: MessageSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        if message.isTombstone {
            Label("Message deleted", systemImage: "trash")
                .font(theme.font(.subheadline).italic())
                .foregroundStyle(theme.palette.secondary.color)
        } else {
            Text("\(Text(rendered(message.body)))\(message.isEdited ? Text("  edited").font(theme.font(.caption)).foregroundStyle(theme.palette.secondary.color) : Text(""))")
                .font(theme.font(.body))
                .textSelection(.enabled)
        }
    }
}

struct ReplyQuote: View {
    let session: ServerSession
    let target: LogID
    var onBubble = false
    @Environment(\.theme) private var theme

    var body: some View {
        let palette = theme.palette
        let tint = onBubble ? palette.onMine.color : palette.secondary.color
        HStack(spacing: 6) {
            if theme.layout == .dense {
                Image(systemName: "arrow.turn.down.right").font(.caption2)
            } else {
                RoundedRectangle(cornerRadius: 1).fill(onBubble ? palette.onMine.color.opacity(0.6) : palette.accent.color).frame(width: 3)
            }
            if let quoted = session.store.message(target) {
                Text("\(Text(session.displayName(for: quoted.from)).fontWeight(.semibold))  \(Text(quoted.isTombstone ? AttributedString("Message deleted") : rendered(quoted.body)))")
                    .lineLimit(theme.layout == .dense ? 1 : 2)
            } else {
                Text("Earlier message")
            }
        }
        .font(theme.font(theme.layout == .dense ? .caption : .footnote, theme.layout == .dense ? .mono : nil))
        .foregroundStyle(tint)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("In reply to " + (session.store.message(target).map { session.displayName(for: $0.from) } ?? "an earlier message"))
    }
}

/// Reaction chips; your own reactions are filled and outlined. Each chip is a 44 pt target.
struct ReactionChips: View {
    let reactions: [ReplayStore.ReactionSummary]
    let you: String?
    let onReact: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let palette = theme.palette
        HStack(spacing: 6) {
            ForEach(reactions, id: \.emoji) { reaction in
                let mine = you.map(reaction.userIDs.contains) ?? false
                Button { onReact(reaction.emoji) } label: {
                    HStack(spacing: 4) {
                        Text(reaction.emoji)
                        Text("\(reaction.userIDs.count)")
                            .fontWeight(mine ? .bold : .regular)
                            .monospacedDigit()
                    }
                    .font(theme.font(.footnote))
                    .foregroundStyle(mine ? palette.accent.color : palette.secondary.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(mine ? palette.accent.color.opacity(0.14) : palette.surface.color, in: Capsule())
                    .overlay(Capsule().strokeBorder(mine ? palette.accent.color : palette.separator.color, lineWidth: mine ? 1.5 : 1))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(reaction.emoji), \(reaction.userIDs.count)\(mine ? ", including you" : "")")
            }
        }
    }
}
