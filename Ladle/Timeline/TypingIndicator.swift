import ApronKit
import SwiftUI

/// The web's TypingIndicator, above the composer in regular width: three bobbing dots and who is
/// typing (`TypingLine.line`). Its row stays while nobody is, so nothing moves when it fills.
/// VoiceOver reads the words as they change.
struct TypingIndicator: View {
    let names: [String]

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            if let line = TypingLine.line(names) {
                TypingDots()
                Text(line).lineLimit(1)
            }
        }
        .apText(.sm)
        .foregroundStyle(Palette.inkMuted)
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.top, Tokens.Space.s1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The web's TypingDots: three 4 pt dots that bob in turn every 1.2 s (`ap-bob`, 0.15 s apart).
/// Reduce Motion holds them still and dimmed, as the web does.
struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SwiftUI.TimelineView(.animation(paused: reduceMotion)) { context in
            HStack(spacing: 3) {
                ForEach(0 ..< 3, id: \.self) { index in
                    let bob = reduceMotion ? nil : Self.bob(at: context.date.timeIntervalSinceReferenceDate - Double(index) * 0.15)
                    Circle()
                        .fill(Palette.inkMuted)
                        .frame(width: 4, height: 4)
                        .offset(y: bob?.offset ?? 0)
                        .opacity(bob?.opacity ?? Tokens.Opacity.dim)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// `ap-bob`: at rest and half seen at 0 %, 60 % and 100 % of the cycle, up 3 pt and fully
    /// seen at 30 %, eased in and out between.
    static func bob(at time: Double) -> (offset: CGFloat, opacity: Double) {
        let phase = time.truncatingRemainder(dividingBy: 1.2) / 1.2
        let rise: Double
        switch phase {
        case ..<0: rise = 0
        case ..<0.3: rise = phase / 0.3
        case ..<0.6: rise = 1 - (phase - 0.3) / 0.3
        default: rise = 0
        }
        let eased = (1 - cos(rise * .pi)) / 2
        return (-3 * eased, 0.5 + 0.5 * eased)
    }
}
