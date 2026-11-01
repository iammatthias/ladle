import ApronKit
import SwiftUI

/// The web's TimelineLoading pill (`float` and `top`): a spinner and what is happening, floating
/// over the timeline so nothing moves as it comes and goes. `rising` fades it in from below, as
/// over the composer; otherwise from above, as at the top.
struct LoadingPill: View {
    let label: String
    let rising: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var shown = false

    var body: some View {
        let shadow = Tokens.Shadow.float
        let float = colorScheme == .light ? shadow.light : shadow.dark
        HStack(spacing: Tokens.Space.s2) {
            Spinner(period: reduceMotion ? 2.4 : 0.8)
            Text(label).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
        }
        .padding(.vertical, Tokens.Space.s1)
        .padding(.leading, Tokens.Space.s3 - 2)
        .padding(.trailing, Tokens.Space.s3)
        .background(Palette.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line))
        .shadow(color: Color(uiColor: float.color.uiColor), radius: float.blur / 2, y: float.y)
        .opacity(shown || reduceMotion ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : rising ? 4 : -4)
        .onAppear { withAnimation(Motion.medium(reduceMotion)) { shown = true } }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The web's `ap-tlstatus-spin`: a 12 pt ring in muted ink with its top in the accent.
    private struct Spinner: View {
        let period: Double

        var body: some View {
            SwiftUI.TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                ZStack {
                    Circle().stroke(Palette.inkMuted.opacity(0.35), lineWidth: 2)
                    Circle().trim(from: 0.625, to: 0.875).stroke(Palette.accent, lineWidth: 2)
                }
                .padding(1)
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(turn * 360))
            }
        }
    }
}

/// Other rooms catching up while this one is current: the web's `ap-roomhead-updating`, a short
/// accent glint running along the header's foot. Under Reduce Motion it stands still, the whole
/// width, dimmed.
struct CatchingUpLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let glint = LinearGradient(colors: [Palette.accent.opacity(0), Palette.accent, Palette.accent.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
            if reduceMotion {
                Rectangle().fill(glint).opacity(Tokens.Opacity.dim)
            } else {
                SwiftUI.TimelineView(.animation) { context in
                    // ease-in-out over 1.4 s, from just before the leading edge to past the trailing one.
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                    Rectangle().fill(glint)
                        .frame(width: width * 0.4)
                        .offset(x: width * 0.4 * (-1 + 3.5 * eased))
                }
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// What a timeline's catching up shows, held by the renderer for its shots in place of the
    /// session's. The app never sets it.
    @Entry var heldPaneLoading: PaneLoading.Shown?
    /// The connection words your own dot says, held by the renderer for the profile bar's dashed
    /// ring. The app never sets it.
    @Entry var heldAwayWords: String?
}
