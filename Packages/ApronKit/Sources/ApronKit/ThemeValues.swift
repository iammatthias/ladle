import CoreGraphics
import Foundation

/// An sRGB color: `0xRRGGBB` and an alpha.
public struct RGBA: Hashable, Sendable, CustomStringConvertible {
    public let rgb: UInt32
    public let alpha: Double

    public init(_ rgb: UInt32, _ alpha: Double = 1) {
        self.rgb = rgb
        self.alpha = alpha
    }

    /// Channels from 0 to 255, rounded as apron-web's `toHex` rounds them.
    init(channels: (Double, Double, Double), alpha: Double = 1) {
        func byte(_ value: Double) -> UInt32 { UInt32(max(0, min(255, (value).rounded(.toNearestOrAwayFromZero)))) }
        self.init(byte(channels.0) << 16 | byte(channels.1) << 8 | byte(channels.2), max(0, min(1, alpha)))
    }

    var red: Double { Double((rgb >> 16) & 0xFF) }
    var green: Double { Double((rgb >> 8) & 0xFF) }
    var blue: Double { Double(rgb & 0xFF) }

    /// `#rrggbb`, lowercase, with the alpha after it when it is not 1.
    public var description: String {
        let hex = "#" + String(rgb, radix: 16).leftPadded(to: 6)
        return alpha == 1 ? hex : "\(hex) \(alpha)"
    }

    /// WCAG relative luminance, as apron-web's `luminance`.
    public var luminance: Double {
        func linear(_ n: Double) -> Double {
            let v = n / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between two colors, as apron-web's `contrast`.
    public func contrast(with other: RGBA) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

private extension String {
    func leftPadded(to length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}

/// The two color modes a theme gives values for.
public enum ColorMode: String, Sendable, CaseIterable {
    case light, dark
}

/// A token's value in dark mode (the web's reference) and light.
public struct Themed<Value: Sendable>: Sendable {
    public let dark: Value
    public let light: Value

    public init(_ dark: Value, _ light: Value) {
        self.dark = dark
        self.light = light
    }

    public subscript(mode: ColorMode) -> Value { mode == .light ? light : dark }
}

extension Themed: Equatable where Value: Equatable {}
extension Themed: Hashable where Value: Hashable {}

public struct ShadowToken: Hashable, Sendable {
    public let y: CGFloat
    public let blur: CGFloat
    public let color: RGBA

    public init(y: CGFloat, blur: CGFloat, color: RGBA) {
        (self.y, self.blur, self.color) = (y, blur, color)
    }
}

/// A CSS `cubic-bezier` easing.
public struct Curve: Hashable, Sendable {
    public let x1, y1, x2, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        (self.x1, self.y1, self.x2, self.y2) = (x1, y1, x2, y2)
    }
}
