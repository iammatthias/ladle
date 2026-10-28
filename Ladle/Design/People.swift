import ApronKit
import SwiftUI
import UIKit

/// A user's shown status (§4.5.1). Each value has its own symbol shape, so it never depends on
/// color alone.
enum Presence: String {
    case online, idle, dnd, offline

    init?(_ user: JSONValue?) {
        guard let value = user?["status"]?.stringValue, let presence = Presence(rawValue: value) else { return nil }
        self = presence
    }

    var symbol: String {
        switch self {
        case .online: "circle.fill"
        case .idle: "moon.fill"
        case .dnd: "minus.circle.fill"
        case .offline: "circle"
        }
    }

    var tint: Color {
        switch self {
        case .online: .green
        case .idle: .orange
        case .dnd: .red
        case .offline: .secondary
        }
    }

    var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .dnd: "Do not disturb"
        case .offline: "Offline"
        }
    }
}

extension ServerSession {
    func presence(of userID: String) -> Presence? { Presence(users.user(userID)) }
}

struct PresenceGlyph: View {
    let presence: Presence
    var size: CGFloat = 10

    var body: some View {
        Image(systemName: presence.symbol)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(presence.tint)
            .accessibilityLabel(presence.label)
    }
}

/// Initials on a muted tone picked from the user id, with the presence glyph on its corner.
struct Avatar: View {
    let name: String
    let userID: String
    let presence: Presence?
    let size: CGFloat
    var rounded = false
    @Environment(\.theme) private var theme

    var body: some View {
        Text(initials)
            .font(theme.font(size: size * 0.4, theme.titleFace, weight: .semibold))
            .foregroundStyle(theme.palette.text.color)
            .frame(width: size, height: size)
            .background(tone, in: rounded ? AnyShape(RoundedRectangle(cornerRadius: size * 0.3)) : AnyShape(Circle()))
            .overlay(alignment: .bottomTrailing) {
                if let presence {
                    PresenceGlyph(presence: presence, size: max(9, size * 0.3))
                        .padding(2)
                        .background(theme.palette.background.color, in: Circle())
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    private var tone: Color {
        let hue = Double(userID.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hue: hue, saturation: 0.35, brightness: 0.36, alpha: 1)
                : UIColor(hue: hue, saturation: 0.22, brightness: 0.92, alpha: 1)
        })
    }
}
