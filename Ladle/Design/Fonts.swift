import ApronKit
import CoreText
import Synchronization
import SwiftUI
import UIKit

/// Which of a theme's faces a text role takes.
enum TextFace: Sendable {
    /// `--font-sans`: the interface.
    case sans
    /// `--font-chat`: message text.
    case chat
    /// `--font-mono`: code and commands.
    case mono
}

extension EnvironmentValues {
    /// The face `apText` takes where it isn't told: message text sets `.chat` around itself.
    @Entry var textFace: TextFace = .sans
}

/// The faces apron-web carries for its themes (Recursive's casual sans and mono, Nunito; OFL 1.1),
/// converted by tools/design/fonts.py into `Ladle/Fonts` and registered for this process the
/// first time a theme names one. Each is two fonts, the Latin cut and, behind it as a cascade,
/// the Latin Extended one, as fonts.css joins them with `unicode-range`.
enum BundledFonts {
    /// fonts.css's family names, which themes write, and the fonts' own.
    private static let families: [String: (main: String, ext: String)] = [
        "apron recursive casual": ("Apron Recursive Casual", "Apron Recursive Casual Ext"),
        "apron rec mono casual": ("Apron Rec Mono Casual", "Apron Rec Mono Casual Ext"),
        "apron nunito": ("Apron Nunito", "Apron Nunito Ext"),
    ]

    private static let registered: Bool = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, nil)
        return true
    }()

    /// A face for one family of a theme's list at a size and weight, italic or not, or nil when
    /// the device lacks it.
    static func font(_ family: FontFamily, size: CGFloat, weight: Font.Weight, italic: Bool = false) -> UIFont? {
        guard let descriptor = upright(family, size: size, weight: weight) else { return nil }
        let upright = UIFont(descriptor: descriptor, size: size)
        return italic ? UIFont(descriptor: italicized(descriptor, upright), size: size) : upright
    }

    /// The upright face's descriptor, the bundled faces' with their cascade.
    private static func upright(_ family: FontFamily, size: CGFloat, weight: Font.Weight) -> UIFontDescriptor? {
        switch family {
        case .system: return UIFont.systemFont(ofSize: size, weight: weight.ui).fontDescriptor
        case .systemMono: return UIFont.monospacedSystemFont(ofSize: size, weight: weight.ui).fontDescriptor
        case .rounded: return UIFont.systemFont(ofSize: size, weight: weight.ui).fontDescriptor.withDesign(.rounded)
        case .serif: return UIFont.systemFont(ofSize: size, weight: weight.ui).fontDescriptor.withDesign(.serif)
        case .named(let name):
            if let bundled = families[name.lowercased()] {
                _ = registered
                let ext = variable(bundled.ext, weight: weight)
                let descriptor = variable(bundled.main, weight: weight).addingAttributes([.cascadeList: [ext]])
                return UIFont(descriptor: descriptor, size: size).familyName == bundled.main ? descriptor : nil
            }
            guard let installed = installedFamily(name) else { return nil }
            return UIFontDescriptor(fontAttributes: [.family: installed, .traits: [UIFontDescriptor.TraitKey.weight: weight.ui]])
        }
    }

    /// `font-style: italic` in a face, as `Italic.choose` decides from what the face carries: its
    /// italic cut, its `ital` axis, or the browser's synthetic oblique as a shear in the font's
    /// matrix, on the cascade's fonts too.
    private static func italicized(_ descriptor: UIFontDescriptor, _ font: UIFont) -> UIFontDescriptor {
        let cut = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic)
        let hasItalicFace = cut.map { CTFontGetSymbolicTraits($0).contains(.traitItalic) } ?? false
        let axes = (CTFontCopyVariationAxes(font) as? [[CFString: Any]] ?? []).compactMap { axis -> FontAxis? in
            guard let code = axis[kCTFontVariationAxisIdentifierKey] as? Int,
                  let minimum = axis[kCTFontVariationAxisMinimumValueKey] as? Double,
                  let maximum = axis[kCTFontVariationAxisMaximumValueKey] as? Double else { return nil }
            return FontAxis(tag: FontAxis.tag(code), minimum: minimum, maximum: maximum)
        }
        switch Italic.choose(hasItalicFace: hasItalicFace, axes: axes) {
        case .face:
            return descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) ?? descriptor
        case .axis(let tag, let value):
            let key = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
            var variation = descriptor.fontAttributes[key] as? [Int: Double] ?? [:]
            variation[FontAxis.code(tag)] = value
            return descriptor.addingAttributes([key: variation])
        case .oblique(let skew):
            let shear = CGAffineTransform(a: 1, b: 0, c: skew, d: 1, tx: 0, ty: 0)
            let cascade = (descriptor.fontAttributes[.cascadeList] as? [UIFontDescriptor] ?? []).map { $0.addingAttributes([.matrix: shear]) }
            return descriptor.addingAttributes(cascade.isEmpty ? [.matrix: shear] : [.matrix: shear, .cascadeList: cascade])
        }
    }

    /// The first family of a theme's list the device has (the system face when it has none), as
    /// a SwiftUI font and its line height. The system faces stay SwiftUI's own, as before themes.
    static func font(_ list: [FontFamily], size: CGFloat, weight: Font.Weight, italic: Bool = false, mono: Bool) -> (font: Font, lineHeight: CGFloat) {
        for family in list {
            switch family {
            case .system:
                let font = Font.system(size: size, weight: weight)
                return (italic ? font.italic() : font, UIFont.systemFont(ofSize: size, weight: weight.ui).lineHeight)
            case .systemMono:
                let font = Font.system(size: size, weight: weight, design: .monospaced)
                return (italic ? font.italic() : font, UIFont.systemFont(ofSize: size, weight: weight.ui).lineHeight)
            default:
                if let font = font(family, size: size, weight: weight, italic: italic) { return (Font(font), font.lineHeight) }
            }
        }
        return font([mono ? .systemMono : .system], size: size, weight: weight, italic: italic, mono: mono)
    }

    /// The theme's own face for UIKit text that SwiftUI doesn't draw (the navigation bar's
    /// title), or nil where the theme keeps the system face.
    static func themeFont(_ list: [FontFamily], size: CGFloat, weight: Font.Weight) -> UIFont? {
        for family in list {
            if family == .system || family == .systemMono { return nil }
            if let font = font(family, size: size, weight: weight) { return font }
        }
        return nil
    }

    private static let installed = Mutex<[String: String?]>([:])

    /// The device's own family for a name, looked up once.
    private static func installedFamily(_ name: String) -> String? {
        if let known = installed.withLock({ $0[name.lowercased()] }) { return known }
        let found = UIFont.familyNames.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        installed.withLock { $0[name.lowercased()] = .some(found) }
        return found
    }

    /// A variable font's descriptor at a weight on its `wght` axis (400 to 700 or 800 here).
    private static func variable(_ family: String, weight: Font.Weight) -> UIFontDescriptor {
        UIFontDescriptor(fontAttributes: [
            .family: family,
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [FontAxis.code("wght"): weight.axis],
        ])
    }
}

extension ThemeFonts {
    func list(_ face: TextFace) -> [FontFamily] {
        switch face {
        case .sans: sans
        case .chat: chat
        case .mono: mono
        }
    }
}

extension Font.Weight {
    var ui: UIFont.Weight {
        switch self {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        default: .regular
        }
    }

    /// The CSS weight, for a variable font's `wght` axis.
    var axis: Double {
        switch self {
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        default: 400
        }
    }
}
