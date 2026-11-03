import ApronKit
import PhotosUI
import SwiftUI

/// You, on one server: apron-web's Preferences > Profile, in Preferences or, from the server
/// pane's Edit Profile, as a sheet of its own (`standalone`). Your avatar with Change and Remove,
/// your display name and the `@user_id` the server assigned, your bio where the server keeps one,
/// Revert and Save, the status picker with what the server answered, and how you sign in, with
/// Sign Out. Each server has its own. Pause notifications is in Preferences > Notifications, as
/// on the web.
struct YouView: View {
    let session: ServerSession
    /// A sheet of its own, with Done, rather than a screen in Preferences.
    let standalone: Bool
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
    /// Sign Out's Keep Local History (#199): on each time, so deleting is always chosen.
    @State private var keepHistory = true
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    /// An Add Email or Add External Sign-In form already under way; the design-review renderer
    /// sets it, the app never does.
    private let adding: AddSignInRows.Adding?

    init(session: ServerSession, standalone: Bool = true, adding: AddSignInRows.Adding? = nil) {
        self.session = session
        self.standalone = standalone
        self.adding = adding
        _form = State(initialValue: ProfileForm(you: session.you))
    }

    var body: some View {
        if standalone {
            NavigationStack {
                content.toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
            }
        } else {
            content
        }
    }

    private var content: some View {
            Form {
                if let you = session.you {
                    identity(you)
                    if session.keepsBio { bio }
                    if session.maySetStatus { status }
                    if session.offersReadReceipts { readReceipts }
                }
                signIn
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(!dirty || form.name.trimmingCharacters(in: .whitespaces).isEmpty || form.bioIsOver || !connected)
                    }
                }
            }
            .signOutDialog(session: session, isPresented: $signingOut, keepingHistory: keepHistory) { dismiss() }
            .photosPicker(isPresented: $pickingAvatar, selection: $avatarItem, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: avatarItem) {
                guard let item = avatarItem else { return }
                avatarItem = nil
                setAvatar(from: item)
            }
            .onChange(of: session.you?.userID) { form = ProfileForm(you: session.you) }
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
            Text("Display Name").formHeader()
        } footer: {
            Text("User ID assigned by server: \(Text("@" + you.userID).monospaced())").textSelection(.enabled).formFooter()
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
                    .fontWeight(.regular)
                    .monospacedDigit()
                    .foregroundStyle(form.bioIsOver ? Palette.danger : Palette.inkMuted)
            }
            .formHeader()
        }
    }

    private var hasAvatar: Bool { !(session.you?.json["avatar"]?.stringValue ?? "").isEmpty }

    // MARK: Read receipts

    /// apron-web's Read Receipts switch (#187), on this device for every server.
    private var readReceipts: some View {
        Section {
            Toggle("Read Receipts", isOn: Binding(get: { session.receiptSettings.isOn }, set: { session.receiptSettings.set($0) }))
                .tint(Palette.accent)
        } footer: {
            Text("See how far others have read in private rooms, and let them see how far you have. Sent while you’re online, not while invisible.")
                .formFooter()
        }
    }

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
            Text("Status").formHeader()
        } footer: {
            Text(StatusChoice.hint(for: current)).formFooter()
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

    // MARK: Sign-in

    private var signIn: some View {
        Section {
            Text(session.signInWords).apText(.ui).foregroundStyle(Palette.ink)
            if registered {
                AddSignInRows(session: session, adding: adding)
            }
            if session.you != nil {
                if session.offersKeepingHistory {
                    Toggle("Keep Local History", isOn: $keepHistory)
                }
                Button("Sign Out", role: .destructive) { signingOut = true }
            }
        } header: {
            Text("Sign-in").formHeader()
        } footer: {
            if let you = session.you {
                Text("Signed in to \(TextDirection.isolated(session.serverName)) as \(TextDirection.isolated(session.displayName(for: you))).").formFooter()
            }
        }
    }

    /// An account with a way back, not a guest: a passkey registered or an address added here
    /// adds to it (§4.10, §4.11), as apron-web's `passkeySession`.
    private var registered: Bool { session.you != nil && session.resumable && !session.isGuest }

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
    /// not be signed back in to, and without `keepingHistory` this account's local history goes
    /// (apron-web's "Signing out deletes local history. Continue?").
    func signOutDialog(session: ServerSession, isPresented: Binding<Bool>, keepingHistory: Bool = true,
                       then done: @escaping () -> Void = {}) -> some View {
        let deletes = !keepingHistory && session.offersKeepingHistory
        return confirmationDialog("Sign out of \(session.serverName)?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                done()
                Task { await session.signOut(keepingHistory: !deletes) }
            }
        } message: {
            let method = session.record.account?.scheme == "guest" || session.record.account?.scheme == "token"
                ? "This account signs in only with its token, which is deleted. You may not get back into it."
                : "You can sign in again with the same method."
            Text(deletes ? "Signing out deletes local history. \(method)" : method)
        }
    }
}
