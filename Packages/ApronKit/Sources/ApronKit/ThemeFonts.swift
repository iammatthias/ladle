import Foundation

/// One family in a CSS `font-family` list, as iOS can show it.
public enum FontFamily: Hashable, Sendable {
    /// San Francisco: `system-ui`, `-apple-system`, `BlinkMacSystemFont`, `sans-serif`.
    case system
    /// SF Mono: `ui-monospace`, `SF Mono`, `Menlo`, `monospace`.
    case systemMono
    /// SF Rounded: `ui-rounded`.
    case rounded
    /// New York: `ui-serif`, `serif`.
    case serif
    /// A family by name, shown when the device has it: one Ladle bundles or one installed.
    case named(String)

    /// Reads a `font-family` list, quotes removed, generic and system names mapped.
    public static func list(_ value: String) -> [FontFamily] {
        CSSValue.topLevel(value, separator: ",").compactMap { entry in
            var name = entry.trimmingCharacters(in: .jsWhitespace)
            if name.count >= 2, let first = name.first, first == "\"" || first == "'", name.last == first {
                name = String(name.dropFirst().dropLast())
            }
            guard !name.isEmpty else { return nil }
            switch name.lowercased() {
            case "system-ui", "-apple-system", "blinkmacsystemfont", "sans-serif": return .system
            case "ui-monospace", "sf mono", "menlo", "monospace": return .systemMono
            case "ui-rounded": return .rounded
            case "ui-serif", "serif": return .serif
            default: return .named(name)
            }
        }
    }
}

/// The three faces a theme sets (`--font-sans`, `--font-chat`, `--font-mono`), each a list to
/// take the first available family from, as the browser does.
public struct ThemeFonts: Hashable, Sendable {
    /// The interface: every text role but messages and code.
    public let sans: [FontFamily]
    /// Message text.
    public let chat: [FontFamily]
    /// Code, embeds and commands.
    public let mono: [FontFamily]

    public init(sans: [FontFamily], chat: [FontFamily], mono: [FontFamily]) {
        (self.sans, self.chat, self.mono) = (sans, chat, mono)
    }

    /// The faces a theme's own values give, tokens.css's where it sets none.
    init(own: [String: String]) {
        func list(_ name: String) -> [FontFamily] {
            let lookup: (String) -> String? = { own[$0] ?? WebTokens.dark[$0] }
            return lookup(name).flatMap { CSSValue.substitute($0, lookup: lookup) }.map(FontFamily.list) ?? []
        }
        self.init(sans: list("--font-sans"), chat: list("--font-chat"), mono: list("--font-mono"))
    }
}

/// A variation axis a face carries (`wght`, `ital`, `slnt`, …), by its four-letter tag.
public struct FontAxis: Hashable, Sendable {
    public let tag: String
    public let minimum: Double
    public let maximum: Double

    public init(tag: String, minimum: Double, maximum: Double) {
        (self.tag, self.minimum, self.maximum) = (tag, minimum, maximum)
    }

    /// The tag as the number CoreText names an axis by: its four letters, big-endian.
    public static func code(_ tag: String) -> Int {
        tag.unicodeScalars.reduce(0) { $0 << 8 | Int($1.value & 0xFF) }
    }

    /// The four letters of a CoreText axis number.
    public static func tag(_ code: Int) -> String {
        String(String.UnicodeScalarView((0 ..< 4).reversed().compactMap { UnicodeScalar(UInt8((code >> ($0 * 8)) & 0xFF)) }))
    }
}

/// How a face draws `font-style: italic`, as the browser does (CSS Fonts 4 §2.4): with the
/// family's italic cut, else its `ital` axis at 1, else as an oblique the renderer synthesizes
/// from the upright. A `slnt` axis is not used: the spec gives `slnt` to `oblique` values and
/// `ital` to `italic`. Recursive and Nunito, as apron-web bundles them, carry neither, and SF
/// Rounded has no italic cut, so all three come out oblique, as they do on the web.
public enum Italic: Equatable, Sendable {
    case face
    case axis(tag: String, value: Double)
    /// A horizontal shear: x moves by `skew` times y.
    case oblique(skew: Double)

    /// The synthetic oblique's slant, 14 degrees: CSS's angle for an `oblique` with none given
    /// (CSS Fonts 4 §2.4) and WebKit's `FontCascade::syntheticObliqueAngle()`, applied as
    /// `tan(14°)` (WebKit r268638).
    public static let syntheticSkew = tan(14 * Double.pi / 180)

    public static func choose(hasItalicFace: Bool, axes: [FontAxis]) -> Italic {
        if hasItalicFace { return .face }
        if let ital = axes.first(where: { $0.tag == "ital" }), ital.minimum <= 1, ital.maximum >= 1 {
            return .axis(tag: "ital", value: 1)
        }
        return .oblique(skew: syntheticSkew)
    }
}
