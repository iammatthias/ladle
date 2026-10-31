import CoreGraphics

/// Every token Ladle applies, as a theme leaves it in each mode: the theme's own value where it
/// sets one, else tokens.css's (`WebTokens`), with `var()` read against the theme first, so an
/// alias follows what the theme sets (`--focus` is the theme's `--accent`), as in the browser.
public struct ResolvedTheme: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case color(RGBA)
        case shadow(ShadowToken)
        /// Points (`px`).
        case length(Double)
        /// Seconds.
        case duration(Double)
        /// A percentage, as a fraction.
        case fraction(Double)
        case number(Double)
        case curve(Curve)
    }

    enum Kind: CaseIterable {
        case shadow, curve, color, length, duration, fraction, number

        func read(_ text: String, _ mode: ColorMode) -> Value? {
            switch self {
            case .shadow: CSSValue.shadow(text, mode: mode).map(Value.shadow)
            case .curve: CSSValue.curve(text).map(Value.curve)
            case .color: CSSValue.color(text, mode: mode).map(Value.color)
            case .length: CSSValue.length(text).map(Value.length)
            case .duration: CSSValue.duration(text).map(Value.duration)
            case .fraction: text.hasSuffix("%") ? CSSValue.fraction(text).map(Value.fraction) : nil
            case .number: CSSValue.number(text).map(Value.number)
            }
        }
    }

    /// What the theme sets, as parsed: its own tokens, after those its base colors give.
    public let vars: [ThemeVar]
    /// The tokens the theme sets that Ladle does not apply: web-only ones (`--z-*`, the
    /// `--pref-` widths), names tokens.css lacks, and values Ladle can't read. Kept, so the
    /// theme's text round-trips, and listed in Preferences as not used on iOS.
    public let notShown: [ThemeVar]
    let values: [String: Themed<Value>]

    public init(vars: [ThemeVar]) {
        self.init(vars: vars, fallback: .apron)
    }

    /// `fallback` gives a token whose value the theme sets but Ladle can't read; tokens.css's own
    /// values all read (`ThemeTests`), so the Apron theme needs none.
    private init(vars: [ThemeVar], fallback: ResolvedTheme?) {
        self.vars = vars
        let own = Dictionary(vars.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
        func read(_ name: String, _ kind: Kind, _ mode: ColorMode) -> Value? {
            let base = mode == .light ? WebTokens.light : WebTokens.dark
            guard let written = own[name] ?? base[name],
                  let text = CSSValue.substitute(written, lookup: { own[$0] ?? base[$0] }) else { return nil }
            return kind.read(text, mode)
        }
        var values: [String: Themed<Value>] = [:]
        for (name, kind) in Self.kinds {
            if let dark = read(name, kind, .dark), let light = read(name, kind, .light) {
                values[name] = Themed(dark, light)
            } else if let fallback = fallback?.values[name] {
                values[name] = fallback
            }
        }
        self.values = values
        notShown = vars.filter { v in
            if ThemeCSS.bases.contains(v.name) { return false }
            guard WebTokens.applied.contains(v.name) else { return true }
            guard let kind = Self.kinds[v.name] else { return false }
            return read(v.name, kind, .dark) == nil || read(v.name, kind, .light) == nil
        }
    }

    /// A theme's CSS, read as apron-web reads it; a theme with an error sets nothing.
    public init(css: String) {
        self.init(vars: ThemeCSS.parse(css).vars)
    }

    /// tokens.css's own palette and sizes: the Apron theme.
    public static let apron = ResolvedTheme(vars: [], fallback: nil)

    /// What each applied token reads as, from tokens.css's value for it (fonts excepted).
    static let kinds: [String: Kind] = {
        var kinds: [String: Kind] = [:]
        for name in WebTokens.applied where !name.hasPrefix("--font-") {
            guard let written = WebTokens.dark[name],
                  let text = CSSValue.substitute(written, lookup: { WebTokens.dark[$0] }),
                  let kind = Kind.allCases.first(where: { $0.read(text, .dark) != nil }) else { continue }
            kinds[name] = kind
        }
        return kinds
    }()

    public func color(_ name: String) -> Themed<RGBA> {
        guard case let .color(dark)? = values[name]?.dark, case let .color(light)? = values[name]?.light else { return Themed(RGBA(0), RGBA(0)) }
        return Themed(dark, light)
    }

    public func shadow(_ name: String) -> Themed<ShadowToken> {
        guard case let .shadow(dark)? = values[name]?.dark, case let .shadow(light)? = values[name]?.light else {
            return Themed(ShadowToken(y: 0, blur: 0, color: RGBA(0, 0)), ShadowToken(y: 0, blur: 0, color: RGBA(0, 0)))
        }
        return Themed(dark, light)
    }

    /// A length, duration or plain number token (`px`, seconds, a number), as dark mode has it:
    /// these don't change with the mode.
    public func number(_ name: String) -> Double {
        switch values[name]?.dark {
        case let .length(n)?, let .duration(n)?, let .number(n)?, let .fraction(n)?: n
        default: 0
        }
    }

    public func fraction(_ name: String) -> Themed<Double> {
        guard case let .fraction(dark)? = values[name]?.dark, case let .fraction(light)? = values[name]?.light else { return Themed(1, 1) }
        return Themed(dark, light)
    }

    public func curve(_ name: String) -> Curve {
        guard case let .curve(curve)? = values[name]?.dark else { return Curve(0, 0, 1, 1) }
        return curve
    }
}
