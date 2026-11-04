import ApronKit
import SwiftUI

/// Media the gate holds back (`MediaDecision.ask`), as the web's MediaAsk: a dashed tile in the
/// media's place showing what it is (its alt text, else its kind) and its full URL, so the viewer
/// can judge it (apron-web #186), cut in the middle past two lines. A tap loads this one, this
/// launch (Load). The tile's menu and its long press add Always Load from the site, which trusts
/// the site from then on, and Block, which hides everything from it from then on, whatever trusts
/// it; Preferences lists either. Both only where the site can be trusted (`https:`).
struct MediaAskTile: View {
    let ask: MediaAsk
    let what: String
    var symbol = "photo"
    /// Width over height when the sender said, which shapes the tile.
    var aspect: Double?
    let settings: MediaSettings

    static let width: CGFloat = 320

    static func symbol(_ kind: CardAsk.Kind) -> String {
        switch kind {
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .image: "photo"
        }
    }

    var body: some View {
        let height = min(200, max(120, Self.width / (aspect ?? 2)))
        Button { settings.loadOnce(ask.url) } label: {
            VStack(spacing: Tokens.Space.s1) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Palette.inkMuted)
                Text(what).apText(.ui, .semibold).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.center)
                Text(ask.url.absoluteString).apText(.sm).foregroundStyle(Palette.inkMuted)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                Text("Tap to Load").apText(.sm, .semibold).foregroundStyle(Palette.denim)
            }
            .padding(.horizontal, Tokens.Space.s8)
            .padding(.vertical, Tokens.Space.s3)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Menu { actions } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(Palette.inkMuted).touchTarget()
            }
            .accessibilityHidden(true)
        }
        .contextMenu { actions }
        .frame(maxWidth: Self.width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(what), \(ask.url.absoluteString), not loaded")
        .accessibilityHint("Loads it")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { settings.loadOnce(ask.url) }
        .accessibilityActions {
            if let origin = ask.origin {
                Button("Always Load from \(ask.host)") { settings.trust(origin, held: ask.held) }
                Button("Block \(ask.host)") { settings.block(origin) }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Load", systemImage: "arrow.down.circle") { settings.loadOnce(ask.url) }
        if let origin = ask.origin {
            Button("Always Load from \(ask.host)", systemImage: "checkmark.shield") { settings.trust(origin, held: ask.held) }
            Divider()
            Button("Block \(ask.host)", systemImage: "hand.raised", role: .destructive) { settings.block(origin) }
        }
    }
}

#Preview("Media ask") {
    let settings = MediaSettings()
    VStack(alignment: .leading, spacing: Tokens.Space.s4) {
        MediaAskTile(ask: MediaAsk(url: URL(string: "https://shazow.net/images/icon.png")!, host: "shazow.net", origin: "https://shazow.net"),
                     what: "embedded image from an external host", settings: settings)
        MediaAskTile(ask: MediaAsk(url: URL(string: "https://youtube.example/v.mp4")!, host: "youtube.example", origin: "https://youtube.example"),
                     what: "Video", symbol: "play.rectangle", aspect: 16 / 9, settings: settings)
    }
    .padding()
    .background(Palette.timeline)
}
