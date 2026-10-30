import ApronKit
import SwiftUI

/// The web's LinkCard for an Apron link (`PlaceCard`): a message as "Sender in #room" over its
/// first lines, and a room or thread as its title, a lock when private, and its member count.
/// Denim on denim-soft, as the thread cards, or the private color with its lock. A tap opens the
/// place through `open`.
struct PlaceCardView: View {
    let card: PlaceCard
    let open: () -> Void

    var body: some View {
        let tint = card.isPrivate ? Palette.private : Palette.denim
        Button(action: open) {
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                HStack(spacing: Tokens.Space.s1) {
                    if card.isPrivate { Lock(tint: tint) }
                    headline.foregroundStyle(tint).lineLimit(1)
                }
                switch card.content {
                case .message(_, let preview):
                    Text(TextDirection.isolated(preview)).foregroundStyle(Palette.ink).lineLimit(3)
                case .room:
                    if let count = card.memberCount {
                        Text(count == 1 ? "1 member" : "\(count) members").apText(.sm).foregroundStyle(Palette.inkMuted)
                    }
                }
            }
            .apText(.ui)
            .padding(.vertical, Tokens.Space.s1_5)
            .padding(.leading, Tokens.Space.s3)
            .padding(.trailing, Tokens.Space.s3)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(minHeight: Tokens.Size.touchTarget)
            .background(card.isPrivate ? Palette.privateSoft : Palette.denimSoft, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: 3).padding(.vertical, Tokens.Space.s1).accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.spoken)
        .accessibilityHint(card.content == .room ? "Opens the \(card.isThread ? "thread" : "room")" : "Shows the message")
    }

    /// A room as `#title`, a thread by its title alone, as the web's card names them.
    private var place: String { (card.isThread ? "" : "#") + TextDirection.isolated(card.roomTitle) }

    private var headline: Text {
        switch card.content {
        case .message(let sender, _): Text("\(Text(TextDirection.isolated(sender)).fontWeight(.semibold)) in \(place)")
        case .room: Text(place).fontWeight(.semibold)
        }
    }
}
