import SwiftUI
import UIKit

/// An sRGB color from tokens.css: `0xRRGGBB` and an alpha.
struct RGBA: Hashable, Sendable {
    let rgb: UInt32
    let alpha: Double

    init(_ rgb: UInt32, _ alpha: Double = 1) {
        self.rgb = rgb
        self.alpha = alpha
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

/// A token's value in the dark theme (the web's reference) and the light one.
struct Themed<Value: Sendable>: Sendable {
    let dark: Value
    let light: Value

    init(_ dark: Value, _ light: Value) {
        self.dark = dark
        self.light = light
    }

    func value(for traits: UITraitCollection) -> Value {
        traits.userInterfaceStyle == .light ? light : dark
    }
}

struct ShadowToken: Hashable, Sendable {
    let y: CGFloat
    let blur: CGFloat
    let color: RGBA
}

/// A CSS `cubic-bezier` easing.
struct Curve: Hashable, Sendable {
    let x1, y1, x2, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        (self.x1, self.y1, self.x2, self.y2) = (x1, y1, x2, y2)
    }

    func animation(duration: Double) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration)
    }
}

extension Themed where Value == RGBA {
    /// The token as a color that follows the appearance. With Increase Contrast on, `other`
    /// replaces it when given (Ladle's only departure from the web's two themes).
    func color(increasedContrast other: Themed<RGBA>? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let token = traits.accessibilityContrast == .high ? (other ?? self) : self
            return token.value(for: traits).uiColor
        })
    }
}
