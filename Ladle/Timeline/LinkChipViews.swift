import ApronKit
import SwiftUI

/// An Apron link chip (`LinkChipKey`) in a line of `Text`, as apron-web's `ap-linkchip` (#119):
/// its kind's icon (a message bubble, a hash, a corner arrow, a globe for another server; a
/// user's reads as a mention, with none), its label, and its detail, `styled` colouring the
/// words. Another server's ends with an arrow, since opening it leaves this server.
/// `LinkChipRenderer` draws the chip behind them.
enum LinkChipText {
    /// One part of the chip. `number` tells this chip from the next for the renderer.
    static func part(_ part: LinkChipPart, _ written: AttributedSubstring, number: Int) -> Text {
        let chip = part.chip
        let mark = LinkChipMark(number: number, elsewhere: chip.kind == .elsewhere)
        let edge = Text("\u{202F}")
        var text = Text(AttributedString(written))
        if !part.isDetail, let symbol = symbol(chip.kind) {
            let icon = Text(Image(systemName: symbol)).foregroundStyle(mark.elsewhere ? Palette.ink : Palette.denim)
            text = Text("\(edge)\u{2060}\(icon)\u{2060}\(edge)\u{2060}\(text)")
        }
        if part.isDetail || chip.detail == nil {
            let arrow = mark.elsewhere ? Text("\u{2060}\u{00A0}\u{2197}").foregroundStyle(Palette.inkMuted) : Text("")
            text = Text("\(text)\(arrow)\u{2060}\(edge)")
        }
        return text.customAttribute(mark)
    }

    private static func symbol(_ kind: LinkChip.Kind) -> String? {
        switch kind {
        case .message: "bubble.left"
        case .room: "number"
        case .thread: "arrow.turn.down.right"
        case .elsewhere: "globe"
        case .user: nil
        }
    }
}

/// Which link chip a run of laid-out text belongs to.
struct LinkChipMark: TextAttribute {
    let number: Int
    let elsewhere: Bool
}

/// Draws each link chip behind its words, a piece per line it wraps onto (the web's
/// `box-decoration-break: clone`): denim-soft for a place on this server, a `line-strong` outline
/// for one on another server.
struct LinkChipRenderer: TextRenderer {
    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            var pieces: [(mark: LinkChipMark, rect: CGRect)] = []
            for run in line {
                guard let mark = run[LinkChipMark.self] else { continue }
                let rect = run.typographicBounds.rect
                if let last = pieces.last, last.mark.number == mark.number {
                    pieces[pieces.count - 1].rect = last.rect.union(rect)
                } else {
                    pieces.append((mark, rect))
                }
            }
            for piece in pieces {
                let shape = RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                if piece.mark.elsewhere {
                    ctx.stroke(shape.path(in: piece.rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Palette.lineStrong), lineWidth: 1)
                } else {
                    ctx.fill(shape.path(in: piece.rect), with: .color(Palette.denimSoft))
                }
            }
            ctx.draw(line)
        }
    }
}
