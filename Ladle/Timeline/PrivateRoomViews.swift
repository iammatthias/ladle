import ApronKit
import SwiftUI

/// The web's PrivateIntro: the start of a private room's timeline, once its history reaches back to
/// it. Who is in it, and what private means, on its plum.
struct PrivateIntroCard: View {
    let session: ServerSession
    let intro: PrivateIntro

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s3) {
                Faces(session: session, people: intro.faces, size: .lg)
                VStack(alignment: .leading, spacing: 2) {
                    Text(intro.name).apText(.title, .semibold).foregroundStyle(Palette.ink).lineLimit(2)
                    if let detail = intro.detail {
                        Text(detail).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(2)
                    }
                }
            }
            (Text("\(Image(systemName: "lock.fill")) Private room.").foregroundStyle(Palette.private).fontWeight(.semibold)
                + Text(" Only members and the server host can read messages here. Only members can add others.").foregroundStyle(Palette.inkMuted))
                .apText(.sm)
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.privateWash(0.55), in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(Palette.private.opacity(0.25)))
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.top, Tokens.Space.s4)
        .padding(.bottom, Tokens.Space.s2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("About this private room: \(intro.name)\(intro.detail.map { ", \($0)" } ?? ""). Only members and the server host can read messages here. Only members can add others.")
    }
}

/// The web's AddedBanner (#165), under a private room's header when someone else added you to it:
/// the sentence beside a × in the corner, and Mute, Leave and Dismiss in one row under it, until
/// Dismiss or the × puts it away.
struct AddedBanner: View {
    let session: ServerSession
    let roomID: String
    /// Leave, which asks first, as the room's own Leave does.
    let leave: () -> Void
    let problem: (String) -> Void
    @State private var busy = false

    var body: some View {
        let muted = session.mute(of: roomID) != nil
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                Text("You were added to this private room.").apText(.ui).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: Tokens.Control.md, alignment: .leading)
                Button("Close", systemImage: "xmark") { session.dismissAdded(roomID) }
                    .labelStyle(.iconOnly).buttonStyle(GhostButtonStyle())
            }
            HStack(spacing: Tokens.Space.s2) {
                if session.mayMute {
                    Button(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash") { mute(!muted) }
                        .buttonStyle(GhostButtonStyle(tone: Palette.ink))
                        .disabled(busy)
                }
                if session.server?.has("rooms") == true, session.mayWrite {
                    Button("Leave", systemImage: "rectangle.portrait.and.arrow.right", action: leave)
                        .buttonStyle(GhostButtonStyle(tone: Palette.danger))
                        .disabled(busy)
                }
                Button("Dismiss") { session.dismissAdded(roomID) }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.leading, Tokens.Space.s3)
        .padding(.trailing, Tokens.Space.s1)
        .padding(.vertical, Tokens.Space.s1)
        .background(Palette.privateWash(0.7), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.private.opacity(0.3)))
        .accessibilityElement(children: .contain)
    }

    private func mute(_ on: Bool) {
        busy = true
        Task {
            do { try await session.setMute(roomID, on ? .untilChanged : nil) } catch { problem(errorText(error)) }
            busy = false
        }
    }
}
