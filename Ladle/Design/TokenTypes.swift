import ApronKit
import Observation
import SwiftUI
import Synchronization
import UIKit

/// The theme every token reads (`Tokens`, `Palette`, `TextRole`), Apron until Preferences sets
/// another. Reading it in a view's body subscribes the view, so a new theme redraws whatever
/// shows a token, with no per-view code. It is a lock, not an actor, because tokens are read
/// from anywhere (static helpers, UIKit color providers).
final class ActiveTheme: Observable, Sendable {
    static let shared = ActiveTheme()

    private let registrar = ObservationRegistrar()
    private let state = Mutex(ResolvedTheme.apron)

    var theme: ResolvedTheme {
        get {
            registrar.access(self, keyPath: \.theme)
            return state.withLock { $0 }
        }
        set {
            guard newValue != state.withLock({ $0 }) else { return }
            registrar.withMutation(of: self, keyPath: \.theme) { state.withLock { $0 = newValue } }
        }
    }

    static func color(_ name: String) -> Themed<RGBA> { shared.theme.color(name) }
    static func shadow(_ name: String) -> Themed<ShadowToken> { shared.theme.shadow(name) }
    static func length(_ name: String) -> CGFloat { CGFloat(shared.theme.number(name)) }
    static func number(_ name: String) -> Double { shared.theme.number(name) }
    static func fraction(_ name: String) -> Themed<Double> { shared.theme.fraction(name) }
    static func curve(_ name: String) -> Curve { shared.theme.curve(name) }
}

extension RGBA {
    var uiColor: UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

extension Themed {
    func value(for traits: UITraitCollection) -> Value {
        traits.userInterfaceStyle == .light ? light : dark
    }
}

extension Curve {
    func animation(duration: Double) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration)
    }
}

extension Themed where Value == RGBA {
    /// The token as a color that follows the appearance. With Increase Contrast on, `other`
    /// replaces it when given (Ladle's only departure from the web's two modes).
    func color(increasedContrast other: Themed<RGBA>? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let token = traits.accessibilityContrast == .high ? (other ?? self) : self
            return token.value(for: traits).uiColor
        })
    }
}
