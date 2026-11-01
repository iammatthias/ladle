import ApronKit
import SwiftUI

/// What the design-review renderer holds still in a timeline, which would otherwise come and go
/// faster than its capture: the floating day shown, a mention of you mid-pulse at a fraction of
/// its ring, and a row scrolled to. The app never sets it.
struct ShotPins: Hashable {
    var floatingDay = false
    var pulse: Double?
    var scrollTo: String?
}

extension EnvironmentValues {
    @Entry var shotPins = ShotPins()
}

/// The web's FloatingDay pill: the day of the messages at the top of the timeline while it
/// scrolls, a day pill with the float shadow, over the messages without taking space.
struct FloatingDayPill: View {
    let label: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shadow = Tokens.Shadow.float[colorScheme == .dark ? .dark : .light]
        TimelineDivider(kind: .day, label: label)
            .fixedSize()
            .compositingGroup()
            .shadow(color: Color(uiColor: shadow.color.uiColor), radius: shadow.blur / 2, y: shadow.y)
            .frame(maxWidth: .infinity)
            .padding(.top, Tokens.Space.s2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The web's `ap-ping`: one accent ring spreading 12 pt out from a row and fading, as a mention
/// of you arrives. `frozen` draws it still at that fraction of the way, for the renderer.
struct PulseRing: View {
    var frozen: Double?
    @State private var progress = 0.0

    var body: some View {
        let spread = 12 * (frozen ?? progress)
        RoundedRectangle(cornerRadius: Tokens.Radius.md + spread)
            .strokeBorder(Palette.accent.opacity(0.55 * (1 - (frozen ?? progress))), lineWidth: spread)
            .padding(-spread)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard frozen == nil else { return }
                withAnimation(.easeOut(duration: 0.9)) { progress = 1 }
            }
    }
}
