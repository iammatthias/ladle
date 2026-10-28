import ApronKit
import SwiftUI

/// The web's Composer: one raised box with a strong edge that turns accent on focus, the field,
/// and Send. A reply or edit shows its line above the box. Typing `@` opens the mention list
/// above it (the web's MentionPicker). With a hardware keyboard, Return sends and Shift-Return
/// starts a new line; Escape cancels a reply or edit.
struct ComposerView: View {
    let session: ServerSession
    let roomID: String
    @Binding var draft: Draft
    let onSend: (String, [String]) -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let query = mentionQuery, !candidates(query).isEmpty {
                MentionPicker(session: session, people: candidates(query), pick: pick)
                    .padding(.horizontal, Tokens.Space.s4)
                    .padding(.bottom, Tokens.Space.s1)
            }
            if let target {
                HStack(spacing: Tokens.Space.s2) {
                    let who = Text(session.displayName(for: target.from)).fontWeight(.semibold).foregroundStyle(Palette.ink)
                    (isEdit ? Text("Editing your message") : Text("Replying to \(who)"))
                        .apText(.ui)
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Cancel", systemImage: "xmark") { draft = Draft() }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Palette.inkMuted)
                        .touchTarget()
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.leading, Tokens.Space.s4)
                .padding(.trailing, Tokens.Space.s2)
            }
            HStack(alignment: .bottom, spacing: Tokens.Space.s2) {
                TextField(placeholder, text: $draft.text, axis: .vertical)
                    .apText(.field)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1 ... 8)
                    .focused($focused)
                    .disabled(!canWrite)
                    .padding(.vertical, Tokens.Space.s1 + 3)
                    .padding(.horizontal, Tokens.Space.s1)
                    .frame(minHeight: Tokens.Control.md + Tokens.Space.s2 * 2 - Tokens.Space.s2, alignment: .center)
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        send()
                        return .handled
                    }
                Button("Send") { send() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.vertical, Tokens.Space.s1)
            .padding(.leading, Tokens.Space.s3)
            .padding(.trailing, Tokens.Space.s1)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(focused ? Palette.accent : Palette.lineStrong))
            .opacity(canWrite ? 1 : Tokens.Opacity.disabled)
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.top, Tokens.Space.s2)
            .padding(.bottom, Tokens.Space.s2)
        }
        .animation(Motion.fast(reduceMotion), value: mentionQuery)
        .onChange(of: draft.mode.isActive, initial: true) { if draft.mode.isActive { focused = true } }
    }

    private var placeholder: String {
        switch session.status {
        case .signedOut, .stopped: "Sign in to send"
        default: "Message \(session.title(of: roomID))"
        }
    }

    private var canWrite: Bool {
        switch session.status {
        case .signedOut, .stopped: false
        default: true
        }
    }

    private var target: MessageSnapshot? {
        switch draft.mode {
        case .new: nil
        case .reply(let message), .edit(let message): message
        }
    }

    private var isEdit: Bool {
        if case .edit = draft.mode { return true }
        return false
    }

    private var canSend: Bool {
        canWrite && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The word being typed after `@`, when there is one.
    private var mentionQuery: String? {
        guard let word = draft.text.split(separator: " ", omittingEmptySubsequences: false).last,
              word.hasPrefix("@"), !word.contains("\n") else { return nil }
        return String(word.dropFirst())
    }

    private func candidates(_ query: String) -> [UserObject] {
        let people = session.memberSections(roomID).flatMap(\.people).filter { $0.userID != session.you?.userID }
        guard !query.isEmpty else { return Array(people.prefix(6)) }
        return Array(people.filter {
            session.displayName(for: $0).localizedCaseInsensitiveContains(query) || $0.userID.localizedCaseInsensitiveContains(query)
        }.prefix(6))
    }

    private func pick(_ person: UserObject) {
        let name = session.displayName(for: person)
        guard let at = draft.text.range(of: "@", options: .backwards) else { return }
        draft.text.replaceSubrange(at.lowerBound..., with: "@\(name) ")
        draft.mentions[person.userID] = name
    }

    private func send() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let mentions = draft.mentions.filter { text.contains("@" + $0.value) }.map(\.key).sorted()
        onSend(text, mentions)
    }
}

/// The web's MentionPicker: a raised list above the composer, each person with their face,
/// name and `@user_id`.
struct MentionPicker: View {
    let session: ServerSession
    let people: [UserObject]
    let pick: (UserObject) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(people, id: \.userID) { person in
                let name = session.displayName(for: person)
                Button { pick(person) } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        Avatar(name: name, userID: person.userID, presence: session.presence(of: person.userID), size: .sm)
                        Text(name).apText(.field, .semibold).foregroundStyle(Palette.ink)
                        Text("@" + person.userID).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Tokens.Space.s2)
                    .frame(minHeight: Tokens.Size.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mention \(name)")
            }
        }
        .padding(Tokens.Space.s1)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
    }
}

private extension Draft.Mode {
    var isActive: Bool {
        if case .new = self { return false }
        return true
    }
}
