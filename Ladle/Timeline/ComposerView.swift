import ApronKit
import PhotosUI
import SwiftUI

/// The web's Composer: one raised box with a strong edge that turns accent on focus, the field,
/// and Send. A reply or edit shows its line above the box. Typing `@` opens the mention list
/// above it (the web's MentionPicker), and typing a command word after `/` lists the commands
/// the server's `/help` gives this user, with their usage and what they do. With a hardware
/// keyboard, Return sends and Shift-Return starts a new line; Escape cancels a reply or edit. Text is held to `TextLimit`: a counter shows
/// in the last 512 bytes, and past the limit Send is off and the composer says why.
///
/// With capability `embed:upload`, the attach menu adds photos and videos (PhotosPicker), a
/// photo or video from the camera, files (the document picker), a voice note, or a pasted image.
/// Each shows above the box as a tile while it is fitted to the server, and goes out with the
/// message (§4.8.4). Without the capability the menu is not there. Where the server states what
/// it takes (`UploadOffer`), the pickers show only that, the rest is greyed out, and the menu
/// says what the server takes.
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
            if let query = commandQuery, let found = session.commands?.matching(query), !found.isEmpty {
                CommandSuggestions(commands: found, pick: pickCommand)
                    .padding(.horizontal, Tokens.Space.s4)
                    .padding(.bottom, Tokens.Space.s1)
            } else if let query = mentionQuery, !candidates(query).isEmpty {
                MentionPicker(session: session, people: candidates(query), pick: pick)
                    .padding(.horizontal, Tokens.Space.s4)
                    .padding(.bottom, Tokens.Space.s1)
            } else if let query = emojiQuery, let found = session.emojiCatalog?.search(query, limit: 6), !found.isEmpty {
                EmojiSuggestions(emoji: found, pick: insert)
                    .padding(.horizontal, Tokens.Space.s4)
                    .padding(.bottom, Tokens.Space.s1)
            }
            if let target {
                HStack(spacing: Tokens.Space.s2) {
                    let who = Text(TextDirection.isolated(session.displayName(for: target.from))).fontWeight(.semibold).foregroundStyle(Palette.ink)
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
            if textLimit.isOver {
                Label("Too long to send by \(-textLimit.remaining) bytes. A message holds \(TextLimit.maxBytes.formatted()) bytes of text; emoji and accented letters take more than one.",
                      systemImage: "exclamationmark.circle")
                    .apText(.sm)
                    .foregroundStyle(Palette.danger)
                    .padding(.horizontal, Tokens.Space.s4)
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
        .animation(Motion.fast(reduceMotion), value: emojiQuery)
        .animation(Motion.fast(reduceMotion), value: commandQuery)
        .task(id: commandQuery != nil && session.status == .signedIn) {
            if commandQuery != nil { await session.loadCommands(in: roomID) }
        }
        .task(id: emojiQuery != nil) { if emojiQuery != nil { await session.loadEmojiCatalog() } }
        .onChange(of: draft.mode.isActive, initial: true) { if draft.mode.isActive { focused = true } }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 10,
                      matching: .any(of: (offer.images ? [.images] : []) + (offer.videos ? [.videos] : [])), preferredItemEncoding: .compatible)
        .onChange(of: photoItems) {
            for item in photoItems {
                attach(contentType: nil) {
                    guard let file = try await item.loadTransferable(type: ImportedFile.self) else { throw CocoaError(.fileReadUnknown) }
                    return file.url
                }
            }
            photoItems = []
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: offer.contentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): for url in urls { attach(contentType: nil) { url } }
            case .failure(let error): onProblem(errorText(error))
            }
        }
        .fullScreenCover(isPresented: $usingCamera) {
            CameraPicker(videos: offer.videos) { url in attach(contentType: nil) { url } }.ignoresSafeArea()
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
        if textLimit.showsCounter {
            Text(textLimit.remaining.formatted())
                .apText(.sm, .medium)
                .monospacedDigit()
                .foregroundStyle(textLimit.isOver ? Palette.danger : Palette.inkMuted)
                .frame(minHeight: Tokens.Control.md)
                .accessibilityLabel(textLimit.isOver ? "\(-textLimit.remaining) bytes over the limit" : "\(textLimit.remaining) bytes left")
        }
        Button("Send") { send() }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
    }

    private var attachMenu: some View {
        Menu {
            Section {
                Button(offer.videos ? "Photo Library" : "Photos", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                    .disabled(!offer.images && !offer.videos)
                if CameraPicker.isAvailable {
                    Button(offer.videos ? "Take Photo or Video" : "Take Photo", systemImage: "camera") { usingCamera = true }
                        .disabled(!offer.images && !offer.videos)
                }
                Button("Choose File", systemImage: "doc") { importingFiles = true }
                    .disabled(offer.contentTypes.isEmpty)
                Button("Record Voice Note", systemImage: "mic") {
                    recorder.onLimit = { clip in attach(contentType: "audio/mp4") { clip } }
                    Task { await recorder.start(maxBytes: audioLimit) }
                }
                .disabled(!takesVoiceNotes)
                if UIPasteboard.general.hasImages {
                    Button("Paste Image", systemImage: "doc.on.clipboard") { pasteImages() }
                        .disabled(!offer.images)
                }
            } header: {
                if let summary = offer.summary { Text(summary) }
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

    private var offer: UploadOffer { UploadOffer(session.mediaLimits?.upload) }

    private var textLimit: TextLimit { TextLimit(draft.text) }

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
        return canWrite && !preparing && !textLimit.isOver && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ready.isEmpty)
    }

    /// The command word being typed, outside an edit: an edit is never a command.
    private var commandQuery: String? {
        guard !isEdit else { return nil }
        return CommandHelp.query(in: draft.text)
    }

    /// Puts `/name ` in the field and keeps the keyboard up for the arguments.
    private func pickCommand(_ command: ServerCommand) {
        draft.text = "/\(command.name) "
        focused = true
    }

    /// The word being typed after `@`, when there is one.
    private var mentionQuery: String? {
        guard let word = draft.text.split(separator: " ", omittingEmptySubsequences: false).last,
              word.hasPrefix("@"), !word.contains("\n") else { return nil }
        return String(word.dropFirst())
    }

    /// The name being typed after `:`, for the custom emoji list (`ext:emoji`).
    private var emojiQuery: String? {
        guard let word = draft.text.split(separator: " ", omittingEmptySubsequences: false).last,
              word.hasPrefix(":"), word.count > 1, CustomEmoji.isKey(word + ":") else { return nil }
        return String(word.dropFirst())
    }

    /// Puts the key in place of the `:name` being typed, then a space.
    private func insert(_ emoji: CustomEmoji) {
        guard let colon = draft.text.range(of: ":", options: .backwards) else { return }
        draft.text.replaceSubrange(colon.lowerBound..., with: emoji.key + " ")
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

/// The command list above the composer, styled as the mention and `:` lists: each command's usage
/// and what it does, scrolling past five rows.
struct CommandSuggestions: View {
    let commands: [ServerCommand]
    let pick: (ServerCommand) -> Void
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands, id: \.name) { command in
                    Button { pick(command) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.usage).apText(.ui, .semibold, mono: true).foregroundStyle(Palette.ink).lineLimit(1)
                            Text(command.summary).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(2)
                        }
                        .padding(.horizontal, Tokens.Space.s2)
                        .padding(.vertical, Tokens.Space.s1)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchTarget, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(command.usage)
                    .accessibilityHint(command.summary)
                }
            }
            .padding(Tokens.Space.s1)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(height, Tokens.Size.touchTarget * 5.5))
        .frame(maxWidth: 480, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
    }
}
