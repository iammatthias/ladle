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

    var body: some View {
        let font = UIFont.systemFont(ofSize: ScaledRole.size(role, at: fixed ?? dynamic))
        var out = Text("")
        var spoken = ""
        for (key, range) in text.runs[CustomEmojiKey.self] {
            let written = text[range]
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
        return out.accessibilityLabel(spoken)
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

    /// What VoiceOver reads: the emoji, the custom emoji's `alt` or key, or the key.
    static func label(_ entry: String, _ catalog: EmojiCatalog?) -> String {
        catalog?[entry]?.label ?? entry
    }
}

/// The composer's `:shortcode` list: custom emoji whose name, `alt` or tags match, each with its
/// image, key and `alt`. Standard emoji come from the system emoji keyboard.
struct EmojiSuggestions: View {
    let emoji: [CustomEmoji]
    let pick: (CustomEmoji) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(emoji, id: \.key) { emoji in
                Button { pick(emoji) } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        EmojiTile(emoji: emoji, side: Tokens.AvatarSize.sm)
                        Text(emoji.key).apText(.field, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
                        if let alt = emoji.alt { Text(alt).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Tokens.Space.s2)
                    .frame(minHeight: Tokens.Size.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Insert \(emoji.label)")
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

/// A room's, a thread's or the server's description (CommonMark) inside a control: its custom
/// emoji drawn, its links left out so a tap goes to the control.
func descriptionText(_ text: String, _ catalog: EmojiCatalog?) -> AttributedString {
    var out = MessageText.markdown(text, emoji: catalog)
    out.link = nil
    return out
}

extension ServerSession {
    /// Whether showing this message needs the custom emoji catalog: its text could hold a key, or
    /// a reaction is one.
    func needsEmojiCatalog(_ message: MessageSnapshot) -> Bool {
        guard server?.emojiCatalogURL != nil, emojiCatalog == nil else { return false }
        return EmojiKeys.mayHaveKeys(message.plainText)
            || (store.reactions(on: message.messageID) ?? []).contains { !ReactionEntry.isEmojiSequence($0.emoji) }
    }

    /// Fetches the catalog when the text could hold a key.
    func loadEmojiCatalog(for text: String?) async {
        if let text, EmojiKeys.mayHaveKeys(text) { await loadEmojiCatalog() }
    }
}
