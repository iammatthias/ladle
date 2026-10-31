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
    /// Every room's kept draft; this room's is the composer's unless an edit is open.
    let drafts: Drafts
    /// The descriptions put away with their ×.
    let hidden: HiddenDescriptions
    /// Copy Link copied: "Link copied" under the title for two seconds.
    @State private var copied = false
    @State private var descriptionOpen = false
    @State private var editingRoom = false
    /// An open edit, which sits beside the kept draft and is never kept, as apron-web's editor.
    @State private var editing: ComposerDraft?
    @State private var problem: String?
    @State private var reacting: MessageSnapshot?
    @State private var deleting: MessageSnapshot?
    @State private var leaving = false
    /// The ends of the long waits put away, which show again on the next Send.
    @State private var dismissedWaits: Set<Date> = []
    @State private var showingMembers = false
    @State private var searchingHistory = false
    @State private var atBottom = true
    @State private var visit = Visit.opening
    @State private var visible = false
    @State private var jumpTarget: String?
    @State private var sentCount = 0
    @State private var viewing: MediaRequest?
    @State private var selecting: SelectableBody?
    @State private var remindingAt: CustomReminder?
    @State private var profile: ProfileRequest?
    /// Start Thread's form, suggested from its message.
    @State private var startingThread: ThreadRequest?
    /// The thread Start Thread made, opened once its form has gone.
    @State private var startedThread: String?
    @State private var reminding: MessageReminders
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openRoom) private var openRoom
    @Environment(\.requestSignIn) private var requestSignIn
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(session: ServerSession, roomID: String, reminders: Reminders, hidden: HiddenDescriptions, drafts: Drafts,
         place: Binding<ApronLink?> = .constant(nil), showingMembers: Bool = false) {
        self.session = session
        self.roomID = roomID
        self.drafts = drafts
        self.hidden = hidden
        _place = place
        _reminding = State(initialValue: MessageReminders(session: session, reminders: reminders))
        _showingMembers = State(initialValue: showingMembers)
    }

    private var draftKey: DraftKey { DraftKey(server: session.record.id, roomID: roomID) }

    /// The room's or thread's description, pinned under the header until its × puts it away, and
    /// again once it is edited, as apron-web's.
    private var pinnedDescription: String? {
        session.roomDescription(roomID).flatMap { hidden.isHidden(draftKey, description: $0) ? nil : $0 }
    }

    private var descriptionPutAway: Bool {
        session.roomDescription(roomID).map { hidden.isHidden(draftKey, description: $0) } ?? false
    }

    /// What the composer writes: the open edit, else this room's kept draft. Ending the edit (a
    /// draft that is no longer one) brings the kept draft back.
    private var draft: Binding<ComposerDraft> {
        Binding(get: { editing ?? drafts[draftKey] }, set: { value in
            if editing != nil { editing = value.field.isEdit ? value : nil } else { drafts[draftKey] = value }
        })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let intro = session.privateIntro(roomID) { PrivateIntroCard(session: session, intro: intro) }
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
                        Callout(title: menu.title) {
                            MessageBlocksView(blocks: MessageText.blocks(notice.body, rooms: session.referencedTitle), catalog: nil, role: .ui,
                                              gate: session.mediaGate, settings: session.mediaSettings)
                                .tint(Palette.denim)
                        }
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
                VStack(spacing: 0) {
                    // Wider, it is a line above the composer, as the web's TypingIndicator.
                    if sizeClass != .compact, session.server?.has("activity") == true {
                        TypingIndicator(names: session.typingNames(in: roomID))
                    }
                    if !session.mayWrite {
                        ReadOnlyPrompt(session: session) { requestSignIn(session.record) }
                    } else {
                        waits
                        ComposerView(session: session, roomID: roomID, draft: draft, staging: drafts.staging, onSend: send,
                                     onHeld: { dismissedWaits = [] }, onProblem: { problem = $0 })
                    }
                }
                .background(Palette.timeline)
            }
        }
        .background(Palette.timeline)
        .environment(\.openURL, OpenURLAction { url in
            if let user = Self.mentionedUser(url) {
                showProfile(user)
            } else {
                openURL(url)
            }
            return .handled
        })
        .environment(\.openMedia, OpenMediaAction { viewing = MediaRequest(id: $0) })
        .fullScreenCover(item: $viewing) { request in
            MediaViewer(items: session.mediaItems(in: roomID), selection: request.id)
        }
        .dropDestination(for: ImportedFile.self) { files, _ in
            guard session.canAttach, editing == nil else { return false }
            dropped(files)
            return true
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
        .navigationTitle(session.title(of: roomID))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // A private room's header takes the plum wash, as the web's.
        .toolbarBackground(session.isPrivate(roomID) ? Palette.privateWash(0.6) : Palette.timeline, for: .navigationBar)
        .toolbarBackgroundVisibility(session.isPrivate(roomID) ? .visible : .automatic, for: .navigationBar)
        .sheet(isPresented: $searchingHistory) {
            SearchView(session: session, initial: ServerSession.searchStart(in: roomID))
        }
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
        .sheet(item: $startingThread, onDismiss: {
            if let startedThread { openRoom(startedThread) }
            startedThread = nil
        }) { request in
            RoomFormSheet(kind: .thread, mode: .create, subtitle: "In \(session.title(of: roomID))", isPrivate: session.isPrivate(roomID),
                          title: request.title, description: request.description) { title, description in
                guard let thread = try await session.startThread(from: request.message, title: title, description: description) else { return }
                // The link back is its first reply: the thread opens replying to the message.
                drafts[DraftKey(server: session.record.id, roomID: thread)].field.mode = .reply(request.message.messageID)
                startedThread = thread
                // A thread of a private room is private too: the room's other members are added, so they see it.
                Task { if let note = await session.includeMembers(of: roomID, in: thread) { problem = note } }
            }
        }
        .sheet(isPresented: $editingRoom) {
            RoomFormSheet(kind: session.store.room(roomID)?.parentRoomID == nil ? .room : .thread, mode: .edit,
                          title: session.editableTitle(of: roomID), description: session.roomDescription(roomID) ?? "") { title, description in
                // Unchanged, it only closes, as the web's editor.
                guard title != session.editableTitle(of: roomID).trimmingCharacters(in: .whitespacesAndNewlines)
                    || description != (session.roomDescription(roomID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                try await session.editRoom(roomID, title: title, description: description)
            }
        }
        .sheet(item: $profile) { request in
            ProfileCardView(session: session, request: request) { id, name in draft.wrappedValue.field.mention(id, named: name) }
        }
        .sheet(item: $reacting) { message in
            ReactionPicker(session: session) { emoji in
                reacting = nil
                perform { try await session.toggleReaction(emoji, on: message.messageID) }
            }
        }
        .modifier(MembersPresentation(session: session, roomID: roomID, showing: $showingMembers, compact: sizeClass == .compact) { id, name in
            if sizeClass == .compact { showingMembers = false }
            draft.wrappedValue.field.mention(id, named: name)
        })
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
        .onAppear {
            visible = true
            session.show(roomID, true)
        }
        .onDisappear {
            visible = false
            session.show(roomID, false)
        }
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

    /// A link's place in this room: the profile card for `user`, as apron-web's
    /// `revealLinkedUser`, and for `message` the history back to it, a scroll there and a brief
    /// highlight, or a notice when the room lacks it.
    private func show(_ link: ApronLink) async {
        if let user = link.user { showProfile(user) }
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

    /// A mention chip's link (`ApronLink.relative(user:)`): a user and nothing else.
    private static func mentionedUser(_ url: URL) -> String? {
        guard let link = ApronLink(url), link.server == nil, link.room == nil else { return nil }
        return link.user
    }

    private func showProfile(_ userID: String) {
        let user = session.users.user(userID).flatMap(UserObject.init) ?? UserObject(["user_id": .string(userID)])
        profile = user.map { ProfileRequest(user: $0, roomID: roomID) }
    }

    private var isReading: Bool {
        visible && scenePhase == .active && atBottom && visit.isLanded && session.status == .signedIn
    }

    /// Waits the server asked for on sending and on uploads, above the composer they hold back.
    @ViewBuilder
    private var waits: some View {
        let shown = [(LimitScope.message, session.sendWait), (.upload, session.wait(.upload))]
            .compactMap { scope, wait in wait.flatMap { dismissedWaits.contains($0.until) ? nil : (scope, $0) } }
        if !shown.isEmpty {
            VStack(spacing: Tokens.Space.s1) {
                ForEach(shown, id: \.0) { scope, wait in
                    RateLimitNotice(scope: scope, wait: wait) { dismissedWaits.insert(wait.until) }
                }
            }
            .padding(.horizontal, Tokens.Space.s3)
            .padding(.top, Tokens.Space.s2)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: Tokens.Space.s1) {
                // An untitled private room says who it is with before its name, as the web's RoomHeader.
                if session.isNamedForMembers(roomID) { Faces(session: session, people: session.faces(of: roomID)) }
                if session.isPrivate(roomID) { Lock(tint: Palette.private) }
                Text(session.title(of: roomID)).font(.headline).foregroundStyle(Palette.ink).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // Muted: a bell-off left of the ⋯ menu says so and unmutes, as the web's RoomHeader.
            if session.mayMute, let mute = session.mute(of: roomID) {
                Button {
                    let target = if case .withRoom(let parent, _) = mute { parent } else { roomID }
                    perform { try await session.setMute(target, nil) }
                } label: {
                    Label("Unmute", systemImage: "bell.slash")
                }
                .accessibilityLabel(mute.isWithRoom ? "Muted with its room, \(session.muteWords(mute))" : "Muted, \(session.muteWords(mute))")
                .accessibilityHint(mute.isWithRoom ? "Unmutes the room" : "Unmutes it")
            }
            // Beside the title, as apron-web #166 put it there, and ⌘F, as its Ctrl or ⌘F.
            Button("Search Local History", systemImage: "magnifyingglass") { searchingHistory = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("Members", systemImage: "person.2") { showingMembers.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            if session.status == .signedIn, session.server?.has("rooms") == true || session.mayMute {
                Menu("Room", systemImage: "ellipsis") {
                    let noun = session.store.room(roomID)?.parentRoomID == nil ? "Room" : "Thread"
                    if let link = session.link(to: roomID) {
                        Button("Copy Link to \(noun)", systemImage: "link") { copyLink(link) }
                    }
                    if descriptionPutAway {
                        Button("Show Description", systemImage: "text.alignleft") { hidden.show(draftKey) }
                    }
                    MuteActions(session: session, roomID: roomID, perform: perform)
                    if session.mayEdit(roomID) {
                        Button("Edit \(noun)", systemImage: "pencil") { editingRoom = true }
                    }
                    if session.server?.has("rooms") == true {
                        if session.joinedRoomIDs.contains(roomID) {
                            Button("Leave Room", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { leaving = true }
                        } else {
                            Button("Join Room", systemImage: "plus.circle") { perform { try await session.join(roomID) } }
                        }
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
            // The header's subtitle, as the web's RoomHeader, as a line under the bar so the centered
            // title never moves: on a phone who is typing, in denim; a thread's replies; or a room's
            // description's first line once its pinned description is put away.
            let typing = sizeClass == .compact ? TypingLine.subtitle(session.typingNames(in: roomID)) : nil
            if let line = session.headerLine(roomID, typing: typing, copied: copied, descriptionPutAway: descriptionPutAway) {
                Group {
                    if case .topic(let topic) = line {
                        EmojiText(text: descriptionText(topic, session.emojiCatalog), catalog: session.emojiCatalog, role: .sm)
                    } else {
                        Text(line.text)
                    }
                }
                    .apText(.sm)
                    .foregroundStyle(line == .copied || typing != nil ? Palette.denim : Palette.inkMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.Space.s1)
                    .background(Palette.timeline)
                    .accessibilityAddTraits(typing != nil ? .updatesFrequently : [])
            }
            if session.wasAdded(to: roomID) {
                AddedBanner(session: session, roomID: roomID, leave: { leaving = true }, problem: { problem = $0 })
            }
            if let description = pinnedDescription {
                PinnedDescription(text: description, thread: session.store.room(roomID)?.parentRoomID != nil, session: session,
                                  open: $descriptionOpen) {
                    hidden.hide(draftKey, description: description)
                    descriptionOpen = false
                }
            }
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
                       onJump: { jumpTarget = $0.text },
                       onProfile: { profile = ProfileRequest(user: message.from, roomID: roomID) })
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
        case .members(let line):
            let words = session.words(line)
            SystemLine(text: words.text, date: line.date, spoken: words.full)
        case .renamed(let rename):
            SystemLine(text: MembershipLines.rename(rename.title, thread: session.store.room(roomID)?.parentRoomID != nil),
                       date: Date(timeIntervalSince1970: (Double(rename.logID.text) ?? 0) / 1000))
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
            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                editing = nil
                drafts[draftKey].field.mode = .reply(message.messageID)
            }
            if menu.startsThread {
                Button("Start Thread", systemImage: "bubble.left.and.text.bubble.right") { startThread(from: message) }
            }
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
            Button("Edit", systemImage: "pencil") { editing = ComposerDraft(field: DraftField(editing: message, in: session)) }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = message }
        }
    }

    /// Copies the room's link; "Link copied" shows under the title for two seconds.
    private func copyLink(_ link: URL) {
        UIPasteboard.general.url = link
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    /// Start Thread, as apron-web's: a thread already started from the message opens; otherwise
    /// the form suggests the message's first line as the title and its text, quoted, as the
    /// description.
    private func startThread(from message: MessageSnapshot) {
        if let existing = session.thread(startedFrom: message.messageID, in: roomID) {
            openRoom(existing)
            return
        }
        startingThread = ThreadRequest(message: message, title: ThreadStart.title(message.body),
                                       description: ThreadStart.description(message.body) ?? "")
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

    /// Files dropped on the conversation join the room's kept draft, as the web's DropZone does;
    /// one still being fitted when the room is left lands in that draft.
    private func dropped(_ files: [ImportedFile]) {
        let limits = session.mediaLimits?.upload
        let key = draftKey, drafts = drafts
        for file in files {
            let item = StagedFile(name: file.url.lastPathComponent, phase: .preparing)
            drafts[key].files.append(item)
            Task {
                do {
                    let attachment = try await AttachmentStaging.prepare(file.url, name: item.name, contentType: nil, limits: limits, into: drafts.staging)
                    drafts[key].ready(item.id, as: attachment)
                } catch {
                    drafts[key].files.removeAll { $0.id == item.id }
                    problem = "\(item.name): \(errorText(error))"
                }
            }
        }
    }

    /// An edit's save closes the editor and brings the kept draft back; anything else empties
    /// the kept draft, as apron-web's `drafts.clear`.
    private func send(_ field: DraftField, attachments: [Attachment]) {
        if field.isEdit { editing = nil } else { drafts[draftKey] = ComposerDraft() }
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

/// Start Thread's form: the message and what it suggests.
struct ThreadRequest: Identifiable {
    let id = UUID()
    let message: MessageSnapshot
    let title: String
    let description: String
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
    let onMention: (String, String) -> Void

    func body(content: Content) -> some View {
        if compact {
            content.sheet(isPresented: $showing) {
                NavigationStack { MemberList(session: session, roomID: roomID, onMention: onMention) }
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Palette.chrome)
            }
        } else {
            content.inspector(isPresented: $showing) {
                MemberList(session: session, roomID: roomID, onMention: onMention).inspectorColumnWidth(Tokens.Size.memberListW)
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

/// The web's ThreadDescription: a room's or thread's description pinned under the header, its
/// Markdown rendered as a message's. It previews three lines; a tap opens the rest and folds it
/// again, and × puts it away.
struct PinnedDescription: View {
    let text: String
    let thread: Bool
    let session: ServerSession
    @Binding var open: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            Image(systemName: "text.alignleft").imageScale(.small).foregroundStyle(Palette.inkMuted).padding(.top, Tokens.Space.s2 + 3)
                .accessibilityHidden(true)
            Group {
                if open {
                    MessageBlocksView(blocks: MessageText.markdown(text, emoji: session.emojiCatalog),
                                      catalog: session.emojiCatalog, role: .ui, gate: session.mediaGate, settings: session.mediaSettings)
                } else {
                    // Three lines, its blocks a line each, as the web's preview cuts it.
                    EmojiText(text: descriptionText(text, session.emojiCatalog), catalog: session.emojiCatalog, role: .ui)
                        .apText(.ui)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(3)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Tokens.Space.s2)
                .contentShape(Rectangle())
                .onTapGesture { open.toggle() }
                .accessibilityAction(named: open ? "Show less of the description" : "Show the whole description") { open.toggle() }
            Button("Hide Description", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(GhostButtonStyle())
                .accessibilityLabel("Hide description")
        }
        .padding(.leading, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s1)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(thread ? "Thread description" : "Room description")
        .task(id: session.server?.emojiCatalogURL) { await session.loadEmojiCatalog(for: text) }
    }
}

/// The web's quiet SystemLine: who joined and left, or a rename, centered between the rows with
/// no avatar and no actions. Its time, which the web shows on hover, is read by VoiceOver, with
/// every name when the line counted some.
struct SystemLine: View {
    let text: String
    let date: Date
    var spoken: String?

    var body: some View {
        Text(text)
            .apText(.sm)
            .foregroundStyle(Palette.inkMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.top, Tokens.Space.s2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(spoken ?? text), \(date.formatted(.dateTime.hour().minute()))")
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
                    Text(pending.text).apText(.body).environment(\.textFace, .chat).foregroundStyle(Palette.ink)
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
