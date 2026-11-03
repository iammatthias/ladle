import ApronKit
import SwiftUI
import UIKit

/// The web's ServerPane, as a sheet from the room list's title: the server's face, name, how
/// the connection stands and its host, its description, who you are with Edit Profile, its
/// address with copy and the protocol version, then Connect to Another Server…, Add Another
/// Account… (a second account on this server, as its own record) and Disconnect. Ladle keeps
/// several servers and accounts, so Disconnect closes this one's connection; the others stay as they are.
struct ServerPaneView: View {
    let session: ServerSession
    var onEditProfile: () -> Void = {}
    var onConnect: () -> Void = {}
    var onAddAccount: () -> Void = {}
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pane = session.pane
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                HStack(spacing: Tokens.Space.s3) {
                    RailTile(label: pane.name, image: session.serverAvatarURL, active: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pane.name).apText(.title, .semibold).foregroundStyle(Palette.ink).lineLimit(2)
                        HStack(spacing: Tokens.Space.s1) {
                            Circle().fill(color(pane.tone)).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(pane.connection).foregroundStyle(Palette.ink)
                            Text("·").accessibilityHidden(true)
                            Text(pane.host)
                        }
                        .apText(.sm)
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
                if let description = pane.description {
                    MessageBlocksView(blocks: MessageText.markdown(description, emoji: session.emojiCatalog), catalog: session.emojiCatalog, role: .ui,
                                      gate: session.mediaGate, settings: session.mediaSettings)
                        .apText(.ui).foregroundStyle(Palette.ink).tint(Palette.denim)
                        .written(in: TextDirection(of: description))
                        .task(id: session.server?.emojiCatalogURL) { await session.loadEmojiCatalog(for: description) }
                }
                if let signedInAs = pane.signedInAs {
                    HStack(spacing: Tokens.Space.s2) {
                        Text(signedInAs).apText(.ui).foregroundStyle(Palette.ink)
                        Button("Edit Profile") {
                            dismiss()
                            onEditProfile()
                        }
                        .buttonStyle(GhostButtonStyle(tone: Palette.accent))
                    }
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Address").apText(.sm, .semibold).foregroundStyle(Palette.inkMuted)
                    HStack(spacing: Tokens.Space.s1) {
                        Text(pane.address).apText(.ui).monospaced().foregroundStyle(Palette.ink).textSelection(.enabled).lineLimit(2)
                        Button(copied ? "Copied the address" : "Copy the address", systemImage: copied ? "checkmark" : "doc.on.doc") { copy(pane.address) }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Palette.inkMuted)
                            .buttonStyle(.borderless)
                            .frame(minWidth: Tokens.Size.touchTarget, minHeight: Tokens.Size.touchTarget)
                    }
                    if let version = pane.protocolVersion { Text(version).apText(.sm).foregroundStyle(Palette.inkMuted) }
                }
                if let warning = pane.versionWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .apText(.sm).foregroundStyle(Palette.ink)
                        .padding(Tokens.Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.warn))
                }
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Button("Connect to Another Server…") {
                            dismiss()
                            onConnect()
                        }
                        Button("Add Another Account…") {
                            dismiss()
                            onAddAccount()
                        }
                        .accessibilityHint("Signs in to \(session.serverName) as another account, beside this one")
                    }
                    .buttonStyle(GhostButtonStyle(tone: Palette.accent))
                    Spacer(minLength: 0)
                    if session.status != .offline {
                        // Closes the connection and keeps it closed; the saved session and what is kept stay (#177).
                        Button("Disconnect") {
                            dismiss()
                            Task { await session.disconnect() }
                        }
                        .buttonStyle(GhostButtonStyle(tone: Palette.danger))
                    }
                }
            }
            .padding(Tokens.Space.s4)
        }
        .background(Palette.chrome)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.chrome)
        .presentationDragIndicator(.visible)
    }

    private func color(_ tone: ServerPane.Tone) -> Color {
        switch tone {
        case .ok: Palette.ok
        case .warn: Palette.warn
        case .danger: Palette.danger
        }
    }

    private func copy(_ address: String) {
        UIPasteboard.general.string = address
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
