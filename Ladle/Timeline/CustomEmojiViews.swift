import ApronKit
import SwiftUI
import UIKit

/// Custom emoji images (`ext:emoji`), drawn once per URL and size at the height of a line of text,
/// in the catalog's aspect ratio (square without one). A `Text` can only hold an image at its own
/// size, so each is drawn at the size it shows. Views read an image and get nil until it loads;
/// the load then redraws them.
@MainActor
@Observable
final class EmojiImages {
    static let shared = EmojiImages()

    private var images: [String: UIImage] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    func image(_ emoji: CustomEmoji, height: CGFloat, reduceMotion: Bool) -> UIImage? {
        let url = emoji.imageURL(reduceMotion: reduceMotion)
        let size = CGSize(width: (height * (emoji.aspectRatio ?? 1)).rounded(), height: height.rounded())
        let key = "\(Int(size.width))x\(Int(size.height))|\(url.absoluteString)"
        if let image = images[key] { return image }
        if asked.insert(key).inserted {
            Task {
                guard let source = try? await MediaLoader.shared.image(url, maxPixel: max(size.width, size.height) * 3) else { return }
                images[key] = Self.fit(source, in: size)
            }
        }
        return nil
    }

    private static func fit(_ image: UIImage, in size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(origin: CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2), size: drawn))
        }
    }
}

/// Text from `MessageText` with each marked custom emoji key drawn as its image at the height of
/// the line, and read by VoiceOver as its `alt`. A key whose image has not loaded shows as written.
struct EmojiText: View {
    let text: AttributedString
    let catalog: EmojiCatalog?
    var role: TextRole = .body
    @Environment(\.fixedTypeSize) private var fixed
    @Environment(\.dynamicTypeSize) private var dynamic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roleFace) private var face

    var body: some View {
        let (line, chips) = drawn()
        if chips > 0 {
            line.textRenderer(LinkChipRenderer())
        } else {
            line
        }
    }

    /// The line, read by VoiceOver as its words, and how many link chips it holds.
    private func drawn() -> (Text, Int) {
        let size = ScaledRole.size(role, at: fixed ?? dynamic)
        let font = UIFont.systemFont(ofSize: size)
        let text = inMonoFace(face?.emphasized(self.text) ?? self.text, size: ScaledRole.size(.ui, at: fixed ?? dynamic))
        var out = Text("")
        var spoken = ""
        var chips = 0
        for (key, chip, range) in text.runs[CustomEmojiKey.self, LinkChipKey.self] {
            let written = text[range]
            if let chip {
                if !chip.isDetail {
                    chips += 1
                    spoken += chip.chip.spoken
                }
                out = Text("\(out)\(LinkChipText.part(chip, written, number: chips))")
                continue
            }
            guard let key, let emoji = catalog?[key], let image = EmojiImages.shared.image(emoji, height: font.lineHeight, reduceMotion: reduceMotion) else {
                out = Text("\(out)\(Text(AttributedString(written)))")
                spoken += String(written.characters)
                continue
            }
            // Adjacent copies of one key share a run.
            for _ in 0 ..< written.characters.count / key.count {
                out = Text("\(out)\(Text(Image(uiImage: image)).baselineOffset(font.descender))")
                spoken += emoji.label
            }
        }
        return (out.accessibilityLabel(spoken), chips)
    }

    /// Inline code in the theme's `--font-mono` at the ui size on the `--bg-300` ground, as the
    /// web's `.ap-msg-text code`, in place of the system monospaced face the `.code` intent alone
    /// draws in. A run of `Text` has no padding or corner radius, so the ground is square.
    private func inMonoFace(_ text: AttributedString, size: CGFloat) -> AttributedString {
        var out = text
        let mono = BundledFonts.font(ActiveTheme.shared.theme.fonts.list(.mono), size: size, weight: .regular, mono: true).font
        for run in out.runs {
            guard var intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            intent.remove(.code)
            out[run.range].inlinePresentationIntent = intent.isEmpty ? nil : intent
            out[run.range].font = mono
            out[run.range].backgroundColor = Palette.hover
        }
        return out
    }
}

/// A reaction entry in a chip: an emoji sequence as text, a custom emoji the catalog has as its
/// image, and any other key as a dashed placeholder (§4.7).
struct ReactionGlyph: View {
    let entry: String
    let catalog: EmojiCatalog?
    @Environment(\.fixedTypeSize) private var fixed
    @Environment(\.dynamicTypeSize) private var dynamic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let height = UIFont.systemFont(ofSize: ScaledRole.size(.ui, at: fixed ?? dynamic)).lineHeight
        if ReactionEntry.isEmojiSequence(entry) {
            Text(entry)
        } else if let emoji = catalog?[entry] {
            Group {
                if let image = EmojiImages.shared.image(emoji, height: height, reduceMotion: reduceMotion) {
                    Image(uiImage: image)
                } else {
                    Color.clear
                }
            }
            .frame(width: (height * (emoji.aspectRatio ?? 1)).rounded(), height: height.rounded())
        } else {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Palette.inkMuted, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: height * 0.8, height: height * 0.8)
        }
    }
}

/// The composer's `:shortcode` list, as the web's: the server's custom emoji that match, then
/// the standard ones, each its glyph or image, `:shortcode:` and name.
struct EmojiSuggestions: View {
    let emoji: [EmojiSuggestion]
    let rows: SuggestionRows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(emoji.enumerated()), id: \.element.inserted) { index, emoji in
                Button { rows.pick(index) } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        Group {
                            if let custom = emoji.custom {
                                EmojiTile(emoji: custom, side: Tokens.AvatarSize.sm)
                            } else {
                                Text(emoji.inserted).font(.system(size: 20))
                            }
                        }
                        .frame(width: Tokens.AvatarSize.sm, height: Tokens.AvatarSize.sm)
                        .accessibilityHidden(true)
                        Text(":\(emoji.id):").apText(.field, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
                        Text(emoji.name).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Tokens.Space.s2)
                    .frame(minHeight: Tokens.Size.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .suggestionRow(index, of: rows)
                .accessibilityLabel("Insert \(emoji.name)")
            }
        }
        .padding(Tokens.Space.s1)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
    }
}

/// A custom emoji at a fixed size, for the picker and the `:` list.
struct EmojiTile: View {
    let emoji: CustomEmoji
    let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let image = EmojiImages.shared.image(emoji, height: side, reduceMotion: reduceMotion) {
                Image(uiImage: image)
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel(emoji.label)
    }
}

/// A room's, a thread's or the server's description (CommonMark) inside a control, its blocks
/// a line each: its custom emoji drawn, its links left out so a tap goes to the control.
func descriptionText(_ text: String, _ catalog: EmojiCatalog?) -> AttributedString {
    var out = MessageBlock.flattened(MessageText.markdown(text, emoji: catalog))
    out.link = nil
    return out
}
