import ApronKit
import PhotosUI
import SwiftUI

/// You, on one server: apron-web's Preferences > Profile as a sheet. Your avatar with Change and
/// Remove, your display name and the `@user_id` the server assigned, your bio where the server
/// keeps one, Revert and Save, the status picker with what the server answered, and how you sign
/// in, with Sign Out. Each server has its own.
struct YouView: View {
    let session: ServerSession
    @State private var form: ProfileForm
    @State private var saving = false
    @State private var shownSaved = false
    @State private var choosing: String?
    @State private var answer: StatusAnswer?
    @State private var pickingAvatar = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarBusy: String?
    @State private var avatarError: String?
    @State private var signingOut = false
    /// What the server refused of the last Pause or Resume (§4.5: nothing changed), until the next.
    @State private var pauseRefused: (title: String, message: String)?
    @State private var pausing = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(session: ServerSession) {
        self.session = session
        _form = State(initialValue: ProfileForm(you: session.you))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let you = session.you {
                    identity(you)
                    if session.keepsBio { bio }
                    if session.maySetStatus { status }
                    if session.mayMute { pause }
                }
                signIn
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(!dirty || form.name.trimmingCharacters(in: .whitespaces).isEmpty || form.bioIsOver || !connected)
                    }
                }
            }
            .signOutDialog(session: session, isPresented: $signingOut) { dismiss() }
            .photosPicker(isPresented: $pickingAvatar, selection: $avatarItem, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: avatarItem) {
                guard let item = avatarItem else { return }
                avatarItem = nil
                setAvatar(from: item)
            }
            .onChange(of: session.you?.userID) { form = ProfileForm(you: session.you) }
        }
    }

    private var dirty: Bool { form.isDirty(keepsBio: session.keepsBio) }
    private var connected: Bool { session.status == .signedIn }

    // MARK: Profile

    private func identity(_ you: UserObject) -> some View {
        Section {
            HStack(spacing: Tokens.Space.s3) {
                Avatar(name: form.name.isEmpty ? you.userID : form.name, userID: you.userID, size: .lg, image: session.avatarURL(of: you.userID))
                    .overlay { if avatarBusy != nil { ProgressView().controlSize(.small) } }
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    if session.canSetAvatar {
                        Button(hasAvatar ? "Change Avatar" : "Upload Avatar") { pickingAvatar = true }
                            .disabled(avatarBusy != nil || !connected)
                    } else {
                        Text("This server takes no avatar uploads.").apText(.sm).foregroundStyle(Palette.inkMuted)
                    }
                    if hasAvatar {
                        Button("Remove Avatar", role: .destructive, action: removeAvatar)
                            .disabled(avatarBusy != nil || !connected)
                    }
                    if let avatarBusy { Text(avatarBusy).apText(.sm).foregroundStyle(Palette.inkMuted) }
                }
                .buttonStyle(.borderless)
                .apText(.ui)
            }
            if let avatarError { Text(avatarError).apText(.sm).foregroundStyle(Palette.danger) }
            TextField("Display name", text: $form.name)
                .textContentType(.nickname)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(save)
                .disabled(saving)
            switch form.outcome {
            case .altered(let kept): Text("The server saved your name as “\(kept)”.").apText(.sm).foregroundStyle(Palette.ink)
            case .declined(let note): Text(note).apText(.sm).foregroundStyle(Palette.danger)
            case .saved where shownSaved: Text("Saved.").apText(.sm).foregroundStyle(Palette.ok)
            default: EmptyView()
            }
            if dirty {
                Button("Revert", role: .cancel) { form.revert() }.disabled(saving)
            }
        } header: {
            Text("Display Name")
        } footer: {
            Text("User ID assigned by server: \(Text("@" + you.userID).monospaced())").textSelection(.enabled)
        }
    }

    private var bio: some View {
        Section {
            TextField("A few words about you, in plain text", text: $form.bio, axis: .vertical)
                .lineLimit(3 ... 6)
                .disabled(saving)
            if let bioError = form.bioError { Text(bioError).apText(.sm).foregroundStyle(Palette.danger) }
        } header: {
            HStack {
                Text("Bio")
                Spacer()
                Text("\(Bio.length(form.bio))/\(Bio.maxLength)")
                    .monospacedDigit()
                    .foregroundStyle(form.bioIsOver ? Palette.danger : Palette.inkMuted)
            }
        }
    }

    private var hasAvatar: Bool { !(session.you?.json["avatar"]?.stringValue ?? "").isEmpty }

    // MARK: Status

    private var status: some View {
        let current = session.chosenStatus ?? "online"
        let known = StatusChoice.all.contains { $0.value == current }
        return Section {
            Picker(selection: Binding(get: { current }, set: choose)) {
                ForEach(session.statusChoices) { choice in
                    Label {
                        Text(choice.label)
                        Text(choice.hint)
                    } icon: {
                        StatusIcon(status: choice.value)
                    }
                    .tag(choice.value)
                }
                if !known { Text("“\(current)”").tag(current) }
            } label: {
                Label {
                    Text(choosing == nil ? "Show Me As" : "Saving…")
                } icon: {
                    StatusIcon(status: current)
                }
            }
            .pickerStyle(.menu)
            .disabled(choosing != nil || !connected)
            if let answer {
                Callout(title: answer.title) { Text(answer.text) }
                    .listRowInsets(EdgeInsets(top: Tokens.Space.s2, leading: Tokens.Space.s4, bottom: Tokens.Space.s2, trailing: Tokens.Space.s4))
            }
        } header: {
            Text("Status")
        } footer: {
            Text(StatusChoice.hint(for: current))
        }
    }

    private func choose(_ value: String) {
        guard value != (session.chosenStatus ?? "online") || answer != nil else { return }
        choosing = value
        answer = nil
        Task {
            answer = await session.chooseStatus(value)
            choosing = nil
            if let answer { AccessibilityNotification.Announcement("\(answer.title). \(answer.text)").post() }
        }
    }

    // MARK: Pause

    /// apron-web's Pause notifications: a Pause… menu of how long, or Resume while paused, which
    /// only ask; the line changes when the server's `status` says so, perhaps shorter.
    private var pause: some View {
        Section {
            if let paused = session.pausedLine {
                Label("\(paused) · no notifications on your devices.", systemImage: "bell.slash")
                    .apText(.ui).foregroundStyle(Palette.warn)
                Button("Resume") { ask(nil) }
                    .disabled(pausing || !connected)
            } else {
                Menu {
                    ForEach(MuteChoice.pause(now: Date())) { choice in
                        Button {
                            ask(choice.end)
                        } label: {
                            Text(choice.title)
                            if let hint = choice.hint { Text(hint) }
                        }
                    }
                } label: {
                    Label(pausing ? "Pausing…" : "Pause…", systemImage: "bell.slash")
                }
                .disabled(pausing || !connected)
            }
            if let pauseRefused {
                Callout(title: pauseRefused.title) { Text(pauseRefused.message) }
                    .listRowInsets(EdgeInsets(top: Tokens.Space.s2, leading: Tokens.Space.s4, bottom: Tokens.Space.s2, trailing: Tokens.Space.s4))
            }
        } header: {
            Text("Pause Notifications")
        } footer: {
            if session.pause == nil {
                Text("Silence notifications on all your devices for a while. Only you see it.")
            }
        }
    }

    private func ask(_ end: MuteEnd?) {
        pausing = true
        pauseRefused = nil
        Task {
            do {
                try await session.setPause(end)
            } catch {
                pauseRefused = (end == nil ? "Notifications are still paused" : "Notifications weren’t paused", errorText(error))
                AccessibilityNotification.Announcement(pauseRefused?.title ?? "").post()
            }
            pausing = false
        }
    }

    // MARK: Sign-in

    private var signIn: some View {
        Section {
            Text(session.signInWords).apText(.ui).foregroundStyle(Palette.ink)
            if session.you != nil {
                Button("Sign Out", role: .destructive) { signingOut = true }
            }
        } header: {
            Text("Sign-in")
        } footer: {
            if let you = session.you {
                Text("Signed in to \(TextDirection.isolated(session.serverName)) as \(TextDirection.isolated(session.displayName(for: you))).")
            }
        }
    }

    // MARK: Actions

    private func save() {
        guard dirty, !saving else { return }
        focused = false
        saving = true
        Task {
            form = await session.save(form)
            saving = false
            guard form.outcome == .saved else { return }
            shownSaved = true
            try? await Task.sleep(for: .seconds(2))
            shownSaved = false
        }
    }

    private func removeAvatar() {
        avatarBusy = "Removing…"
        avatarError = nil
        Task {
            do {
                if try await session.removeAvatar() == false { avatarError = "The server kept your previous avatar." }
            } catch {
                avatarError = errorText(error)
            }
            avatarBusy = nil
        }
    }

    /// Crops the picked image to the avatar the server takes, then sends it with `/avatar`
    /// (§4.8.6). The server sends `user` with the new avatar once it is written.
    private func setAvatar(from item: PhotosPickerItem) {
        let limits = session.mediaLimits?.avatar
        avatarBusy = "Uploading…"
        avatarError = nil
        Task {
            defer { avatarBusy = nil }
            do {
                guard let file = try await item.loadTransferable(type: ImportedFile.self) else { throw CocoaError(.fileReadUnknown) }
                let avatar = try await Task.detached {
                    try AttachmentPreparer.prepareAvatar(file.url, limits: limits, into: AttachmentStaging.directory)
                }.value
                try await session.setAvatar(avatar)
            } catch {
                avatarError = errorText(error)
            }
        }
    }
}

/// A status's dot in a list or menu, as the web's StatusDot beside each choice: none is an empty
/// ring in muted ink, so the row keeps its place.
struct StatusIcon: View {
    let status: String

    var body: some View {
        if let presence = Presence(status: status) {
            StatusDot(presence: presence, diameter: 10)
        } else {
            Circle().strokeBorder(Palette.lineStrong, lineWidth: 1).frame(width: 10, height: 10).accessibilityHidden(true)
        }
    }
}

extension View {
    /// Confirms signing out of a server, saying what it costs: a token-only or guest account may
    /// not be signed back in to.
    func signOutDialog(session: ServerSession, isPresented: Binding<Bool>, then done: @escaping () -> Void = {}) -> some View {
        confirmationDialog("Sign out of \(session.serverName)?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                done()
                Task { await session.signOut() }
            }
        } message: {
            Text(session.record.account?.scheme == "guest" || session.record.account?.scheme == "token"
                 ? "This account signs in only with its token, which is deleted. You may not get back into it."
                 : "You can sign in again with the same method.")
        }
    }
}
