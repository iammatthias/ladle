import ApronKit
import SwiftUI

/// The web's RateLimitNotice: a wait the server asked for, above the composer it holds back.
/// What waits ("Sending is paused."), then the time left, counting down each second; a ring that
/// empties, or a clock for a wait of an hour or more, which can be put away. VoiceOver hears the
/// wait once, as it began, not every tick.
struct RateLimitNotice: View {
    let scope: LimitScope
    let wait: LimitWait
    var onDismiss: (() -> Void)?

    var body: some View {
        if let words = WaitWords.notice(scope) {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, wait.until.timeIntervalSince(context.date))
                HStack(spacing: Tokens.Space.s2) {
                    icon(left: left)
                    (Text(words.title + " ").foregroundStyle(Palette.ink)
                        + Text("\(words.lead) \(WaitWords.countdown(left, long: wait.isLong))\(words.end)").foregroundStyle(Palette.inkMuted))
                        .apText(.sm)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if wait.isLong, let onDismiss {
                        Button("Dismiss", systemImage: "xmark", action: onDismiss)
                            .labelStyle(.iconOnly)
                            .buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(.vertical, Tokens.Space.s1_5)
                .padding(.horizontal, Tokens.Space.s3)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(words.title) \(words.lead) \(WaitWords.spoken(wait.until.timeIntervalSince(wait.since), long: wait.isLong))\(words.end)")
            }
        }
    }

    @ViewBuilder
    private func icon(left: TimeInterval) -> some View {
        if wait.isLong {
            Image(systemName: "clock").foregroundStyle(Palette.warn)
        } else {
            let total = max(1, wait.until.timeIntervalSince(wait.since))
            ZStack {
                Circle().stroke(Palette.line, lineWidth: 3)
                Circle().trim(from: 0, to: left / total)
                    .stroke(Palette.warn, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .padding(3)
        }
    }
}
