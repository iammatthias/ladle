import ApronKit
import SwiftUI

/// A room's messages, oldest first, paging back as the top comes into view. The web's timeline:
/// day pills, the New line in denim, thread cards where each thread began, room notices as
/// callouts, and queued messages at the end. Problems show inline, never as alerts. A link's
/// `place` in this room scrolls to its message and highlights it, or shows its member.
struct TimelineView: View {
    let session: ServerSession
    let roomID: String
    @Binding var place: ApronLink?
    @State private var focus: ApronLink?
    @State private var highlighted: LogID?
    @State private var draft: Draft
    @State private var problem: String?
    @State private var reacting: MessageSnapshot?
    @State private var deleting: MessageSnapshot?
    @State private var leaving = false
    @State private var showingMembers = false
    @State private var atBottom = true
    @State private var visit = Visit.opening
    @State private var visible = false
    @State private var jumpTarget: String?
    @State private var sentCount = 0
    @State private var viewing: MediaRequest?
    @State private var selecting: SelectableBody?
    @State private var remindingAt: CustomReminder?
    @State private var reminding: MessageReminders
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openRoom) private var openRoom
    @Environment(\.requestSignIn) private var requestSignIn
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(session: ServerSession, roomID: String, reminders: Reminders, place: Binding<ApronLink?> = .constant(nil), draft: Draft = Draft(),
         showingMembers: Bool = false) {
        self.session = session
        self.roomID = roomID
        _place = place
        _reminding = State(initialValue: MessageReminders(session: session, reminders: reminders))
        _draft = State(initialValue: draft)
        _showingMembers = State(initialValue: showingMembers)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.canLoadOlder(roomID) {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchTarget)
                            .task(id: session.histories[roomID]?.olderBefore) {
                                do { try await session.loadOlder(roomID) } catch { problem = errorText(error) }
                            }
                    }
                    ForEach(session.timelineItems(roomID, lineBefore: session.newLine(in: roomID, after: visit.after))) { item in
                        row(item).id(item.id)
                    }
                    ForEach(Array(session.notices.enumerated()).filter { $0.element.roomID == roomID }, id: \.offset) { _, notice in
                        let menu = NoticeMenu(notice, in: session)
                        Callout(title: menu.title) { Text(styled(MessageText.attributed(notice.body, rooms: session.referencedTitle))).tint(Palette.denim) }
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Tokens.Radius.md))
                            .contextMenu { noticeActions(menu) }
                            .accessibilityActions { noticeActions(menu) }
                            .padding(.horizontal, Tokens.Space.s4)
                            .padding(.top, Tokens.Space.s3)
                    }
                    Color.clear.frame(height: Tokens.Space.s3).id("bottom")
                }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 80
            } action: { _, bottom in
                atBottom = bottom
            }
            .onChange(of: jumpTarget) {
                guard let jumpTarget else { return }
                withAnimation(Motion.slide(reduceMotion)) { proxy.scrollTo(jumpTarget, anchor: .center) }
                self.jumpTarget = nil
            }
            .overlay(alignment: .bottom) {
                if !atBottom, session.unreadCount(in: roomID) > 0 {
                    JumpBar(count: session.unreadCount(in: roomID), mentions: session.mentionCount(in: roomID)) {
                        withAnimation(Motion.slide(reduceMotion)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .padding(.bottom, Tokens.Space.s2)
                    .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Group {
                    if !session.mayWrite {
                        ReadOnlyPrompt(session: session) { requestSignIn(session.record) }
                    } else {
                        ComposerView(session: session, roomID: roomID, draft: $draft, onSend: send, onProblem: { problem = $0 })
                    }
                }
                .background(Palette.timeline)
            }
        }
        .background(Palette.timeline)
        .environment(\.openMedia, OpenMediaAction { viewing = MediaRequest(id: $0) })
        .fullScreenCover(item: $viewing) { request in
            MediaViewer(items: session.mediaItems(in: roomID), selection: request.id)
        }
        .dropDestination(for: ImportedFile.self) { files, _ in
            guard session.canAttach, !draft.field.isEdit else { return false }
            dropped(files)
            return true
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
        .navigationTitle(session.title(of: roomID))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $selecting) { selected in
            SelectTextSheet(text: selected.text) { selecting = nil }
        }
        .sheet(item: $remindingAt) { pending in
            ReminderDateSheet(date: Binding(get: { remindingAt?.date ?? pending.date }, set: { remindingAt?.date = $0 }),
                              set: {
                                  reminding.remind(pending.message, at: remindingAt?.date ?? pending.date)
                                  remindingAt = nil
                              },
                              cancel: { remindingAt = nil })
        }
        .sheet(item: $reacting) { message in
            ReactionPicker(session: session) { emoji in
                reacting = nil
                perform { try await session.toggleReaction(emoji, on: message.messageID) }
            }
        }
        .modifier(MembersPresentation(session: session, roomID: roomID, showing: $showingMembers, compact: sizeClass == .compact))
        .confirmationDialog("Delete this message?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { message in
            Button("Delete Message", role: .destructive) { perform { try await session.delete(message) } }
        } message: { _ in
            Text("It is removed for everyone in the room.")
        }
        .confirmationDialog("Leave \(session.title(of: roomID))?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { perform { try await session.leave(roomID) } }
        } message: {
            Text(session.isPrivate(roomID) ? "It is private, so you need an invitation to come back." : "You can join it again from Browse Rooms.")
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: ReadMark(reading: isReading, through: session.timeline(roomID).last?.messageID), initial: true) { _, mark in
            guard mark.reading, let through = mark.through else { return }
            Task { await session.markRead(roomID, through: through) }
        }
        .task(id: session.status) {
            guard session.status == .signedIn else { return }
            do { try await session.open(roomID) } catch {
                problem = errorText(error)
                return
            }
            if visit == .opening { visit = .landed(after: session.readThrough(roomID)) }
        }
        .onChange(of: place, initial: true) { _, link in
            guard let link, link.room == roomID else { return }
            focus = link
            place = nil
        }
        .task(id: Focus(link: focus, signedIn: session.status == .signedIn)) {
            guard let link = focus, session.status == .signedIn else { return }
            await show(link)
            if !Task.isCancelled { focus = nil }
        }
    }

    /// A link's place in this room: its member list for `user`, and for `message` the history
    /// back to it, a scroll there and a brief highlight, or a notice when the room lacks it.
    private func show(_ link: ApronLink) async {
        if link.user != nil { showingMembers = true }
        guard let message = link.message else { return }
        let shown: Bool
        do { shown = try await session.reveal(message, in: roomID) } catch {
            if !Task.isCancelled { problem = errorText(error) }
            return
        }
        guard shown else {
            problem = "That message isn't in this room."
            return
        }
        highlighted = message
        try? await Task.sleep(for: .milliseconds(100))
        jumpTarget = message.text
        try? await Task.sleep(for: .seconds(2))
        withAnimation(Motion.medium(reduceMotion)) { highlighted = nil }
    }

    private var isReading: Bool {
        visible && scenePhase == .active && atBottom && visit.isLanded && session.status == .signedIn
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: Tokens.Space.s1) {
                if session.isPrivate(roomID) { Lock() }
                Text(session.title(of: roomID)).font(.headline).foregroundStyle(Palette.ink).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Members", systemImage: "person.2") { showingMembers.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            if session.status == .signedIn, session.server?.has("rooms") == true {
                Menu("Room", systemImage: "ellipsis") {
                    if session.joinedRoomIDs.contains(roomID) {
                        Button("Leave Room", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { leaving = true }
                    } else {
                        Button("Join Room", systemImage: "plus.circle") { perform { try await session.join(roomID) } }
                    }
                }
            }
        }
    }

    /// Connection state (UX spec 4.1) and the last failure, under the navigation bar.
    @ViewBuilder
    private var banner: some View {
        let state = ConnectionState(session.status)
        VStack(spacing: Tokens.Space.s2) {
            if let message = session.unavailableMessage {
                Callout(title: session.serverName) { Text(message) }
            }
            if let state, state.isProblem {
                ActionBanner(symbol: state.symbol, title: state.title(session.record), detail: state.detail) {
                    if state.canRetry { Button("Try Now") { session.start() }.buttonStyle(GhostButtonStyle(tone: Palette.accent)) }
                }
            } else if let state {
                Label(state.title(session.record), systemImage: state.symbol)
                    .apText(.sm, .medium)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, Tokens.Space.s3)
                    .padding(.vertical, 3)
                    .background(Palette.raised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.line))
            }
            if reminding.notificationsOff {
                ActionBanner(symbol: "bell.slash", title: "Notifications are off for Ladle",
                             detail: "Your reminder shows on its message, but no alert will come. Turn on notifications for Ladle in Settings.") {
                    Button("Settings") {
                        reminding.notificationsOff = false
                        URL(string: UIApplication.openNotificationSettingsURLString).map { openURL($0) }
                    }
                    .buttonStyle(GhostButtonStyle(tone: Palette.accent))
                    Button("Dismiss", systemImage: "xmark") { reminding.notificationsOff = false }
                        .labelStyle(.iconOnly).buttonStyle(GhostButtonStyle())
                }
            }
            if let problem {
                ActionBanner(symbol: "exclamationmark.triangle", title: problem, tone: Palette.danger) {
                    Button("Dismiss", systemImage: "xmark") { self.problem = nil }
                        .labelStyle(.iconOnly).buttonStyle(GhostButtonStyle())
                }
                .task(id: problem) {
                    try? await Task.sleep(for: .seconds(6))
                    self.problem = nil
                }
            }
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.top, state == nil && problem == nil && !reminding.notificationsOff && session.unavailableMessage == nil ? 0 : Tokens.Space.s2)
    }

    @ViewBuilder
    private func row(_ item: TimelineItem) -> some View {
        switch item {
        case .message(let message, let continues):
            MessageRow(session: session, message: message, continues: continues, highlighted: highlighted == message.messageID,
                       reminderDue: reminding.reminder(on: message)?.due,
                       onClearReminder: { reminding.forget(message) },
                       onReact: { emoji in perform { try await session.toggleReaction(emoji, on: message.messageID) } },
                       onAddReaction: { reacting = message },
                       onJump: { jumpTarget = $0.text })
                .padding(.horizontal, Tokens.Space.s2)
                .padding(.top, continues ? 0 : Tokens.Space.s3)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .contextMenu { actions(for: message) }
                .accessibilityActions { actions(for: message) }
        case .day(let date):
            TimelineDivider(kind: .day, label: dayLabel(date))
                .padding(.top, Tokens.Space.s6)
                .padding(.bottom, Tokens.Space.s2)
        case .unreadLine:
            TimelineDivider(kind: .new, label: "New")
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.top, Tokens.Space.s6)
                .padding(.bottom, Tokens.Space.s2)
        case .thread(let threadID):
            Button { openRoom(threadID) } label: { ThreadCard(session: session, threadID: threadID) }
                .buttonStyle(.plain)
                .padding(.leading, Tokens.Space.s4 + Tokens.AvatarSize.md + Tokens.Space.s3)
                .padding(.trailing, Tokens.Space.s4)
                .padding(.top, Tokens.Space.s2)
        case .pending(let pending):
            PendingRow(session: session, pending: pending)
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.top, Tokens.Space.s3)
        }
    }

    @ViewBuilder
    private func actions(for message: MessageSnapshot) -> some View {
        let menu = MessageMenu(message, in: session)
        Section {
            if menu.reacts {
                ControlGroup {
                    ForEach(ReactionPicker.quick.prefix(4), id: \.self) { emoji in
                        Button(emoji) { perform { try await session.toggleReaction(emoji, on: message.messageID) } }
                    }
                    Button("More Reactions", systemImage: "face.smiling") { reacting = message }
                }
                .controlGroupStyle(.compactMenu)
            }
            Button("Reply", systemImage: "arrowshape.turn.up.left") { draft = Draft(field: DraftField(mode: .reply(message)), attachments: draft.attachments) }
        } header: {
            if !menu.mayWrite { Text(ReadOnlyPrompt.reason(session)) }
        }
        .disabled(!menu.mayWrite)
        Button("Copy Text", systemImage: "doc.on.doc") { UIPasteboard.general.string = menu.text }
        if let text = menu.selectableText {
            Button("Select Text", systemImage: "selection.pin.in.out") { selecting = SelectableBody(text: text) }
        }
        if let link = menu.link {
            Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = link }
        }
        if !menu.moveDestinations.isEmpty {
            Menu("Move To", systemImage: "arrow.right.square") {
                ForEach(menu.moveDestinations, id: \.self) { roomID in
                    Button(session.title(of: roomID)) { perform { try await session.move(message, to: roomID) } }
                }
            }
        }
        remindMenu(message)
        linkActions(menu.links)
        if menu.editable {
            Button("Edit", systemImage: "pencil") { draft = Draft(field: DraftField(editing: message, in: session)) }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = message }
        }
    }

    /// Remind Me: a time from now, tomorrow morning, or one picked; and the reminder's removal.
    @ViewBuilder
    private func remindMenu(_ message: MessageSnapshot) -> some View {
        Menu("Remind Me", systemImage: "alarm") {
            ForEach(ReminderChoice.allCases, id: \.self) { choice in
                Button(choice.title) { reminding.remind(message, at: choice.due(after: .now, calendar: .current)) }
            }
            Button("Custom…", systemImage: "calendar") {
                remindingAt = CustomReminder(message: message, date: MessageReminders.customStart(after: .now))
            }
            if reminding.reminder(on: message) != nil {
                Button("Remove Reminder", systemImage: "bell.slash") { reminding.forget(message) }
            }
        }
    }

    /// Open, Copy Link and Share for each of a body's first three links.
    @ViewBuilder
    private func linkActions(_ links: [MenuLink]) -> some View {
        ForEach(links, id: \.self) { link in
            Menu(link.title, systemImage: "link") {
                Button("Open Link", systemImage: "arrow.up.right.square") { openURL(link.url) }
                Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = link.shared }
                ShareLink(item: link.shared)
            }
        }
    }

    /// A notice's menu (`NoticeMenu`): its text, each code span on its own, and its links.
    @ViewBuilder
    private func noticeActions(_ menu: NoticeMenu) -> some View {
        Button("Copy Text", systemImage: "doc.on.doc") { UIPasteboard.general.string = menu.text }
        Button("Select Text", systemImage: "selection.pin.in.out") { selecting = SelectableBody(text: menu.text) }
        ForEach(menu.code, id: \.self) { code in
            Button { UIPasteboard.general.string = code } label: {
                Label { Text("Copy \(Text(code).monospaced())").lineLimit(1) } icon: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
            }
        }
        linkActions(menu.links)
    }

    /// Files dropped on the conversation join the draft, as the web's DropZone does.
    private func dropped(_ files: [ImportedFile]) {
        let limits = session.mediaLimits?.upload
        for file in files {
            let item = DraftAttachment(name: file.url.lastPathComponent, phase: .preparing)
            draft.attachments.append(item)
            Task {
                do {
                    let attachment = try await AttachmentStaging.prepare(file.url, name: item.name, contentType: nil, limits: limits)
                    if let index = draft.attachments.firstIndex(where: { $0.id == item.id }) { draft.attachments[index].phase = .ready(attachment) }
                } catch {
                    draft.attachments.removeAll { $0.id == item.id }
                    problem = "\(item.name): \(errorText(error))"
                }
            }
        }
    }

    private func send(_ field: DraftField, attachments: [Attachment]) {
        draft = Draft()
        sentCount += 1
        perform { try await session.submit(field, in: roomID, attachments: attachments) }
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() } catch { problem = errorText(error) }
        }
    }
}

/// What the composer is writing (`DraftField`), and the files staged to go with it (§4.8.4).
struct Draft {
    var field = DraftField()
    var attachments: [DraftAttachment] = []
}

/// One look at a room, as the web's `newDivider`: where you had read when it opened fixes the New
/// line for the visit.
enum Visit: Equatable {
    case opening
    case landed(after: LogID?)

    var after: LogID? {
        if case .landed(let after) = self { return after }
        return nil
    }

    var isLanded: Bool {
        if case .landed = self { return true }
        return false
    }
}

struct Focus: Equatable {
    var link: ApronLink?
    var signedIn: Bool
}

struct ReadMark: Equatable {
    var reading: Bool
    var through: LogID?
}

/// The text Select Text shows (`MessageMenu.selectableText`, `NoticeMenu.text`).
struct SelectableBody: Identifiable {
    let id = UUID()
    let text: String
}

/// Remind Me's Custom…: the message, and the time being picked.
struct CustomReminder: Identifiable {
    let id = UUID()
    let message: MessageSnapshot
    var date: Date
}

/// Which media the viewer opens at.
struct MediaRequest: Identifiable {
    let id: String
}

extension MessageSnapshot: @retroactive Identifiable {
    public var id: String { messageID.text }
}

/// The member list: a sheet on iPhone, as the web's overlay under 960 px; the inspector column
/// on iPad, as the web's own column at 960 px and wider. Only one is attached, so the
/// inspector's toolbar never lands in an iPhone navigation bar.
private struct MembersPresentation: ViewModifier {
    let session: ServerSession
    let roomID: String
    @Binding var showing: Bool
    let compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content.sheet(isPresented: $showing) {
                NavigationStack { MemberList(session: session, roomID: roomID) }
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Palette.chrome)
            }
        } else {
            content.inspector(isPresented: $showing) {
                MemberList(session: session, roomID: roomID).inspectorColumnWidth(Tokens.Size.memberListW)
            }
        }
    }
}

/// The web's JumpBar: new messages below, and the way back to them.
struct JumpBar: View {
    let count: Int
    let mentions: Int
    let jump: () -> Void

    var body: some View {
        Button(action: jump) {
            HStack(spacing: Tokens.Space.s3) {
                Text(mentions > 0 ? "\(count) new, \(mentions) mention\(mentions == 1 ? "" : "s") of you" : "\(count) new message\(count == 1 ? "" : "s")")
                    .foregroundStyle(Palette.inkMuted)
                Text("Jump").fontWeight(.semibold).foregroundStyle(Palette.denim)
            }
            .apText(.ui)
            .padding(.leading, Tokens.Space.s3)
            .padding(.trailing, Tokens.Space.s3)
            .frame(minHeight: Tokens.Control.md + Tokens.Space.s2)
            .background(Palette.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(mentions > 0 ? Palette.accent : Palette.line))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .touchTarget()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Scrolls to the newest messages")
    }
}

/// The web's ThreadMarker: a denim card at the point the thread began, with who is in it, its
/// unread count and last time, its description and its latest line.
struct ThreadCard: View {
    let session: ServerSession
    let threadID: String

    var body: some View {
        let messages = session.timeline(threadID)
        let last = messages.last
        let unread = session.unreadCount(in: threadID)
        let faces = Array(NSOrderedSet(array: messages.reversed().map(\.from.userID)).array.compactMap { $0 as? String }.prefix(3))
        let ground = session.isPrivate(threadID) ? Palette.privateSoft : Palette.denimSoft
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            HStack(spacing: Tokens.Space.s2) {
                HStack(spacing: -6) {
                    ForEach(faces, id: \.self) { id in
                        let name = session.users.user(id).flatMap(UserObject.init).map(session.displayName(for:)) ?? id
                        Avatar(name: name, userID: id, size: .sm, image: session.avatarURL(of: id)).overlay(Circle().stroke(ground, lineWidth: 2))
                    }
                }
                if session.isPrivate(threadID) { Lock(tint: Palette.private) }
                Text(session.title(of: threadID)).fontWeight(.semibold)
                    .foregroundStyle(session.isPrivate(threadID) ? Palette.private : Palette.denim)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Space.s2)
                if unread > 0 { UnreadCount(count: unread) }
                if let last {
                    Text(last.date, format: .dateTime.hour().minute()).apText(.sm).monospacedDigit().foregroundStyle(Palette.inkMuted)
                }
            }
            if let description = session.roomDescription(threadID) {
                Label { EmojiText(text: descriptionText(description, session.emojiCatalog), catalog: session.emojiCatalog, role: .ui).lineLimit(1) } icon: { Image(systemName: "text.alignleft").foregroundStyle(Palette.inkMuted) }
                    .foregroundStyle(Palette.ink)
            }
            if let last {
                Label {
                    Text("\(Text(TextDirection.isolated(session.displayName(for: last.from))).fontWeight(.semibold)) \(Text(previewText(last.body)))").lineLimit(1)
                } icon: {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(Palette.inkMuted)
                }
                .foregroundStyle(Palette.ink)
            }
        }
        .apText(.ui)
        .labelStyle(TightLabel())
        .task(id: session.server?.emojiCatalogURL) { await session.loadEmojiCatalog(for: session.roomDescription(threadID)) }
        .padding(.top, Tokens.Space.s1)
        .padding(.bottom, Tokens.Space.s1_5)
        .padding(.horizontal, Tokens.Space.s3)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(minHeight: Tokens.Size.touchTarget)
        .background(ground, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thread \(session.title(of: threadID))" + (unread > 0 ? ", \(unread) new" : ""))
        .accessibilityHint("Opens the thread")
    }
}

/// A label whose icon sits close, as the web's thread lines.
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A queued message: dimmed with "Sending…", or "Not sent" with Retry and Delete (UX spec 4.2).
struct PendingRow: View {
    let session: ServerSession
    let pending: ServerSession.PendingMessage

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            if let you = session.you {
                Avatar(name: session.displayName(for: you), userID: you.userID, image: session.avatarURL(of: you.userID)).padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                if !pending.text.isEmpty {
                    Text(pending.text).apText(.body).foregroundStyle(Palette.ink)
                }
                ForEach(pending.attachments) { attachment in
                    Label(attachment.title, systemImage: attachment.isImage ? "photo" : attachment.isVideo ? "film" : attachment.isAudio ? "waveform" : "doc")
                        .apText(.ui, .semibold).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                }
                switch pending.state {
                case .sending:
                    Label("Sending…", systemImage: "clock").apText(.sm).foregroundStyle(Palette.inkMuted)
                case .failed(let reason):
                    Label("Not sent. \(reason)", systemImage: "exclamationmark.circle").apText(.sm).foregroundStyle(Palette.danger)
                    HStack(spacing: Tokens.Space.s2) {
                        Button("Retry") { session.retry(pending.id) }.buttonStyle(GhostButtonStyle(tone: Palette.accent))
                        Button("Delete", role: .destructive) { session.discard(pending.id) }.buttonStyle(GhostButtonStyle(tone: Palette.danger))
                    }
                }
            }
        }
        .opacity(pending.state == .sending ? Tokens.Opacity.dim : 1)
        .accessibilityElement(children: .contain)
    }
}

extension EnvironmentValues {
    /// Opens a room or thread in the current navigation, from a thread card or a link.
    @Entry var openRoom = OpenRoomAction { _ in }
    /// Opens the sign-in sheet for a saved server.
    @Entry var requestSignIn = SignInAction { _ in }
    /// The signed-in session of another saved server, for a link card naming a place on it.
    @Entry var liveSessions = SessionLookup { _ in nil }
}

/// Finds a saved server's signed-in session by its URL; a struct, as `OpenRoomAction`.
struct SessionLookup {
    let find: (URL) -> ServerSession?
    init(_ find: @escaping (URL) -> ServerSession?) { self.find = find }
}

/// Opens the sign-in sheet for a server; a struct, as `OpenRoomAction`.
struct SignInAction {
    let open: (ServerRecord) -> Void
    init(_ open: @escaping (ServerRecord) -> Void) { self.open = open }
    func callAsFunction(_ record: ServerRecord) { open(record) }
}

/// In place of the composer for a user who may not write (`ServerSession.mayWrite`): why, and the
/// sign-in sheet for this server, which also creates accounts.
struct ReadOnlyPrompt: View {
    static func reason(_ session: ServerSession) -> String {
        "\(session.isGuest ? "Guests" : "You") can read here but not post, react, reply or start threads."
    }

    let session: ServerSession
    let signIn: () -> Void

    var body: some View {
        ActionBanner(symbol: "person.crop.circle.badge.plus", title: "Sign in to join the conversation",
                     detail: "\(Self.reason(session)) Sign in or create an account on \(session.serverName).") {
            Button("Sign In", action: signIn).buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s2)
    }
}

/// Opens a room by id; a struct so the environment can tell it apart from a new closure.
struct OpenRoomAction {
    let open: (String) -> Void
    init(_ open: @escaping (String) -> Void) { self.open = open }
    func callAsFunction(_ roomID: String) { open(roomID) }
}
