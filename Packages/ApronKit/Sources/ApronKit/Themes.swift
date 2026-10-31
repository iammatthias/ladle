/// One of apron-web's premade themes (`THEMES`): a fixed block of theme CSS, read with the same
/// parser as a custom theme.
public struct PremadeTheme: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let css: String

    /// apron-web's themes, in its order: Apron, Ferrous, Gumball, Linocut.
    public static let all: [PremadeTheme] = WebTokens.themes.map { PremadeTheme(id: $0.id, name: $0.name, css: $0.css) }

    /// The themes resolved once, by id.
    public static let resolved: [String: ResolvedTheme] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, ResolvedTheme(css: $0.css)) })
}
