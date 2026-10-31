import Foundation
import Observation

/// Light, dark, or the system's, over any theme (apron-web's `ThemeMode`).
public enum ThemeMode: String, CaseIterable, Sendable {
    case system, light, dark
}

/// A choice of appearance, as apron-web's `AppearancePreferences`: the mode, a premade theme's id
/// or `custom`, and the custom theme's CSS, kept while a premade theme is chosen too so choosing
/// Custom again brings it back.
public struct AppearancePreferences: Hashable, Sendable {
    public static let custom = "custom"

    public var mode: ThemeMode
    public var theme: String
    public var customCSS: String

    public init(mode: ThemeMode = .system, theme: String = "apron", customCSS: String = "") {
        (self.mode, self.theme, self.customCSS) = (mode, theme, customCSS)
    }

    public static let `default` = AppearancePreferences()

    /// apron-web's `decodeAppearance`: an unknown mode is `system`, an unknown theme `apron`, and
    /// custom CSS longer than a theme may be is dropped. (Ladle never kept the font fields that
    /// apron-web turns into a custom theme.)
    public init(saved json: JSONValue?) {
        let mode = json?["mode"]?.stringValue.flatMap(ThemeMode.init(rawValue:)) ?? .system
        let css = json?["customCss"]?.stringValue.flatMap { $0.utf16.count <= WebTokens.themeCSSMax ? $0 : nil } ?? ""
        let theme = json?["theme"]?.stringValue
        let known = theme == Self.custom || PremadeTheme.all.contains { $0.id == theme }
        self.init(mode: mode, theme: known ? theme! : Self.default.theme, customCSS: css)
    }

    var json: JSONValue {
        ["mode": .string(mode.rawValue), "theme": .string(theme), "customCss": .string(customCSS)]
    }

    /// apron-web's `cssForTheme`: a premade theme's CSS, or the custom one.
    public var css: String {
        theme == Self.custom ? customCSS : (PremadeTheme.all.first { $0.id == theme } ?? PremadeTheme.all[0]).css
    }

    /// apron-web's `chooseTheme`: Custom starts, the first time, from the CSS of the theme it was
    /// chosen from.
    public func choosing(_ theme: String) -> AppearancePreferences {
        guard theme == Self.custom || PremadeTheme.all.contains(where: { $0.id == theme }) else { return self }
        var next = self
        next.theme = theme
        if theme == Self.custom, customCSS.isEmpty { next.customCSS = css }
        return next
    }
}

/// The appearance on this device, as apron-web's `AppearanceSettings`: kept in `appearance.json`
/// beside `servers.json` (apron-web keeps it in this browser's storage), never sent anywhere.
/// `shown` is the theme on screen: the saved one, or custom CSS being edited, which shows while
/// it parses (`preview`) until it is applied or `revert`ed.
@MainActor
@Observable
public final class AppearanceSettings {
    public private(set) var current: AppearancePreferences
    public private(set) var shown: ResolvedTheme

    @ObservationIgnored private let fileURL: URL?

    /// `directory` nil keeps the choice in memory only.
    public init(directory: URL? = nil) {
        fileURL = directory?.appending(path: "appearance.json")
        let json = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONValue(parsing: $0) }
        let saved = AppearancePreferences(saved: json)
        current = saved
        shown = Self.resolve(saved)
    }

    public func update(_ next: AppearancePreferences) {
        current = AppearancePreferences(saved: next.json)
        shown = Self.resolve(current)
        save()
    }

    /// Shows custom CSS as it is edited, without saving it; why not, when it doesn't read (the
    /// last that did stays on show).
    public func preview(_ css: String) -> String? {
        let parsed = ThemeCSS.parse(css)
        if let error = parsed.error { return error }
        shown = ResolvedTheme(vars: parsed.vars)
        return nil
    }

    /// Back to what is saved.
    public func revert() {
        shown = Self.resolve(current)
    }

    /// A premade theme is read once; custom CSS with an error sets nothing, as on the web.
    private static func resolve(_ preferences: AppearancePreferences) -> ResolvedTheme {
        if preferences.theme != AppearancePreferences.custom, let premade = PremadeTheme.resolved[preferences.theme] { return premade }
        return ResolvedTheme(css: preferences.css)
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? current.json.serializedData().write(to: fileURL, options: .atomic)
    }
}

/// Preferences > Appearance's custom CSS as it is edited, as apron-web's PreferencesDialog keeps
/// it: the text, which shows while it reads, and why it doesn't. It lives as long as Preferences
/// is open; `close` drops edits not applied, as closing apron-web's dialog does.
@MainActor
@Observable
public final class ThemeEditor {
    public let settings: AppearanceSettings
    /// The custom CSS as edited.
    public private(set) var draft: String
    /// Why Apply refused the CSS, or why the saved custom theme sets nothing.
    public private(set) var themeError = ""
    /// Why the CSS as typed isn't on show, while it doesn't read: "Not showing yet: …".
    public private(set) var draftError = ""

    public init(settings: AppearanceSettings) {
        self.settings = settings
        draft = settings.current.css
    }

    /// Whether the text differs from the chosen theme's.
    public var edited: Bool { draft != settings.current.css }

    /// The text as typed, at most `WebTokens.themeCSSMax` UTF-16 units (the web field's
    /// `maxlength`), shown while it reads.
    public func edit(_ text: String) {
        draft = text.utf16.count > WebTokens.themeCSSMax ? String(utf16Prefix: text, WebTokens.themeCSSMax) : text
        themeError = ""
        if edited {
            draftError = settings.preview(draft) ?? ""
        } else {
            draftError = ""
            settings.revert()
        }
    }

    public func setMode(_ mode: ThemeMode) {
        var next = settings.current
        next.mode = mode
        settings.update(next)
        // Custom CSS being edited stays on show in the new mode.
        if edited { _ = settings.preview(draft) }
    }

    /// A theme applies at once; Custom shows its CSS, the first time the CSS of the theme it was
    /// chosen from. A saved custom theme that doesn't read applies nothing, and says why.
    public func choose(_ theme: String) {
        settings.update(settings.current.choosing(theme))
        draft = settings.current.css
        themeError = theme == AppearancePreferences.custom ? (ThemeCSS.parse(settings.current.customCSS).error ?? "") : ""
        draftError = ""
    }

    /// Edited CSS becomes the custom theme; false, with `themeError` set, when it doesn't read.
    @discardableResult
    public func apply() -> Bool {
        if let error = ThemeCSS.parse(draft).error {
            themeError = error
            return false
        }
        var next = settings.current
        next.theme = AppearancePreferences.custom
        next.customCSS = draft
        settings.update(next)
        themeError = ""
        draftError = ""
        return true
    }

    public func discard() {
        draft = settings.current.css
        themeError = ""
        draftError = ""
        settings.revert()
    }

    /// Preferences closing: edits not applied go with it.
    public func close() {
        if edited { discard() }
    }
}

/// Base colors (`theme-colors.ts`), as the color pickers write them into theme CSS.
public struct ThemeBases: Hashable, Sendable {
    public var ground: Themed<RGBA>
    public var ink: Themed<RGBA>
    public var accent: Themed<RGBA>
    public var link: Themed<RGBA>

    public init(ground: Themed<RGBA>, ink: Themed<RGBA>, accent: Themed<RGBA>, link: Themed<RGBA>) {
        (self.ground, self.ink, self.accent, self.link) = (ground, ink, accent, link)
    }

    /// What a theme shows now, as bases: its grounds, ink, accent and links.
    public init(_ theme: ResolvedTheme) {
        self.init(ground: theme.color("--bg-100"), ink: theme.color("--ink"), accent: theme.color("--accent"), link: theme.color("--denim"))
    }

    /// `css` with these as its four `--base-*` declarations, replacing any it has outside
    /// comments, inside its `:root` block when it has one. Each is `light-dark(light, dark)`, or
    /// one `#hex` when the modes agree. Alpha is dropped: a base is opaque.
    public func written(into css: String) -> String {
        let lines = [("--base-ground", ground), ("--base-ink", ink), ("--base-accent", accent), ("--base-link", link)].map { name, color in
            let (l, d) = (Self.hex(color.light), Self.hex(color.dark))
            return "\t\(name): \(l == d ? l : "light-dark(\(l), \(d))");"
        }
        var text = Self.removingBases(from: css)
        let block = lines.joined(separator: "\n")
        if let close = text.lastIndex(of: "}"), text.wholeMatch(of: /\s*(?:\/\*[\s\S]*?\*\/\s*)*:root\s*\{[\s\S]*\}\s*/) != nil {
            var head = String(text[..<close])
            while head.last?.isWhitespace == true { head.removeLast() }
            text = head + "\n" + block + "\n" + text[close...]
        } else {
            text = (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text.trimmingCharacters(in: .newlines) + "\n") + block + "\n"
        }
        return text
    }

    private static func hex(_ color: RGBA) -> String { RGBA(color.rgb).description }

    /// Removes each `--base-*: …;` declaration outside comments.
    private static func removingBases(from css: String) -> String {
        var out = ""
        var rest = Substring(css)
        while !rest.isEmpty {
            if rest.hasPrefix("/*") {
                let end = rest.range(of: "*/").map(\.upperBound) ?? rest.endIndex
                out += rest[..<end]
                rest = rest[end...]
            } else if let match = rest.prefixMatch(of: /[ \t]*--base-(?:ground|ink|accent|link)\s*:[^;{}]*;?[ \t]*\n?/) {
                rest = rest[match.range.upperBound...]
            } else {
                out.append(rest.removeFirst())
            }
        }
        return out
    }
}
