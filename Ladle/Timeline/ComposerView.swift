import ApronKit
import PhotosUI
import SwiftUI

/// The web's Composer: one raised box with a strong edge that turns accent on focus, the field,
/// and Send. A reply or edit shows its line above the box. Typing `@` opens the mention list
/// above it (the web's MentionPicker), and typing a command word after `/` lists the commands
/// the server's `/help` gives this user, with their usage and what they do. With a hardware
/// keyboard, Return sends and Shift-Return starts a new line; Escape cancels a reply or edit.
/// While a list shows, ↑ and ↓ move its highlighted row, Tab and Return pick it, and Escape
/// puts the list away (`SuggestionCursor`), as the web's AutocompletePicker. Text is held to
/// `TextLimit`: a counter shows in the last 512 bytes, and past the limit Send is off and the
/// composer says why.
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
    @Binding var draft: ComposerDraft
    /// Where fitted files are kept while the draft holds them (`Drafts.staging`).
    let staging: URL
    let onSend: (ComposerDraft) -> Void
    /// Send while a wait holds it back: the notice shows again if it was put away.
    var onHeld: () -> Void = {}
    var onProblem: (String) -> Void = { _ in }
    @FocusState private var focused: Bool
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var usingCamera = false
    @State private var recorder = VoiceRecorder()
    @State private var cursor = SuggestionCursor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let list = suggestions {
                    let row = SuggestionRows(highlighted: cursor.highlighted(count: list.count), showsKey: sizeClass == .regular,
                                             hover: { cursor.hover($0) }, pick: { pick($0, of: list) })
                    switch list {
                    case .commands(let found): CommandSuggestions(commands: found, rows: row)
                    case .mentions(let found): MentionPicker(session: session, items: found, rows: row)
                    case .emoji(let found): EmojiSuggestions(emoji: found, rows: row)
                    case .rooms(let found): RoomSuggestions(rooms: found, rows: row)
                    }
                }
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.bottom, Tokens.Space.s1)
            if draft.field.mode != .new {
                HStack(spacing: Tokens.Space.s2) {
                    targetLine
                        .apText(.ui)
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Cancel", systemImage: "xmark") {
                        if draft.field.isEdit { draft = ComposerDraft() } else { draft.field.mode = .new }
                    }
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
            if !draft.files.isEmpty, !draft.field.isEdit {
                AttachmentTray(attachments: draft.files) { id in draft.files.removeAll { $0.id == id } }
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
        .animation(Motion.fast(reduceMotion), value: draft.field.query)
        .task(id: typingCommand && session.status == .signedIn) {
            if typingCommand { await session.loadCommands(in: roomID) }
        }
        .task(id: typingEmoji) { if typingEmoji { await session.loadEmojiCatalog() } }
        .onChange(of: draft.field.text, initial: true) { cursor.follow(draft.field.query, text: draft.field.text) }
        .onChange(of: draft.field.text) {
            // Typing in the composer, never the editor, says so (§4.6), as the web's `composerInput`.
            // An emptied field is most often a sent one, which the message itself ends.
            if !draft.field.isEdit, !draft.field.text.isEmpty { session.composerChanged(in: roomID) }
        }
        .onChange(of: draft.field.mode, initial: true) { if draft.field.mode != .new { focused = true } }
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
        TextField(placeholder, text: $draft.field.text, axis: .vertical)
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
                if !press.modifiers.contains(.command), use(.enter) { return .handled }
                send()
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down) { press in
                let key: SuggestionCursor.Key = switch press.key {
                case .upArrow: .up
                case .downArrow: .down
                case .tab: .tab
                default: .escape
                }
                return use(key) ? .handled : .ignored
            }
        if textLimit.showsCounter {
            Text(textLimit.remaining.formatted())
                .apText(.sm, .medium)
                .monospacedDigit()
                .foregroundStyle(textLimit.isOver ? Palette.danger : Palette.inkMuted)
                .frame(minHeight: Tokens.Control.md)
                .accessibilityLabel(textLimit.isOver ? "\(-textLimit.remaining) bytes over the limit" : "\(textLimit.remaining) bytes left")
        }
        // While the server asked sending to wait, Send counts down and the draft stays, as the web's.
        if let wait = session.composerWait(withFiles: !draft.files.isEmpty) {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, wait.until.timeIntervalSince(context.date))
                Button { onHeld() } label: {
                    Label(WaitWords.countdown(left, long: left >= WaitWords.long), systemImage: "hourglass")
                        .labelStyle(TightLabel())
                        .monospacedDigit()
                }
                .buttonStyle(PrimaryButtonStyle())
                .opacity(0.6)
                .accessibilityLabel("Send again in \(WaitWords.spoken(left, long: left >= WaitWords.long))")
            }
        } else {
            Button("Send") { send() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
        }
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

    /// "Editing your message", or who the reply answers; a kept reply to a message not loaded
    /// yet says only that it is a reply.
    private var targetLine: Text {
        if draft.field.isEdit { return Text("Editing your message") }
        guard let id = draft.field.replyTo, let message = session.store.message(id) else { return Text("Replying to a message") }
        let who = Text(TextDirection.isolated(session.displayName(for: message.from))).fontWeight(.semibold).foregroundStyle(Palette.ink)
        return Text("Replying to \(who)")
    }

    private var canAttach: Bool { session.canAttach && !draft.field.isEdit }

    private var offer: UploadOffer { UploadOffer(session.mediaLimits?.upload) }

    private var textLimit: TextLimit { TextLimit(draft.field.text) }

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
        let item = StagedFile(name: "Preparing", phase: .preparing)
        draft.files.append(item)
        let limits = session.mediaLimits?.upload
        Task {
            do {
                let url = try await source()
                rename(item.id, to: url.lastPathComponent)
                let attachment = try await AttachmentStaging.prepare(url, name: url.lastPathComponent, contentType: contentType, limits: limits, into: staging)
                guard let index = draft.files.firstIndex(where: { $0.id == item.id }) else { return }
                draft.files[index].phase = .ready(attachment)
            } catch {
                let name = draft.files.first { $0.id == item.id }?.name
                draft.files.removeAll { $0.id == item.id }
                onProblem([name, errorText(error)].compactMap { $0 }.joined(separator: ": "))
            }
        }
    }

    private func rename(_ id: UUID, to name: String) {
        if let index = draft.files.firstIndex(where: { $0.id == id }) { draft.files[index].name = name }
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

    private var canSend: Bool {
        canWrite && draft.field.canSend(readyFiles: draft.files.compactMap(\.attachment).count,
                                        preparing: draft.files.contains { $0.attachment == nil })
    }

    private var typingCommand: Bool {
        if case .command = draft.field.query { return true }
        return false
    }

    private var typingEmoji: Bool {
        if case .emoji = draft.field.query { return true }
        return false
    }

    /// The list above the field, unless Escape put it away at this text.
    private var suggestions: DraftSuggestions? {
        cursor.shows(draft.field.text) ? session.suggestions(for: draft.field, in: roomID) : nil
    }

    /// A key pressed while a list shows, as the web's AutocompletePicker: whether the list took it.
    private func use(_ key: SuggestionCursor.Key) -> Bool {
        guard let list = suggestions else { return false }
        switch cursor.press(key, count: list.count, text: draft.field.text) {
        case .ignored: return false
        case .moved, .dismissed: return true
        case .pick(let index):
            pick(index, of: list)
            return true
        }
    }

    /// Puts the row at `index` in place of what is typed, by touch or key.
    private func pick(_ index: Int, of list: DraftSuggestions) {
        switch list {
        case .commands(let found):
            draft.field.insert(found[index])
            focused = true
        case .mentions(let found):
            switch found[index] {
            case .person(let person): draft.field.insert(mention: person.userID, named: session.displayName(for: person))
            case .role(let role): draft.field.insert(role: role.role)
            }
        case .emoji(let found): draft.field.insert(found[index])
        case .rooms(let found): draft.field.insert(room: found[index].id)
        }
    }

    private func send() {
        if session.composerWait(withFiles: !draft.files.isEmpty) != nil { return onHeld() }
        guard canSend else { return }
        onSend(draft)
    }
}

/// The composer's `#` list, styled as the mention list: each room's or thread's title, a lock
/// when private, and its `#room_id`. Picking one puts `#room_id` in the draft.
struct RoomSuggestions: View {
    let rooms: [RoomSuggestion]
    let rows: SuggestionRows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
                Button { rows.pick(index) } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        Image(systemName: room.isThread ? "text.bubble" : "number")
                            .foregroundStyle(Palette.inkMuted)
                            .frame(width: Tokens.AvatarSize.sm)
                        if room.isPrivate { Lock(tint: Palette.private) }
                        Text(TextDirection.isolated(room.title)).apText(.field, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
                        Text("#" + room.id).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Tokens.Space.s2)
                    .frame(minHeight: Tokens.Size.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .suggestionRow(index, of: rows)
                .accessibilityLabel("\(room.isThread ? "Thread" : "Room") \(room.title)\(room.isPrivate ? ", private" : "")")
                .accessibilityHint("Links it in your message")
            }
        }
        .padding(Tokens.Space.s1)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
    }
}

/// The web's MentionPicker: a raised list above the composer, each person with their face,
/// name and `@user_id`, and each role with a group glyph on denim-soft, `@role` and how many
/// people it mentions.
struct MentionPicker: View {
    let session: ServerSession
    let items: [MentionSuggestion]
    let rows: SuggestionRows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                Button { rows.pick(index) } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        switch item {
                        case .person(let person):
                            let name = session.displayName(for: person)
                            Avatar(name: name, userID: person.userID, presence: session.presence(of: person.userID), size: .sm,
                                   image: session.avatarURL(of: person.userID))
                            Text(name).apText(.field, .semibold).foregroundStyle(Palette.ink)
                            Text("@" + person.userID).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
                        case .role(let role):
                            Image(systemName: "person.2.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Palette.denim)
                                .frame(width: Tokens.AvatarSize.sm, height: Tokens.AvatarSize.sm)
                                .background(Palette.denimSoft, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                            Text("@" + role.role).apText(.field, .semibold).foregroundStyle(Palette.ink)
                            Text(Self.reach(role)).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Tokens.Space.s2)
                    .frame(minHeight: Tokens.Size.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .suggestionRow(index, of: rows)
                .accessibilityLabel(label(item))
            }
        }
        .padding(Tokens.Space.s1)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
    }

    /// "1 person" or "3 people", as the web's picker row.
    static func reach(_ role: RoleSuggestion) -> String {
        role.members.count == 1 ? "1 person" : "\(role.members.count) people"
    }

    private func label(_ item: MentionSuggestion) -> String {
        switch item {
        case .person(let person): "Mention \(session.displayName(for: person))"
        case .role(let role): "Mention everyone with the role \(role.role), \(Self.reach(role))"
        }
    }
}

/// The command list above the composer, styled as the mention and `:` lists: each command's usage
/// and what it does, scrolling past five rows.
struct CommandSuggestions: View {
    let commands: [ServerCommand]
    let rows: SuggestionRows
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.name) { index, command in
                        Button { rows.pick(index) } label: {
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
                        .suggestionRow(index, of: rows)
                        .id(index)
                        .accessibilityLabel(command.usage)
                        .accessibilityHint(command.summary)
                    }
                }
                .padding(Tokens.Space.s1)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .onChange(of: rows.highlighted) { scroller.scrollTo(rows.highlighted) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(height, Tokens.Size.touchTarget * 5.5))
        .frame(maxWidth: 480, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
    }
}

/// What every list above the composer shares, as the web's AutocompletePicker: the highlighted
/// row (`SuggestionCursor`) on the hover ground, with a Tab key on it where a hardware keyboard
/// is likely (regular width); the pointer over a row highlights it; a tap or a key picks one.
struct SuggestionRows {
    let highlighted: Int
    let showsKey: Bool
    let hover: (Int) -> Void
    let pick: (Int) -> Void
}

extension View {
    func suggestionRow(_ index: Int, of rows: SuggestionRows) -> some View {
        let active = index == rows.highlighted
        return self
            .overlay(alignment: .trailing) {
                if active, rows.showsKey {
                    Text("Tab")
                        .apText(.xs)
                        .foregroundStyle(Palette.inkMuted)
                        .padding(.horizontal, Tokens.Space.s1)
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Palette.lineStrong))
                        .padding(.trailing, Tokens.Space.s2)
                        .accessibilityHidden(true)
                }
            }
            .background(active ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .onHover { if $0 { rows.hover(index) } }
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}
