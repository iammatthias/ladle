import ApronKit
import PhotosUI
import SwiftUI

/// The web's Composer: one raised box with a strong edge that turns accent on focus, the field,
/// and Send. A reply or edit shows its line above the box. Typing `@` opens the mention list
/// above it (the web's MentionPicker). With a hardware keyboard, Return sends and Shift-Return
/// starts a new line; Escape cancels a reply or edit.
///
/// With capability `embed:upload`, the attach menu adds photos and videos (PhotosPicker), a
/// photo or video from the camera, files (the document picker), a voice note, or a pasted image.
/// Each shows above the box as a tile while it is fitted to the server, and goes out with the
/// message (§4.8.4). Without the capability the menu is not there.
struct ComposerView: View {
    let session: ServerSession
    let roomID: String
    @Binding var draft: Draft
    let onSend: (String, [String], [Attachment]) -> Void
    var onProblem: (String) -> Void = { _ in }
    @FocusState private var focused: Bool
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var usingCamera = false
    @State private var recorder = VoiceRecorder()
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
            if !draft.attachments.isEmpty, !isEdit {
                AttachmentTray(attachments: draft.attachments) { id in draft.attachments.removeAll { $0.id == id } }
            }
            HStack(alignment: .bottom, spacing: Tokens.Space.s2) {
                if case .recording(let since) = recorder.state {
                    RecordingBar(since: since, cancel: { recorder.cancel() }, done: {
                        if let clip = recorder.finish() { attach(contentType: "audio/mp4") { clip } }
                    })
                } else {
                    field
                }
            }
            .padding(.vertical, Tokens.Space.s1)
            .padding(.leading, canAttach ? Tokens.Space.s1 : Tokens.Space.s3)
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
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]),
                      preferredItemEncoding: .compatible)
        .onChange(of: photoItems) {
            for item in photoItems {
                attach(contentType: nil) {
                    guard let file = try await item.loadTransferable(type: ImportedFile.self) else { throw CocoaError(.fileReadUnknown) }
                    return file.url
                }
            }
            photoItems = []
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): for url in urls { attach(contentType: nil) { url } }
            case .failure(let error): onProblem(errorText(error))
            }
        }
        .fullScreenCover(isPresented: $usingCamera) {
            CameraPicker { url in attach(contentType: nil) { url } }.ignoresSafeArea()
        }
        .onChange(of: recorder.state) {
            if recorder.state == .denied { onProblem("Ladle can't use the microphone. Allow it in Settings to record voice notes.") }
        }
    }

    @ViewBuilder
    private var field: some View {
        if canAttach { attachMenu }
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

    private var attachMenu: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            if CameraPicker.isAvailable {
                Button("Take Photo or Video", systemImage: "camera") { usingCamera = true }
            }
            Button("Choose File", systemImage: "doc") { importingFiles = true }
            if takesVoiceNotes {
                Button("Record Voice Note", systemImage: "mic") {
                    recorder.onLimit = { clip in attach(contentType: "audio/mp4") { clip } }
                    Task { await recorder.start(maxBytes: audioLimit) }
                }
            }
            if UIPasteboard.general.hasImages {
                Button("Paste Image", systemImage: "doc.on.clipboard") { pasteImages() }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.inkMuted)
                .frame(width: Tokens.Control.md, height: Tokens.Control.md)
                .background(Palette.hover, in: Circle())
                .touchTarget()
        }
        .accessibilityLabel("Attach")
        .disabled(!canWrite)
    }

    private var canAttach: Bool { session.canAttach && !isEdit }

    /// Voice notes go as `audio/mp4`; a server that states its media must take it.
    private var takesVoiceNotes: Bool {
        MediaLimits.verdict(for: "audio/mp4", in: session.mediaLimits?.upload) != .refused
    }

    private var audioLimit: Int? {
        if case .allowed(let limits) = MediaLimits.verdict(for: "audio/mp4", in: session.mediaLimits?.upload) { return limits.maxBytes }
        return nil
    }

    /// Adds a tile at once, then fits the file to the server. One that can't be sent comes off
    /// again with the reason.
    private func attach(contentType: String?, _ source: @escaping () async throws -> URL) {
        let item = DraftAttachment(name: "Preparing", phase: .preparing)
        draft.attachments.append(item)
        let limits = session.mediaLimits?.upload
        Task {
            do {
                let url = try await source()
                rename(item.id, to: url.lastPathComponent)
                let attachment = try await AttachmentStaging.prepare(url, name: url.lastPathComponent, contentType: contentType, limits: limits)
                guard let index = draft.attachments.firstIndex(where: { $0.id == item.id }) else { return }
                draft.attachments[index].phase = .ready(attachment)
            } catch {
                let name = draft.attachments.first { $0.id == item.id }?.name
                draft.attachments.removeAll { $0.id == item.id }
                onProblem([name, errorText(error)].compactMap { $0 }.joined(separator: ": "))
            }
        }
    }

    private func rename(_ id: UUID, to name: String) {
        if let index = draft.attachments.firstIndex(where: { $0.id == id }) { draft.attachments[index].name = name }
    }

    /// Pasted images, as PNG; the preparer turns a large one into JPEG.
    private func pasteImages() {
        for (index, image) in (UIPasteboard.general.images ?? []).enumerated() {
            attach(contentType: "image/png") {
                guard let data = image.pngData() else { throw CocoaError(.fileReadUnknown) }
                let file = try AttachmentStaging.importFolder().appending(path: index == 0 ? "Pasted Image.png" : "Pasted Image \(index + 1).png")
                try data.write(to: file)
                return file
            }
        }
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
        let preparing = draft.attachments.contains { $0.attachment == nil }
        let ready = isEdit ? [] : draft.attachments.compactMap(\.attachment)
        return canWrite && !preparing && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ready.isEmpty)
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
        onSend(text, mentions, isEdit ? [] : draft.attachments.compactMap(\.attachment))
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
                        Avatar(name: name, userID: person.userID, presence: session.presence(of: person.userID), size: .sm,
                               image: session.avatarURL(of: person.userID))
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
