/// The direction of what users write (§3.5.2). Each user-written string takes its direction from
/// its own first strong letter, isolated from the text around it, and its bidirectional
/// embeddings and overrides are ignored, so a name or a file title can't reorder the words around
/// it or show its own characters out of order. Only for display: what Ladle keeps and sends
/// stays as written, so an edit sends back every character its author typed.
public enum TextDirection: Hashable, Sendable {
    case leftToRight, rightToLeft

    /// The direction of the first strong letter, or nil when there is none (digits, emoji,
    /// punctuation).
    public init?(of text: some StringProtocol) {
        for scalar in text.unicodeScalars {
            if Self.isRightToLeft(scalar) {
                self = .rightToLeft
                return
            }
            if scalar.properties.isAlphabetic {
                self = .leftToRight
                return
            }
        }
        return nil
    }

    /// The text without U+202A to U+202E.
    public static func withoutOverrides(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isOverride) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !isOverride($0) }))
    }

    /// The text without overrides, between U+2068 FIRST STRONG ISOLATE and U+2069 POP DIRECTIONAL
    /// ISOLATE, for a user's string set among words of the app's own.
    public static func isolated(_ text: String) -> String {
        "\u{2068}\(withoutOverrides(text))\u{2069}"
    }

    private static func isOverride(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A ... 0x202E).contains(scalar.value)
    }

    /// Letters of the scripts written right to left: Hebrew, Arabic, Syriac, Thaana, NKo,
    /// Samaritan, Mandaic and their presentation forms, and the historic ones above the BMP.
    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isAlphabetic else { return false }
        switch scalar.value {
        case 0x0590 ... 0x08FF, 0xFB1D ... 0xFDFF, 0xFE70 ... 0xFEFF, 0x10800 ... 0x10FFF, 0x1E800 ... 0x1EFFF: return true
        default: return false
        }
    }
}
