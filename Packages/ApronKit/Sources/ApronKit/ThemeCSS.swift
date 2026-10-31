import Foundation

/// One custom property a theme sets on the root: `--name` and its value as written.
public struct ThemeVar: Hashable, Sendable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        (self.name, self.value) = (name, value)
    }
}

/// A theme's CSS as apron-web reads it (`appearance.svelte.ts`'s `parseThemeCss`, `theme-colors.ts`),
/// with the same grammar, limits and messages, so a theme pasted from apron-web's Preferences reads
/// the same here: custom property declarations, bare or in one `:root { … }` block, with comments.
public enum ThemeCSS {
    /// What a theme sets, in order, each name once; or why it sets nothing.
    public struct Parsed: Hashable, Sendable {
        public let vars: [ThemeVar]
        public let error: String?
    }

    public static let bases = ["--base-ground", "--base-ink", "--base-accent", "--base-link"]

    private nonisolated(unsafe) static let unsafeValue = try! NSRegularExpression(pattern: WebTokens.unsafeValue, options: [.caseInsensitive])

    /// apron-web's `parseThemeCss`. Lengths count UTF-16 code units, as JavaScript does.
    public static func parse(_ css: String) -> Parsed {
        func fail(_ error: String) -> Parsed { Parsed(vars: [], error: error) }
        if css.utf16.count > WebTokens.themeCSSMax { return fail("A theme can be at most \(WebTokens.themeCSSMax) characters.") }
        var body = css.replacing(/\/\*[\s\S]*?\*\//, with: " ").trimmingCharacters(in: .jsWhitespace)
        if body.contains("/*") { return fail("A comment is missing its closing */.") }
        if let block = body.wholeMatch(of: /:root\s*\{([\s\S]*)\}/) { body = String(block.1) }
        var names: [String] = []
        var values: [String: String] = [:]
        for part in body.split(separator: ";", omittingEmptySubsequences: false) {
            let declaration = part.trimmingCharacters(in: .jsWhitespace)
            if declaration.isEmpty { continue }
            let quoted = "“\(declaration.utf16.count > 40 ? String(utf16Prefix: declaration, 40) + "…" : declaration)”"
            guard let match = declaration.wholeMatch(of: /(--[A-Za-z0-9_-]+)\s*:\s*([\s\S]*)/) else {
                return fail("Expected a token such as --font-sans: value; at \(quoted).")
            }
            let name = String(match.1)
            let value = String(match.2).replacing(/\s+/, with: " ").trimmingCharacters(in: .jsWhitespace)
            if value.isEmpty { return fail("\(name) needs a value.") }
            if unsafeValue.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                return fail("\(name) can’t use url(), @, braces, backslashes or !important.")
            }
            let bare = value.replacing(/"[^"]*"|'[^']*'/, with: "")
            if bare.contains("\"") || bare.contains("'") { return fail("\(name) has an unclosed quote.") }
            var depth = 0
            for c in bare {
                depth += c == "(" ? 1 : c == ")" ? -1 : 0
                if depth < 0 { break }
            }
            if depth != 0 { return fail("\(name) has a bracket that isn’t closed or opened.") }
            names.removeAll { $0 == name }
            names.append(name)
            values[name] = value
        }
        if names.count > WebTokens.themeVarsMax { return fail("A theme can set at most \(WebTokens.themeVarsMax) tokens.") }
        if let error = basesError(values) { return fail(error) }
        let own = names.map { ThemeVar($0, values[$0]!) }
        return Parsed(vars: deriveTokens(values).filter { values[$0.name] == nil } + own, error: nil)
    }

    /// apron-web's `readBase`: one `#hex` for both modes, or `light-dark(#hex, #hex)`.
    public static func readBase(_ value: String) -> Themed<RGBA>? {
        guard let pair = readBasePair(value) else { return nil }
        return Themed(RGBA(channels: pair.dark), RGBA(channels: pair.light))
    }

    typealias Channels = (Double, Double, Double)

    private static func readBasePair(_ value: String) -> (light: Channels, dark: Channels)? {
        let trimmed = value.trimmingCharacters(in: .jsWhitespace)
        let pair = trimmed.wholeMatch(of: /(?i)light-dark\(\s*([^,()]+?)\s*,\s*([^,()]+?)\s*\)/)
        guard let light = hex(pair.map { String($0.1) } ?? trimmed),
              let dark = pair.map({ hex(String($0.2)) }) ?? light else { return nil }
        return (light, dark)
    }

    private static func hex(_ value: String) -> Channels? {
        guard let match = value.trimmingCharacters(in: .jsWhitespace).wholeMatch(of: /(?i)#([0-9a-f]{3}|[0-9a-f]{6})/) else { return nil }
        let digits = match.1.count == 3 ? match.1.map { "\($0)\($0)" }.joined() : String(match.1)
        guard let v = Int(digits, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xFF), Double(v >> 8 & 0xFF), Double(v & 0xFF))
    }

    /// apron-web's `basesError`: why a theme's bases can't be read, if they can't.
    static func basesError(_ vars: [String: String]) -> String? {
        let set = bases.filter { vars[$0] != nil }
        if set.isEmpty { return nil }
        for name in set where readBasePair(vars[name]!) == nil { return "\(name) takes a #hex color, or light-dark(#hex, #hex)." }
        if vars["--base-ground"] == nil || vars["--base-ink"] == nil { return "Base colors start from --base-ground and --base-ink together." }
        return nil
    }

    /// apron-web's `deriveTokens`: the tokens a theme's bases give, before the theme's own; none
    /// without bases. Assumes `basesError` passed.
    static func deriveTokens(_ vars: [String: String]) -> [ThemeVar] {
        guard vars["--base-ground"] != nil, vars["--base-ink"] != nil else { return [] }
        let read = bases.map { name in vars[name].flatMap(readBasePair) }
        guard let ground = read[0], let ink = read[1] else { return [] }
        let light = palette(ground.light, ink.light, read[2]?.light, read[3]?.light)
        let dark = palette(ground.dark, ink.dark, read[2]?.dark, read[3]?.dark)
        return light.map { name, color in
            let (l, d) = (toHex(color), toHex(dark.first { $0.0 == name }!.1))
            return ThemeVar(name, l == d ? l : "light-dark(\(l), \(d))")
        }
    }

    private static func toHex(_ c: Channels) -> String { RGBA(channels: c).description }

    private static func mix(_ a: Channels, _ b: Channels, _ t: Double) -> Channels {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    private static func luminance(_ c: Channels) -> Double { RGBA(channels: c).luminance }

    private static func contrast(_ a: Channels, _ b: Channels) -> Double { RGBA(channels: a).contrast(with: RGBA(channels: b)) }

    /// The derived tokens for one mode, in apron-web's order. The steps follow tokens.css's own.
    private static func palette(_ ground: Channels, _ ink: Channels, _ accent: Channels?, _ link: Channels?) -> [(String, Channels)] {
        let dark = luminance(ground) < luminance(ink)
        func toward(_ t: Double) -> Channels { mix(ground, ink, t) }
        let black: Channels = (0, 0, 0)
        var tokens: [(String, Channels)] = [
            ("--bg-rail", dark ? mix(ground, black, 0.45) : toward(0.12)),
            ("--bg-000", dark ? mix(ground, black, 0.25) : toward(0.06)),
            ("--bg-100", ground),
            ("--bg-200", toward(dark ? 0.06 : 0.035)),
            ("--bg-300", toward(dark ? 0.12 : 0.09)),
            ("--line", toward(dark ? 0.1 : 0.09)),
            ("--line-strong", toward(dark ? 0.5 : 0.55)),
            ("--ink", ink),
            ("--ink-muted", mix(ink, ground, 0.3)),
        ]
        if let accent {
            tokens.append(("--accent", accent))
            tokens.append(("--on-accent", contrast(accent, ground) >= contrast(accent, ink) ? ground : ink))
            tokens.append(("--accent-soft", mix(ground, accent, dark ? 0.18 : 0.16)))
        }
        if let link {
            tokens.append(("--denim", link))
            tokens.append(("--denim-soft", mix(ground, link, dark ? 0.2 : 0.14)))
        }
        return tokens
    }

    /// apron-web's `forMode`: a value as one mode reads it, the half of `light-dark(light, dark)`
    /// for that mode (split at its top-level comma), or the value as it is.
    public static func forMode(_ value: String, _ mode: ColorMode) -> String {
        let trimmed = value.trimmingCharacters(in: .jsWhitespace)
        guard let pair = trimmed.wholeMatch(of: /(?i)light-dark\(([\s\S]*)\)/) else { return trimmed }
        let inner = pair.1
        var depth = 0
        for index in inner.indices {
            switch inner[index] {
            case "(": depth += 1
            case ")": depth -= 1
            case "," where depth == 0:
                let half = mode == .light ? inner[..<index] : inner[inner.index(after: index)...]
                return half.trimmingCharacters(in: .jsWhitespace)
            default: break
            }
        }
        return trimmed
    }
}

extension CharacterSet {
    /// What JavaScript's `trim()` and `\s` take as white space, near enough: Unicode white space
    /// and line breaks.
    static let jsWhitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
}

extension String {
    /// The first `count` UTF-16 code units, as JavaScript's `slice(0, count)`.
    init(utf16Prefix string: String, _ count: Int) {
        let units = Array(string.utf16.prefix(count))
        self = String(decoding: units, as: UTF16.self)
    }
}
