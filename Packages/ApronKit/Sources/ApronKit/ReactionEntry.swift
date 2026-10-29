import Foundation

/// A `reactions` entry (§4.7): one emoji sequence (UTS #51), or a key for another kind of
/// reaction, such as a custom emoji's `:name:` (EXTENSIONS.md, `ext:emoji`).
public enum ReactionEntry {
    /// The entry as clients compare it: without U+FE0F, so ❤ and ❤️ are one.
    public static func key(_ entry: String) -> String {
        String(String.UnicodeScalarView(entry.unicodeScalars.filter { $0 != "\u{FE0F}" }))
    }

    /// Whether the entry is one emoji sequence: a flag, a keycap, or a pictograph with its skin
    /// tones, U+FE0F selectors, tags and ZWJ joins, such as 👍🏽, 🏳️‍🌈 or 👨‍👩‍👧. Anything else is a key.
    public static func isEmojiSequence(_ entry: String) -> Bool {
        sequence.firstMatch(in: entry, range: NSRange(entry.startIndex..., in: entry)) != nil
    }

    /// apron-web's `EMOJI_SEQUENCE`, in ICU's syntax.
    private static let sequence = try! NSRegularExpression(pattern: #"""
        ^(?:\p{Regional_Indicator}{2}|[#*0-9]\x{FE0F}?\x{20E3}|\p{Extended_Pictographic}(?:\p{Emoji_Modifier}|\x{FE0F}|[\x{E0020}-\x{E007F}])*(?:\x{200D}\p{Extended_Pictographic}(?:\p{Emoji_Modifier}|\x{FE0F})*)*)$
        """#)
}
