import ApronKit
import SwiftUI
import UIKit

/// The web's ServerPane, as a sheet from the room list's title: the server's face, name, how
/// the connection stands and its host, its description, who you are with Edit Profile, its
/// address with copy and the protocol version, then Connect to Another Server… and Disconnect.
/// Ladle keeps several servers, so Disconnect signs out of this one, after the sign-out
/// confirmation; the others stay as they are.
struct ServerPaneView: View {
    let session: ServerSession
    var onEditProfile: () -> Void = {}
    var onConnect: () -> Void = {}
    @State private var copied = false
    @State private var disconnecting = false
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
                HStack(spacing: Tokens.Space.s2) {
                    Button("Connect to Another Server…") {
                        dismiss()
                        onConnect()
                    }
                    .buttonStyle(GhostButtonStyle(tone: Palette.accent))
                    if session.you != nil {
                        Button("Disconnect") { disconnecting = true }
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
        .signOutDialog(session: session, isPresented: $disconnecting) { dismiss() }
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
