import SwiftUI

/// The web's UnreadCount: a 20 pt bubble. New messages in accent; mentions of you as `@ n` in
/// accent and semibold; a muted room's count quiet. Its VoiceOver label is the words.
struct UnreadCount: View {
    let count: Int
    var mentions = false
    var quiet = false

    var body: some View {
        Text((mentions ? "@\u{202F}" : "") + (count > 99 ? "99+" : "\(count)"))
            .apText(.sm, .semibold)
            .monospacedDigit()
            .foregroundStyle(quiet ? Palette.ink : Palette.onAccent)
            .padding(.horizontal, Tokens.Space.s1_5)
            .frame(minWidth: 20, minHeight: 20)
            .background(quiet ? Palette.quietCount : Palette.accent, in: Capsule())
            .accessibilityLabel(mentions ? "\(count) \(count == 1 ? "mention" : "mentions")" : "\(count) new")
    }
}

/// A private room's lock (§4.2.4), always beside the private color.
struct Lock: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .imageScale(.small)
            .foregroundStyle(Palette.private)
            .accessibilityLabel("Private")
    }
}

/// The web's Callout: a note on denim-soft with a denim bar at its leading edge. Server
/// notices, `/help` output, and the welcome text use it.
struct Callout<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            if let title { Text(title).apText(.ui, .semibold) }
            content.apText(.ui)
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s3)
        .background(Palette.denimSoft, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Tokens.Radius.md, bottomLeadingRadius: Tokens.Radius.md)
                .fill(Palette.denim).frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .accessibilityElement(children: .combine)
    }
}

/// The web's ActionBanner: something to act on, on accent-soft with its actions at the end.
/// Ladle shows connection problems and sign-in with it instead of alerts.
struct ActionBanner<Actions: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    var tone = Palette.accent
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(tone)
                .frame(width: Tokens.Control.md, height: Tokens.Control.md)
                .background(tone.opacity(0.18), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).apText(.ui, .semibold).foregroundStyle(Palette.ink)
                if let detail { Text(detail).apText(.sm).foregroundStyle(Palette.inkMuted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, Tokens.Space.s2)
        .padding(.leading, Tokens.Space.s3)
        .padding(.trailing, Tokens.Space.s2)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(tone.opacity(0.45)))
        .accessibilityElement(children: .contain)
    }
}

/// The web's EmptyState: a title in ink, a muted line, and one action.
struct EmptyState<Action: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Tokens.Space.s2) {
            Text(title).apText(.title, .semibold).foregroundStyle(Palette.ink)
            Text(detail).apText(.ui).foregroundStyle(Palette.inkMuted)
            action.padding(.top, Tokens.Space.s2)
        }
        .multilineTextAlignment(.center)
        .padding(Tokens.Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The web's `ap-btn-primary`: accent fill, on-accent text, a 32 pt box padded to a 44 pt target.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .apText(.ui, .semibold)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, Tokens.Space.s4)
            .frame(minHeight: Tokens.Control.lg)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: Tokens.Radius.inner))
            .brightness(configuration.isPressed ? 0.08 : 0)
            .opacity(enabled ? 1 : Tokens.Opacity.disabled)
            .touchTarget()
    }
}

/// The web's `ap-btn-ghost`: ink-muted text with no fill until pressed.
struct GhostButtonStyle: ButtonStyle {
    var tone = Palette.inkMuted

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .apText(.ui, .semibold)
            .foregroundStyle(tone)
            .padding(.horizontal, Tokens.Space.s3)
            .frame(minHeight: Tokens.Control.lg)
            .background(configuration.isPressed ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.inner))
            .touchTarget()
    }
}

/// A list section's head, as the web's sidebar sections: small, semibold, ink-muted.
struct SectionHead: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 2) {
            Text(title).apText(.sm, .semibold)
            if let count { Text("· \(count)").apText(.sm) }
        }
        .foregroundStyle(Palette.inkMuted)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The web's TimelineDivider: a line, a label, a line. `new` is denim, a day is a centered pill.
struct TimelineDivider: View {
    enum Kind { case new, day }
    let kind: Kind
    let label: String

    var body: some View {
        switch kind {
        case .new:
            HStack(spacing: Tokens.Space.s3) {
                Rectangle().fill(Palette.denim).frame(height: 1)
                Text(label).apText(.sm, .medium).foregroundStyle(Palette.denim)
                Rectangle().fill(Palette.denim).frame(height: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("New messages")
        case .day:
            Text(label)
                .apText(.sm, .medium)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, Tokens.Space.s3)
                .padding(.vertical, 3)
                .background(Palette.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.line))
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
