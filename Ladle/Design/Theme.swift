import CoreText
import SwiftUI
import UIKit

/// The three visual directions under review. Each is a complete system: type, color, density,
/// message layout, and one ergonomic idea. Debug builds switch between them; see `LadleApp`.
enum Direction: String, CaseIterable, Identifiable {
    /// Editorial and calm: a flat log with avatars, serif titles, warm paper. Swipe to reply.
    case mise
    /// Fast and dense: an IRC-style log, monospaced names and times. Keyboard first.
    case pass
    /// Friendly and tactile: rounded bubbles, enamel colors. A room switcher within thumb reach.
    case enamel

    var id: String { rawValue }

    var name: String {
        switch self {
        case .mise: "Mise"
        case .pass: "Pass"
        case .enamel: "Enamel"
        }
    }
}

/// A color token: one sRGB value per appearance.
struct Swatch: Hashable {
    var light: UInt32
    var dark: UInt32

    var color: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? Self.ui(dark) : Self.ui(light) })
    }

    static func ui(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

struct Palette {
    var background: Swatch
    var surface: Swatch
    var text: Swatch
    var secondary: Swatch
    var accent: Swatch
    var onAccent: Swatch
    var separator: Swatch
    var mine: Swatch
    var onMine: Swatch
    var theirs: Swatch

    /// Foreground and background pairs that carry text, for the contrast report.
    var textPairs: [(name: String, foreground: Swatch, background: Swatch)] {
        [
            ("text on background", text, background),
            ("secondary on background", secondary, background),
            ("text on surface", text, surface),
            ("secondary on surface", secondary, surface),
            ("accent on background", accent, background),
            ("on-accent on accent", onAccent, accent),
            ("own message text", onMine, mine),
            ("others' message text", text, theirs),
        ]
    }
}

/// A typeface. The system faces follow Dynamic Type through text styles; Nunito (SIL OFL 1.1,
/// `Fonts/Nunito-OFL.txt`) follows it through `relativeTo:`.
enum Face {
    case sans, serif, mono, nunito

    var design: Font.Design {
        switch self {
        case .sans, .nunito: .default
        case .serif: .serif
        case .mono: .monospaced
        }
    }
}

enum MessageLayout {
    case log
    case dense
    case bubbles
}

struct Theme {
    var direction: Direction
    var palette: Palette
    var layout: MessageLayout
    /// Titles and room names, message text, and times and other metadata.
    var titleFace: Face
    var bodyFace: Face
    var metaFace: Face
    /// Space between messages from different people, and within one person's run.
    var groupSpacing: CGFloat
    var runSpacing: CGFloat
    var avatarSize: CGFloat
    /// Set only by the design-review renderer: Mac Catalyst ignores Dynamic Type, so it sizes
    /// text from the HIG's iOS table for this size instead of from the system.
    var fixedTypeSize: DynamicTypeSize?

    func font(_ style: Font.TextStyle, _ face: Face? = nil, weight: Font.Weight = .regular) -> Font {
        let face = face ?? bodyFace
        if let fixedTypeSize {
            return font(size: TypeTable.size(style, at: fixedTypeSize), face, weight: weight)
        }
        switch face {
        case .nunito:
            Self.registerFonts
            return .custom("Nunito", size: TypeTable.size(style, at: .large), relativeTo: style).weight(weight)
        default:
            return .system(style, design: face.design, weight: weight)
        }
    }

    /// A fixed size, for glyphs sized to a shape such as avatar initials.
    func font(size: CGFloat, _ face: Face, weight: Font.Weight = .regular) -> Font {
        switch face {
        case .nunito:
            Self.registerFonts
            return .custom("Nunito", fixedSize: size).weight(weight)
        default:
            return .system(size: size, weight: weight, design: face.design)
        }
    }

    private static let registerFonts: Void = {
        if let url = Bundle.main.url(forResource: "Nunito", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func of(_ direction: Direction) -> Theme {
        switch direction {
        case .mise: mise
        case .pass: pass
        case .enamel: enamel
        }
    }

    static let mise = Theme(
        direction: .mise,
        palette: Palette(
            background: Swatch(light: 0xF7F3EC, dark: 0x16130F),
            surface: Swatch(light: 0xFFFDF9, dark: 0x221E19),
            text: Swatch(light: 0x1F1A14, dark: 0xEFE8DC),
            secondary: Swatch(light: 0x6A5F53, dark: 0xA99D8F),
            accent: Swatch(light: 0x9C4A1C, dark: 0xE39361),
            onAccent: Swatch(light: 0xFFFFFF, dark: 0x1A0F08),
            separator: Swatch(light: 0xE3D9CA, dark: 0x332D25),
            mine: Swatch(light: 0xF7F3EC, dark: 0x16130F),
            onMine: Swatch(light: 0x1F1A14, dark: 0xEFE8DC),
            theirs: Swatch(light: 0xF7F3EC, dark: 0x16130F)
        ),
        layout: .log,
        titleFace: .serif,
        bodyFace: .sans,
        metaFace: .sans,
        groupSpacing: 18,
        runSpacing: 6,
        avatarSize: 36
    )

    static let pass = Theme(
        direction: .pass,
        palette: Palette(
            background: Swatch(light: 0xFFFFFF, dark: 0x0D0E10),
            surface: Swatch(light: 0xF1F2F0, dark: 0x191B1E),
            text: Swatch(light: 0x111214, dark: 0xE4E5E2),
            secondary: Swatch(light: 0x5A5D61, dark: 0x9A9DA1),
            accent: Swatch(light: 0x0B6B4E, dark: 0x52D3A3),
            onAccent: Swatch(light: 0xFFFFFF, dark: 0x04140E),
            separator: Swatch(light: 0xE2E3E0, dark: 0x26292D),
            mine: Swatch(light: 0xFFFFFF, dark: 0x0D0E10),
            onMine: Swatch(light: 0x111214, dark: 0xE4E5E2),
            theirs: Swatch(light: 0xFFFFFF, dark: 0x0D0E10)
        ),
        layout: .dense,
        titleFace: .mono,
        bodyFace: .sans,
        metaFace: .mono,
        groupSpacing: 6,
        runSpacing: 2,
        avatarSize: 0
    )

    static let enamel = Theme(
        direction: .enamel,
        palette: Palette(
            background: Swatch(light: 0xFBF8F3, dark: 0x0F121A),
            surface: Swatch(light: 0xFFFFFF, dark: 0x1A1F2A),
            text: Swatch(light: 0x1B2130, dark: 0xF1EEE8),
            secondary: Swatch(light: 0x596273, dark: 0xA3ABBA),
            accent: Swatch(light: 0x2343C4, dark: 0x8AA2FF),
            onAccent: Swatch(light: 0xFFFFFF, dark: 0x0B1020),
            separator: Swatch(light: 0xE6E0D6, dark: 0x2A3040),
            mine: Swatch(light: 0x2343C4, dark: 0x3550D6),
            onMine: Swatch(light: 0xFFFFFF, dark: 0xFFFFFF),
            theirs: Swatch(light: 0xEDE7DD, dark: 0x252B39)
        ),
        layout: .bubbles,
        titleFace: .nunito,
        bodyFace: .nunito,
        metaFace: .nunito,
        groupSpacing: 12,
        runSpacing: 3,
        avatarSize: 28
    )

    /// Large and inline navigation titles in the direction's title face and colors.
    @MainActor func applyNavigationAppearance() {
        let appearance = UINavigationBar.appearance()
        let text = Self.uiColor(palette.text)
        func font(_ style: UIFont.TextStyle, _ swiftUIStyle: Font.TextStyle) -> UIFont {
            let size = TypeTable.size(swiftUIStyle, at: fixedTypeSize ?? .large)
            let bold = [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
            let descriptor: UIFontDescriptor = switch titleFace {
            case .nunito:
                { Self.registerFonts; return UIFontDescriptor(fontAttributes: [.family: "Nunito", .traits: bold]) }()
            case .serif, .mono, .sans:
                UIFont.systemFont(ofSize: size, weight: .bold).fontDescriptor
                    .withDesign(titleFace == .serif ? .serif : titleFace == .mono ? .monospaced : .default) ?? UIFont.systemFont(ofSize: size).fontDescriptor
            }
            let font = UIFont(descriptor: descriptor, size: size)
            return fixedTypeSize == nil ? UIFontMetrics(forTextStyle: style).scaledFont(for: font) : font
        }
        appearance.largeTitleTextAttributes = [.font: font(.largeTitle, .largeTitle), .foregroundColor: text]
        appearance.titleTextAttributes = [.font: font(.headline, .headline), .foregroundColor: text]
    }

    private static func uiColor(_ swatch: Swatch) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? Swatch.ui(swatch.dark) : Swatch.ui(swatch.light) }
    }
}

extension EnvironmentValues {
    @Entry var theme = Theme.mise
}

extension View {
    /// Installs a direction for this hierarchy, including the UIKit navigation bar titles.
    func themed(_ theme: Theme) -> some View {
        environment(\.theme, theme)
            .tint(theme.palette.accent.color)
            .onAppear { theme.applyNavigationAppearance() }
    }
}

/// iOS Dynamic Type point sizes from the HIG's typography specifications
/// (https://developer.apple.com/design/human-interface-guidelines/typography#Specifications).
enum TypeTable {
    static func size(_ style: Font.TextStyle, at size: DynamicTypeSize) -> CGFloat {
        let row = size >= .accessibility3 ? accessibility3 : large
        return row[style] ?? 17
    }

    private static let large: [Font.TextStyle: CGFloat] = [
        .largeTitle: 34, .title: 28, .title2: 22, .title3: 20, .headline: 17, .body: 17,
        .callout: 16, .subheadline: 15, .footnote: 13, .caption: 12, .caption2: 11,
    ]

    private static let accessibility3: [Font.TextStyle: CGFloat] = [
        .largeTitle: 52, .title: 48, .title2: 44, .title3: 43, .headline: 40, .body: 40,
        .callout: 38, .subheadline: 36, .footnote: 33, .caption: 32, .caption2: 29,
    ]
}
