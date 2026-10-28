import ApronKit
import SwiftUI

struct MessageRow: View {
    let session: ServerSession
    let message: MessageSnapshot
    let onReact: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.displayName(for: message.from))
                    .font(.subheadline.weight(.semibold))
                Text(date, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isEdited {
                    Text("Edited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let target = message.replyTo {
                ReplyQuote(session: session, target: target)
            }
            if message.isTombstone {
                Text("Message deleted")
                    .italic()
                    .foregroundStyle(.secondary)
            } else {
                Text(rendered(message.body))
                    .textSelection(.enabled)
            }
            if let reactions = session.store.reactions(on: message.messageID) {
                ReactionChips(reactions: reactions, you: session.you?.userID, onReact: onReact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `log_id == message_id` marks the creation (§2.2); a later snapshot is an edit or a move.
    private var isEdited: Bool { !message.isTombstone && message.logID != message.messageID }

    private var date: Date {
        Date(timeIntervalSince1970: (Double(message.messageID.text) ?? 0) / 1000)
    }
}

/// `markdown` bodies render inline CommonMark; AttributedString shows raw HTML as text (§3.5.2).
func rendered(_ body: JSONValue?) -> AttributedString {
    let text = body?["text"]?.stringValue ?? ""
    guard body?["format"]?.stringValue == "markdown" else { return AttributedString(text) }
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

private struct ReplyQuote: View {
    let session: ServerSession
    let target: LogID

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
            if let quoted = session.store.message(target) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.displayName(for: quoted.from)).font(.caption.weight(.semibold))
                    Text(quoted.isTombstone ? AttributedString("Message deleted") : rendered(quoted.body))
                        .font(.caption)
                        .lineLimit(2)
                }
            } else {
                Text("Earlier message").font(.caption)
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReactionChips: View {
    let reactions: [ReplayStore.ReactionSummary]
    let you: String?
    let onReact: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(reactions, id: \.emoji) { reaction in
                    let mine = you.map(reaction.userIDs.contains) ?? false
                    Button { onReact(reaction.emoji) } label: {
                        Text("\(reaction.emoji) \(reaction.userIDs.count)")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(mine ? .accentColor : .secondary)
                    .accessibilityLabel("\(reaction.emoji), \(reaction.userIDs.count)\(mine ? ", including you" : "")")
                }
            }
        }
    }
}
