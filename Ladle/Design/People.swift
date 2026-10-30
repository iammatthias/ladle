import ApronKit
import SwiftUI
import UIKit

/// Each status has its own shape, as the web's StatusDot: online is a disc, idle a crescent,
/// do-not-disturb a disc with a bar, offline a ring. So no state rests on color alone, and every
/// list that shows one also says it in words to VoiceOver.
extension Presence {
    var color: Color {
        switch self {
        case .online: Tokens.Color.presenceOnline.color()
        case .idle: Tokens.Color.presenceIdle.color()
        case .dnd: Tokens.Color.presenceDnd.color()
        case .offline: Tokens.Color.presenceOffline.color()
        }
    }
}

/// The web's StatusDot: 8 pt by default (7 small, 12 large).
struct StatusDot: View {
    let presence: Presence
    var diameter: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let d = size.width
            var shape = Path(ellipseIn: CGRect(origin: .zero, size: size))
            switch presence {
            case .online:
                break
            case .idle:
                let r = d * 0.36
                shape = shape.subtracting(Path(ellipseIn: CGRect(x: d * 0.18 - r, y: d * 0.18 - r, width: r * 2, height: r * 2)))
            case .dnd:
                shape = shape.subtracting(Path(roundedRect: CGRect(x: d * 0.19, y: d * 0.38, width: d * 0.62, height: d * 0.24), cornerRadius: d * 0.06))
            case .offline:
                let r = d * 0.25
                shape = shape.subtracting(Path(ellipseIn: CGRect(x: d / 2 - r, y: d / 2 - r, width: r * 2, height: r * 2)))
            }
            context.fill(shape, with: .color(presence.color))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// Initials on a tint picked from the `user_id` (the web's `avatarHue`), so a person keeps one
/// color here and in the web client. With a presence, its dot sits in a cut at the corner.
struct Avatar: View {
    enum Size {
        case xs, sm, md, lg

        var diameter: CGFloat {
            switch self {
            case .xs: Tokens.AvatarSize.xs
            case .sm: Tokens.AvatarSize.sm
            case .md: Tokens.AvatarSize.md
            case .lg: Tokens.AvatarSize.lg
            }
        }

        /// The web's initials sizes: 7, 9, 12 and 18 px.
        var initials: CGFloat {
            switch self {
            case .xs: 7
            case .sm: 9
            case .md: 12
            case .lg: 18
            }
        }

        var dot: CGFloat {
            switch self {
            case .xs, .sm: 7
            case .md: 8
            case .lg: 12
            }
        }

        var gap: CGFloat { self == .lg ? 3 : self == .md ? 2 : 1.5 }
    }

    let name: String
    let userID: String
    var presence: Presence?
    var size = Size.md
    /// The user's avatar (§4.8.6), already checked by `MediaPolicy`; the initials show until it
    /// loads, and stay when it doesn't.
    var image: URL?

    var body: some View {
        let hue = Self.hue(userID)
        Text(Self.initials(name))
            .font(.system(size: size.initials, weight: .semibold))
            .foregroundStyle(Self.tint(hue, ink: true))
            .frame(width: size.diameter, height: size.diameter)
            .background(Self.tint(hue, ink: false), in: Circle())
            .overlay {
                if let image { AvatarImage(url: image, diameter: size.diameter) }
            }
            .mask {
                if presence != nil {
                    let cut = size.dot / 2 + size.gap
                    Rectangle().overlay(alignment: .bottomTrailing) {
                        Circle().frame(width: cut * 2, height: cut * 2)
                            .offset(x: cut - size.dot / 2, y: cut - size.dot / 2)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                } else {
                    Rectangle()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let presence { StatusDot(presence: presence, diameter: size.dot) }
            }
            .accessibilityHidden(true)
    }

    /// Loads the avatar as an image only, never as a document (§4.8.6).
    private struct AvatarImage: View {
        let url: URL
        let diameter: CGFloat
        @State private var image: UIImage?
        @Environment(\.displayScale) private var scale

        var body: some View {
            ZStack {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .task(id: url) {
                image = MediaLoader.shared.cachedImage(url, maxPixel: diameter * scale)
                if image == nil { image = try? await MediaLoader.shared.image(url, maxPixel: diameter * scale) }
            }
        }
    }

    /// The web's `initials`: the first letter of the first and last words.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.first else { return "?" }
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        return (String(first) + last).uppercased()
    }

    /// The web's `avatarHue`: FNV-1a over the UTF-16 code units, the murmur3 finalizer, mod 360.
    static func hue(_ userID: String) -> Double {
        var hash: UInt32 = 0x811C_9DC5
        for unit in userID.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        hash ^= hash >> 16
        hash = hash &* 0x85EB_CA6B
        hash ^= hash >> 13
        hash = hash &* 0xC2B2_AE35
        hash ^= hash >> 16
        return Double(hash % 360)
    }

    /// `.ap-avatar-hued`: oklch(0.33 0.06 h) on oklch(0.86 0.08 h) in dark, oklch(0.92 0.045 h)
    /// under oklch(0.42 0.12 h) in light.
    static func tint(_ hue: Double, ink: Bool) -> Color {
        Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle != .light
            return switch (dark, ink) {
            case (true, false): oklch(0.33, 0.06, hue)
            case (true, true): oklch(0.86, 0.08, hue)
            case (false, false): oklch(0.92, 0.045, hue)
            case (false, true): oklch(0.42, 0.12, hue)
            }
        })
    }

    static func oklch(_ l: Double, _ c: Double, _ h: Double) -> UIColor {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        func encode(_ x: Double) -> CGFloat {
            let v = min(1, max(0, x))
            return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return UIColor(red: encode(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_),
                       green: encode(-1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_),
                       blue: encode(-0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_), alpha: 1)
    }
}

/// The web's RoleBadges: a user's roles as small outlined caps beside their name, `admin` in
/// accent, `bot` in denim, any other role (`mod`, or a label such as `announce`) as written in
/// muted ink. Roles are for display only (§3.3). Badges that don't fit drop off the end whole.
struct RoleBadges: View {
    let roles: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: roles.count, to: 0, by: -1)), id: \.self) { count in
                HStack(spacing: 4) { ForEach(roles.prefix(count), id: \.self, content: badge) }
            }
            EmptyView()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(roles.joined(separator: ", "))
    }

    private func badge(_ role: String) -> some View {
        let tone = role == "admin" ? Palette.accent : role == "bot" ? Palette.denim : nil
        return Text(role)
            .textCase(.uppercase)
            .tracking(0.3)
            .apText(.caps, .semibold)
            .lineLimit(1)
            .foregroundStyle(tone ?? Palette.inkMuted)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(tone?.opacity(0.55) ?? Palette.lineStrong))
            .fixedSize()
    }
}
