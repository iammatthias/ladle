import ApronKit
import SwiftUI

/// apron-web's `NotifyPrompt` (a `Nudge`): "Get notified when you're mentioned?", who mentioned
/// you and where, and how far notifications reach. Turn on asks iOS from that tap, as the
/// Notifications switch does; Not now is a choice too, so it isn't offered again. Above the
/// profile bar it says where the switch lives; above the composer it doesn't.
struct NotifyOfferView: View {
    let alerts: MessageAlerts
    let offer: NotifyOffer
    /// Push works here, so notifications reach this device with Ladle closed too.
    var whenClosed = false
    /// It sits above the profile bar, whose gear opens Preferences.
    var pointsAtPreferences = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                Image(systemName: "bell")
                    .imageScale(.small)
                    .foregroundStyle(Palette.accent)
                    .frame(width: Tokens.Control.md, height: Tokens.Control.md)
                    .background(Palette.accent.opacity(0.18), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Get notified when you’re mentioned?").apText(.ui, .semibold).foregroundStyle(Palette.ink)
                    Text(detail).apText(.sm).foregroundStyle(Palette.inkMuted)
                    if pointsAtPreferences {
                        Text("You can change this any time in Preferences.").apText(.sm).foregroundStyle(Palette.inkMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Tokens.Space.s2) {
                Spacer(minLength: 0)
                Button("Not now") { alerts.decline() }.buttonStyle(GhostButtonStyle())
                Button("Turn on") { Task { await alerts.turnOn() } }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(Tokens.Space.s3)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
        .accessibilityElement(children: .contain)
        .onAppear { UIAccessibility.post(notification: .announcement, argument: "Get notified when you’re mentioned? \(detail)") }
    }

    private var detail: String {
        let who = offer.from.flatMap { from in offer.room.map { "\(from) mentioned you in \($0). " } } ?? ""
        return who + "Ladle can alert you on this device\(whenClosed ? ", even when it’s closed" : " while it’s open")."
    }
}
