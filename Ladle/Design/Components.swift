import SwiftUI

/// The web's UnreadCount: a 20 pt bubble. New messages in accent; mentions of you as `@ n` in
/// accent and semibold; a muted room's count quiet. Its VoiceOver label is the words.
/// What's new, in one bubble, as the web's UnreadCount (#202): ink with a touch of denim for
/// unread messages, orange with an @ when they mention you, grey when `quiet` (a muted row, a
/// thread card in the timeline), mentions too.
struct UnreadCount: View {
    let count: Int
    var mentions = false
    var quiet = false

    private var ground: Color {
        if quiet { Palette.quietCount } else if mentions { Palette.accent } else { Palette.unreadCount }
    }

    private var ink: Color {
        if quiet { Palette.ink } else if mentions { Palette.onAccent } else { Palette.chrome }
    }

    var body: some View {
        Text((mentions ? "@\u{202F}" : "") + (count > 99 ? "99+" : "\(count)"))
            .apText(.sm, .semibold)
            .monospacedDigit()
            .foregroundStyle(ink)
            .padding(.horizontal, Tokens.Space.s1_5)
            .frame(minWidth: 20, minHeight: 20)
            .background(ground, in: Capsule())
            .accessibilityLabel(mentions ? "\(count) \(count == 1 ? "mention" : "mentions")" : "\(count) new")
    }
}

/// A private room's lock (§4.2.4). Muted beside a room's name, as the web's `ap-lock`; in the
/// private color on a private thread's card, so that color never shows without it.
struct Lock: View {
    var tint = Palette.inkMuted

    var body: some View {
        Image(systemName: "lock.fill")
            .imageScale(.small)
            .foregroundStyle(tint)
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.fixedTypeSize) private var fixedTypeSize

    var body: some View {
        // At accessibility sizes the actions go under the words, which then keep the full width.
        let stacked = (fixedTypeSize ?? typeSize).isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Space.s2))
            : AnyLayout(HStackLayout(spacing: Tokens.Space.s3))
        layout {
            HStack(spacing: Tokens.Space.s3) {
                if !stacked {
                    Image(systemName: symbol)
                        .imageScale(.small)
                        .foregroundStyle(tone)
                        .frame(width: Tokens.Control.md, height: Tokens.Control.md)
                        .background(tone.opacity(0.18), in: Circle())
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).apText(.ui, .semibold).foregroundStyle(Palette.ink)
                    if let detail { Text(detail).apText(.sm).foregroundStyle(Palette.inkMuted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

extension View {
    /// A form section's header in the theme's interface face, as the web's field label
    /// (`.ap-fieldlabel`: `--text-sm`, 600, `--ink` in a dialog), not the system face a `Section`
    /// header otherwise takes.
    func formHeader() -> some View {
        apText(.sm, .semibold).foregroundStyle(Palette.ink).textCase(nil)
    }

    /// A form section's footer, as the web's form hint (`.ap-form-hint`: `--text-sm`, `--ink-muted`).
    func formFooter() -> some View {
        apText(.sm).foregroundStyle(Palette.inkMuted)
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

/// The web's placeholders (`ap-skel`): grey shapes where messages, rooms or members will be while
/// the app comes up or a room loads its first page, pulsing (still under Reduce Motion). Hidden
/// from VoiceOver; the words beside them say what is happening.
struct SkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

private struct SkeletonBar: View {
    let fraction: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.sm)
            .fill(Palette.hover)
            .frame(height: height)
            .containerRelativeFrame(.horizontal) { width, _ in width * fraction }
    }
}

/// Placeholder message rows (apron-web's TimelineLoading `rows`): an avatar and two lines each, in
/// widths that vary like real messages and stay the same on every render.
struct SkeletonRows: View {
    let count: Int
    private static let widths: [(name: CGFloat, text: CGFloat)] = [(0.30, 0.78), (0.22, 0.64), (0.26, 0.88), (0.18, 0.52), (0.28, 0.70), (0.24, 0.60)]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            ForEach(0 ..< count, id: \.self) { index in
                let widths = Self.widths[index % Self.widths.count]
                HStack(spacing: Tokens.Space.s3) {
                    Circle().fill(Palette.hover).frame(width: Tokens.AvatarSize.md, height: Tokens.AvatarSize.md)
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        SkeletonBar(fraction: widths.name * 0.8, height: 11)
                        SkeletonBar(fraction: widths.text * 0.8, height: 10)
                    }
                }
                .padding(.vertical, Tokens.Space.s2)
                .padding(.horizontal, Tokens.Space.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SkeletonPulse())
    }
}

/// Placeholder lines (the web's `ap-sect-skel` and `ap-memberlist-placeholder`): a rooms or members
/// list still coming up.
struct SkeletonLines: View {
    let fractions: [CGFloat]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ForEach(Array(fractions.enumerated()), id: \.offset) { _, fraction in
                SkeletonBar(fraction: fraction * 0.8, height: 12)
            }
        }
        .padding(.vertical, Tokens.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SkeletonPulse())
    }
}

/// apron-web's NoRoom while the app comes up (and TimelineLoading with rows): placeholder rows
/// standing where the newest messages will, and a pill saying what is happening under them.
struct RoomLoading: View {
    let label: String
    var rows = 6

    var body: some View {
        VStack(spacing: Tokens.Space.s3) {
            Spacer(minLength: 0)
            SkeletonRows(count: rows)
            LoadingPill(label: label, rising: true)
                .padding(.bottom, Tokens.Space.s3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
