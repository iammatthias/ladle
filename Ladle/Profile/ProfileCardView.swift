import ApronKit
import SwiftUI
import UIKit

/// Whose profile to show, and from which room: a name, an avatar, a mention chip, a member row
/// or a link's `user` opens it.
struct ProfileRequest: Identifiable {
    let user: UserObject
    let roomID: String?
    var id: String { user.userID }
}

/// The web's ProfileCard, as a sheet at medium height: their face and dot, name, "(you)",
/// `@user_id` with copy, status in words, when they were last seen, roles, the same-name warning,
/// their bio, whether they are in the room, and Message, Mention and Add to room. Message opens
/// the private conversation you have with them, or starts one.
struct ProfileCardView: View {
    let session: ServerSession
    let request: ProfileRequest
    /// Puts `@name` in the room's composer.
    var onMention: (String, String) -> Void = { _, _ in }
    @State private var note: (text: String, error: Bool)?
    @State private var adding = false
    @State private var messaging = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openRoom) private var openRoom

    var body: some View {
        let card = session.profile(of: request.user, in: request.roomID)
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                who(card)
                if card.sharesName {
                    Callout {
                        Text("Another user also shows as \(Text(card.name).bold()). Check the @user_id.")
                    }
                }
                if let bio = card.bio {
                    Text(bio).apText(.body).foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .written(in: TextDirection(of: bio))
                }
                if let membership = card.membership {
                    Text(membership).apText(.sm).foregroundStyle(Palette.inkMuted)
                }
                actions(card)
                if let note {
                    Text(note.text).apText(.sm).foregroundStyle(note.error ? Palette.danger : Palette.ok)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(Tokens.Space.s4 + Tokens.Space.s1)
        }
        .background(Palette.chrome)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.chrome)
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile of \(card.name)")
    }

    private func who(_ card: UserProfile) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Avatar(name: card.name, userID: card.userID, presence: card.presence, size: .card, image: session.avatarURL(of: card.userID))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                    Text(card.name).apText(.title, .semibold).foregroundStyle(Palette.ink).lineLimit(2)
                    if card.isYou { Text("(you)").apText(.sm).foregroundStyle(Palette.inkMuted) }
                }
                HStack(spacing: Tokens.Space.s1) {
                    Text("@" + card.userID).apText(.ui).monospaced().foregroundStyle(Palette.inkMuted).textSelection(.enabled)
                    Button("Copy @user_id", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = "@" + card.userID
                        note = ("Copied @\(card.userID)", false)
                    }
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .foregroundStyle(Palette.inkMuted)
                    .buttonStyle(.borderless)
                    .frame(minWidth: Tokens.Size.touchTarget, minHeight: Tokens.Size.touchTarget * 0.75)
                }
                if let status = card.status {
                    Text(status).apText(.sm).foregroundStyle(Palette.ink)
                }
                if let lastSeen = card.lastSeen {
                    Text(lastSeen).apText(.sm).foregroundStyle(Palette.inkMuted)
                }
                if !card.roles.isEmpty { RoleBadges(roles: card.roles).padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func actions(_ card: UserProfile) -> some View {
        if card.mayMessage || card.mayMention || card.mayAddToRoom {
            HStack(spacing: Tokens.Space.s2) {
                if card.mayMessage {
                    Button(messaging ? "Opening…" : "Message", systemImage: "bubble.left") { message(card.userID) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(messaging)
                }
                if card.mayMention {
                    let mention = Button("Mention") {
                        dismiss()
                        onMention(card.userID, card.name)
                    }
                    if card.mayMessage { mention.buttonStyle(GhostButtonStyle(tone: Palette.accent)) } else { mention.buttonStyle(PrimaryButtonStyle()) }
                }
                if card.mayAddToRoom, let roomID = request.roomID {
                    Button(adding ? "Adding…" : "Add to Room") { add(card.userID, to: roomID) }
                        .buttonStyle(GhostButtonStyle(tone: Palette.accent))
                        .disabled(adding)
                }
            }
        }
    }

    /// The conversation you have with them, else one started and opened. One started that couldn't
    /// add them is kept under Private, and the card says so.
    private func message(_ userID: String) {
        messaging = true
        note = nil
        Task {
            do {
                let started = try await session.message(userID)
                if started.refused.isEmpty {
                    dismiss()
                    openRoom(started.roomID)
                } else {
                    note = (Refusal.words(started.refused, name: session.pickedName) + " The room is kept under Private.", true)
                }
            } catch {
                note = (errorText(error), true)
            }
            messaging = false
        }
    }

    private func add(_ userID: String, to roomID: String) {
        adding = true
        note = nil
        Task {
            do {
                try await session.addMember(userID, to: roomID)
                note = ("Added to \(session.title(of: roomID))", false)
            } catch {
                note = (errorText(error), true)
            }
            adding = false
        }
    }
}
