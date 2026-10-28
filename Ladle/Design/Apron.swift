import SwiftUI
import UIKit

/// apron-web's colors by job, from `Tokens.Color`. Both themes come from tokens.css; dark is the
/// reference.
///
/// - `accent` (rust) is what you can do: the primary button, Send, a mention of you, the bar on
///   the open room.
/// - `denim` is where you can go: links, threads, the New line, a moved message's room.
/// - Every status color (`ok`, `warn`, `danger`, the presence colors) always carries a word or a
///   shape beside it. Nothing is said by color alone.
/// - `private` (plum) always comes with its lock.
///
/// Increase Contrast has no web counterpart. Under it, hairlines take `line-strong` and muted
/// text takes `ink`, the HIG's answer for low-contrast separators and secondary text.
enum Palette {
    typealias C = Tokens.Color
    /// Grounds by depth: rail < chrome < timeline < raised < hover.
    static let rail = C.bgRail.color()
    static let chrome = C.bg000.color()
    static let timeline = C.bg100.color()
    static let raised = C.bg200.color()
    static let hover = C.bg300.color()
    static let selected = C.selected.color(increasedContrast: C.hover)

    static let line = C.line.color(increasedContrast: C.lineStrong)
    static let lineStrong = C.lineStrong.color()
    static let ink = C.ink.color()
    static let inkMuted = C.inkMuted.color(increasedContrast: C.ink)

    static let accent = C.accent.color()
    static let onAccent = C.onAccent.color()
    static let accentSoft = C.accentSoft.color()
    static let denim = C.denim.color()
    static let denimSoft = C.denimSoft.color()

    static let danger = C.danger.color()
    static let warn = C.warn.color()
    static let ok = C.ok.color()
    static let `private` = C.private.color()
    static let privateSoft = C.privateSoft.color()
    static let scrim = C.scrim.color()

    /// `--count-shade`: a quiet count keeps this much of its ground, the rest black.
    static let quietCount = Color(uiColor: UIColor { traits in
        let shade = Tokens.countShade.value(for: traits)
        let ground = C.bg300.value(for: traits).uiColor
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        ground.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * shade, green: g * shade, blue: b * shade, alpha: a)
    })
}

/// apron-web's text roles. Each role's web size is its size at the Large Dynamic Type setting,
/// and it scales with the text style named here. System faces only (SF and SF Mono), as the web.
enum TextRole {
    /// Uppercase labels with letter spacing: role badges.
    case caps
    /// The quietest meta: system times, keyboard hints.
    case xs
    /// Meta and hints: timestamps, field labels, room topics, section heads.
    case sm
    /// Controls: buttons, menus, member rows, notes, thread cards.
    case ui
    /// What people type. iOS fields take 16 pt (`--text-field-ios`), as the web does on iOS.
    case field
    /// Messages and running text; room and panel titles.
    case body
    /// Dialog and card titles.
    case title
    /// The connect screen's display title (a literal 28 px on the web).
    case display

    var size: CGFloat {
        switch self {
        case .caps: Tokens.TextSize.caps
        case .xs: Tokens.TextSize.xs
        case .sm: Tokens.TextSize.sm
        case .ui: Tokens.TextSize.ui
        case .field: 16
        case .body: Tokens.TextSize.body
        case .title: Tokens.TextSize.title
        case .display: 28
        }
    }

    var leading: CGFloat {
        switch self {
        case .caps, .xs, .sm: Tokens.Leading.sm
        case .ui: Tokens.Leading.ui
        case .field: Tokens.Leading.field + 2
        case .body: Tokens.Leading.body
        case .title: Tokens.Leading.title
        case .display: Tokens.Leading.display
        }
    }

    var style: Font.TextStyle {
        switch self {
        case .caps, .xs: .caption2
        case .sm: .caption
        case .ui: .footnote
        case .field: .callout
        case .body: .subheadline
        case .title: .title3
        case .display: .title
        }
    }
}

extension EnvironmentValues {
    /// Set only by the LadleShots renderer: Mac Catalyst ignores Dynamic Type, so the renderer
    /// scales text from the HIG's iOS table instead.
    @Entry var fixedTypeSize: DynamicTypeSize?
}

/// Sets a role's font and its web line height, both scaled with Dynamic Type.
private struct RoleText: ViewModifier {
    let role: TextRole
    let weight: Font.Weight
    let mono: Bool
    @Environment(\.fixedTypeSize) private var fixed
    @Environment(\.dynamicTypeSize) private var dynamic

    func body(content: Content) -> some View {
        let scale = TypeTable.scale(role.style, at: fixed ?? dynamic)
        let size = role.size * scale
        let font = UIFont.systemFont(ofSize: size, weight: weight.ui)
        content
            .font(.system(size: size, weight: weight, design: mono ? .monospaced : .default))
            .lineSpacing(max(0, role.leading * scale - font.lineHeight))
            .tracking(role == .caps ? 0.6 : 0)
            .textCase(role == .caps ? .uppercase : nil)
    }
}

extension View {
    func apText(_ role: TextRole, _ weight: Font.Weight = .regular, mono: Bool = false) -> some View {
        modifier(RoleText(role: role, weight: weight, mono: mono))
    }

    /// Pads a control to the 44 pt minimum target (`--touch-target`) without changing its look.
    func touchTarget() -> some View {
        frame(minWidth: Tokens.Size.touchTarget, minHeight: Tokens.Size.touchTarget).contentShape(Rectangle())
    }
}

/// A role's point size for fixed glyphs that still follow Dynamic Type (avatar initials).
struct ScaledRole {
    static func size(_ role: TextRole, at size: DynamicTypeSize) -> CGFloat {
        role.size * TypeTable.scale(role.style, at: size)
    }
}

/// iOS Dynamic Type sizes from the HIG's typography specifications, as a scale from Large
/// (https://developer.apple.com/design/human-interface-guidelines/typography#Specifications).
enum TypeTable {
    static func scale(_ style: Font.TextStyle, at size: DynamicTypeSize) -> CGFloat {
        let base = large[style] ?? 17
        let row: [Font.TextStyle: CGFloat] = switch size {
        case .xSmall, .small, .medium: medium
        case .large: large
        case .xLarge: xLarge
        case .xxLarge: xxLarge
        case .xxxLarge: xxxLarge
        case .accessibility1, .accessibility2: accessibility1
        default: accessibility3
        }
        return (row[style] ?? base) / base
    }

    private static let medium: [Font.TextStyle: CGFloat] = [
        .title: 27, .title3: 19, .body: 16, .callout: 15, .subheadline: 14, .footnote: 12, .caption: 11, .caption2: 11,
    ]
    private static let large: [Font.TextStyle: CGFloat] = [
        .title: 28, .title3: 20, .body: 17, .callout: 16, .subheadline: 15, .footnote: 13, .caption: 12, .caption2: 11,
    ]
    private static let xLarge: [Font.TextStyle: CGFloat] = [
        .title: 30, .title3: 22, .body: 19, .callout: 18, .subheadline: 17, .footnote: 15, .caption: 14, .caption2: 13,
    ]
    private static let xxLarge: [Font.TextStyle: CGFloat] = [
        .title: 32, .title3: 24, .body: 21, .callout: 20, .subheadline: 19, .footnote: 17, .caption: 16, .caption2: 15,
    ]
    private static let xxxLarge: [Font.TextStyle: CGFloat] = [
        .title: 34, .title3: 26, .body: 23, .callout: 22, .subheadline: 21, .footnote: 19, .caption: 18, .caption2: 17,
    ]
    private static let accessibility1: [Font.TextStyle: CGFloat] = [
        .title: 38, .title3: 31, .body: 28, .callout: 26, .subheadline: 25, .footnote: 23, .caption: 22, .caption2: 20,
    ]
    private static let accessibility3: [Font.TextStyle: CGFloat] = [
        .title: 48, .title3: 43, .body: 40, .callout: 38, .subheadline: 36, .footnote: 33, .caption: 32, .caption2: 29,
    ]
}

private extension Font.Weight {
    var ui: UIFont.Weight {
        switch self {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
    }
}

/// The web's motion tokens. Reduce Motion turns every one of them off, as
/// `prefers-reduced-motion` does on the web.
enum Motion {
    static func fast(_ reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: Tokens.Duration.fast) }
    static func medium(_ reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: Tokens.Duration.medium) }
    static func slide(_ reduce: Bool) -> Animation? { reduce ? nil : Tokens.easeSlide.animation(duration: Tokens.Duration.slide) }
}

extension View {
    /// Installs the web's grounds and ink on this hierarchy, including the UIKit bars.
    func apronStyle() -> some View {
        tint(Palette.accent)
            .onAppear(perform: Appearance.apply)
    }
}

@MainActor
enum Appearance {
    /// The navigation bar on the chrome ground with a hairline, as the web's room header
    /// (`--header-h`, `--bg-100`, a `--line` border). Titles stay the system's size: the HIG's
    /// navigation bar, not the web's 15 px header.
    static func apply() {
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(Palette.timeline)
        bar.shadowColor = UIColor(Palette.line)
        bar.titleTextAttributes = [.foregroundColor: UIColor(Palette.ink)]
        bar.largeTitleTextAttributes = [.foregroundColor: UIColor(Palette.ink)]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
    }
}
