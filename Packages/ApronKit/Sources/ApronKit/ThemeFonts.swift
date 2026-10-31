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
