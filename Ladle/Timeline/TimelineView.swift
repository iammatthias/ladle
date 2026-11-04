import ApronKit
import SwiftUI
import UniformTypeIdentifiers

/// A room's messages, oldest first, paging back as the top comes into view. The web's timeline:
/// day pills, the New line in denim, thread cards where each thread began, room notices as
/// callouts, and queued messages at the end. Problems show inline, never as alerts. A link's
/// `place` in this room scrolls to its message and highlights it, or shows its member. The first
/// page waits for its thread listing (`ServerSession.held`); scrolling floats the day in view at
/// the top; a mention of you that arrives pulses once.
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
    /// What was asked of the server: "Leaving…" after 600 ms, its error until the next (#69).
    @State private var feedback = RequestFeedback()
    @State private var reacting: MessageSnapshot?
    @State private var deleting: MessageSnapshot?
    @State private var leaving = false
    /// The ends of the long waits put away, which show again on the next Send.
    @State private var dismissedWaits: Set<Date> = []
    @State private var showingMembers = false
    @State private var searchingHistory = false
    /// The room's threads, on iPhone, and what picking in it asked for once it has gone.
    @State private var browsingThreads = false
    @State private var afterThreads: (() -> Void)?
    /// New Thread from the threads sheet.
    @State private var namingThread = false
    /// Select mode: the messages picked, and a move under way.
    @State private var picking: MessageSelection?
    @State private var movingSelection = false
    @State private var newThreadFromSelection = false
    @State private var atBottom = true
    @State private var visit = Visit.opening
    @State private var visible = false
    @State private var jumpTarget: String?
    /// The rows at least half in view, whose new reactions are then seen.
    @State private var rowsInView: Set<String> = []
    /// The New line, scrolled to once when the visit opens at it.
    @State private var landingTarget: String?
    /// The reader dragged the timeline, which keeps it where they put it rather than landing.
    @State private var scrolledByHand = false
    /// The hole a gap row in view paged older into by itself, until the row leaves the view.
    @State private var autoFilledGap: LogSpan?
    @State private var sentCount = 0
    @State private var viewing: MediaRequest?
    @State private var selecting: SelectableBody?
    @State private var signInQR: SignInQRRequest?
    @State private var remindingAt: CustomReminder?
    @State private var profile: ProfileRequest?
    /// Start Thread's form, suggested from its message.
    @State private var startingThread: ThreadRequest?
    /// The thread Start Thread made, opened once its form has gone.
    @State private var startedThread: String?
    @State private var reminding: MessageReminders
    /// The pill, the catching-up line and the older pill, on the session's clock.
    @State private var loadingWatch: PaneLoadingWatch?
    @Environment(\.heldPaneLoading) private var heldLoading
    /// The day of the messages at the top, which floats there while scrolling and
    /// `FloatingDay.shownFor` after.
    @State private var floatingDay: Date?
    @State private var scrolling = false
    @State private var dayShown = false
    @State private var pulse = MentionPulse()
    @State private var pulsing: Set<LogID> = []
    @Environment(\.fixedNow) private var fixedNow
    @Environment(\.shotPins) private var shotPins
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openRoom) private var openRoom
    @Environment(\.requestSignIn) private var requestSignIn
    @Environment(\.sessionStore) private var sessionStore
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(session: ServerSession, roomID: String, reminders: Reminders, hidden: HiddenDescriptions, drafts: Drafts,
         place: Binding<ApronLink?> = .constant(nil), showingMembers: Bool = false, picking: MessageSelection? = nil,
         editing: ComposerDraft? = nil) {
        self.session = session
        self.roomID = roomID
        self.drafts = drafts
        self.hidden = hidden
        _place = place
        _picking = State(initialValue: picking)
        _editing = State(initialValue: editing)
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

    private var items: [TimelineItem] {
        session.timelineItems(roomID, lineBefore: session.newLine(in: roomID, after: visit.after))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Its first page (and thread listing) on the way, nothing shown yet: placeholder rows
                // where the newest messages will be, as apron-web's TimelineLoading (#173).
                let held = session.held.contains(roomID) || (session.histories[roomID] == nil && session.timeline(roomID).isEmpty)
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let intro = session.privateIntro(roomID) { PrivateIntroCard(session: session, intro: intro) }
                    if held {
                        let thread = session.store.room(roomID)?.parentRoomID != nil
                        VStack(spacing: Tokens.Space.s3) {
                            SkeletonRows(count: thread ? 3 : 6)
                            LoadingPill(label: thread ? "Loading replies…" : "Loading messages…", rising: true)
                        }
                        .padding(.top, Tokens.Space.s4)
                    } else if session.canLoadOlder(roomID) {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchTarget)
                            .task(id: session.histories[roomID]?.olderBefore) {
                                do { try await session.loadOlder(roomID) } catch { problem = errorText(error) }
                            }
                    } else if session.historyEnd(of: roomID) == .signInForOlder {
                        OlderHistoryPrompt(session: session) { requestSignIn(session.record) }
                            .id(OlderHistoryPrompt.rowID)
                    }
                    let shown = held ? [] : items
                    let receipts = session.receipts(in: roomID, shown: shown.compactMap(\.storedMessage))
                    let joins = session.mentionJoins(shown)
                    ForEach(shown) { item in
                        row(item, receipts: receipts, join: joins[item.id] ?? []).id(item.id)
                    }
                    ForEach(Array((held ? [] : session.notices(in: roomID)).enumerated()), id: \.offset) { _, notice in
                        let menu = NoticeMenu(notice, in: session)
                        Callout(title: menu.title) {
                            MessageBlocksView(blocks: MessageText.blocks(notice.body, emoji: session.emojiCatalog, rooms: session.referencedTitle),
                                              catalog: session.emojiCatalog, role: .ui, gate: session.mediaGate, settings: session.mediaSettings)
                                .tint(Palette.denim)
                                .task(id: session.server?.emojiCatalogURL) { await session.loadEmojiCatalog(for: MessageText.plain(notice.body)) }
                            ForEach(menu.signInLinks, id: \.self) { link in
                                Button("Show QR Code", systemImage: "qrcode") { signInQR = SignInQRRequest(link: link) }
                                    .buttonStyle(GhostButtonStyle(tone: Palette.accent))
                                    .padding(.leading, -Tokens.Space.s3)
                            }
                        }
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Tokens.Radius.md))
                            .contextMenu { noticeActions(menu) }
                            .accessibilityActions { noticeActions(menu) }
                            .padding(.horizontal, Tokens.Space.s4)
                            .padding(.top, Tokens.Space.s3)
                    }
                    Color.clear.frame(height: Tokens.Space.s3).id("bottom")
                }
                .scrollTargetLayout()
            }
            // The bottom anchor also holds through size changes (apron-web #190): a row that grows
            // without a scroll, such as an image's size arriving or live text, keeps the latest in
            // view. `atBottom`, which the jump bar reads, is measured from the geometry after each
            // change, so it never stays behind a latest message that is in view.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 80
            } action: { _, bottom in
                atBottom = bottom
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
                let visible = Set(ids)
                let shown = items
                let day = FloatingDay.day(of: shown, visible: visible)
                if day != floatingDay { floatingDay = day }
                fillGapsInView(visible, of: shown)
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.5) { ids in rowsInView = Set(ids) }
            .accessibilityRotor("New Reactions") {
                ForEach(session.unseenReactions(in: roomID), id: \.messageID) { unseen in
                    AccessibilityRotorEntry(Text(UnseenReactions.spoken(unseen.count)), id: unseen.messageID.text)
                }
            }
            .onScrollPhaseChange { _, phase in
                scrolling = phase.isScrolling
                if phase == .interacting { scrolledByHand = true }
            }
            .task(id: scrolling) {
                if scrolling {
                    dayShown = true
                    return
                }
                do { try await Task.sleep(for: FloatingDay.shownFor) } catch { return }
                dayShown = false
            }
            .overlay(alignment: .top) {
                if let floatingDay, shotPins.floatingDay || (dayShown && !atBottom) {
                    FloatingDayPill(label: DayLabel.text(floatingDay, now: fixedNow ?? .now))
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(Motion.slow(reduceMotion), value: dayShown && !atBottom)
            .onChange(of: landingTarget) {
                guard let landingTarget else { return }
                proxy.scrollTo(landingTarget, anchor: UnitPoint(x: 0.5, y: 0.06))
                self.landingTarget = nil
            }
            .onChange(of: jumpTarget) {
                guard let jumpTarget else { return }
                // A message you just sent keeps its queued row's id while the room is on screen.
                let target = items.first { $0.storedMessage?.messageID.text == jumpTarget }?.id ?? jumpTarget
                withAnimation(Motion.slide(reduceMotion)) { proxy.scrollTo(target, anchor: shotPins.scrollAnchor) }
                self.jumpTarget = nil
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: Tokens.Space.s2) {
                    if let pill = loading.pill, !session.timeline(roomID).isEmpty {
                        LoadingPill(label: pill, rising: true)
                    } else if let toast = feedback.current, toast.kind == .pending {
                        LoadingPill(label: toast.text, rising: true)
                    }
                    let reactions = session.unseenReactionCount(in: roomID)
                    if reactions > 0 {
                        ReactionJumpPill(count: reactions) { jumpToNewReactions() }
                            .padding(.horizontal, Tokens.Space.s4)
                            .transition(.opacity)
                    }
                    // Also the way back from an old span, however much is unread beyond the hole.
                    if !atBottom, session.unreadCount(in: roomID) > 0 || !session.holes(in: roomID).isEmpty {
                        JumpBar(count: session.unreadCount(in: roomID), mentions: session.mentionCount(in: roomID)) {
                            withAnimation(Motion.slide(reduceMotion)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.bottom, Tokens.Space.s2)
            }
            .overlay(alignment: .top) {
                if let older = loading.older { LoadingPill(label: older, rising: false).padding(.top, Tokens.Space.s2) }
            }
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .overlay(alignment: .top) { if loading.catchingUpLine { CatchingUpLine() } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    // Wider, it is a line above the composer, as the web's TypingIndicator.
                    if sizeClass != .compact, session.server?.has("activity") == true {
                        TypingIndicator(names: session.typingNames(in: roomID))
                    }
                    if let picking {
                        SelectionBar(session: session, selection: picking, moving: movingSelection,
                                     onSelectBetween: { self.picking?.fillBetween(order: session.timeline(roomID).map(\.messageID)) },
                                     onCancel: { self.picking = nil },
                                     onCopy: copySelection,
                                     onMove: moveSelection,
                                     onNewThread: {
                                         // Refused before a title is asked for, as no thread is made that would stay empty.
                                         if session.mayMoveAll(picking.ids) { newThreadFromSelection = true } else { problem = notMovableWords }
                                     })
                    } else if let note = session.archiveNote {
                        // Reading an export (`ext:archive`): what it is, with no sign-in to offer.
                        Text(note).apText(.sm).foregroundStyle(Palette.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Tokens.Space.s4)
                            .padding(.vertical, Tokens.Space.s3)
                    } else if !session.mayWrite {
                        ReadOnlyPrompt(session: session) { requestSignIn(session.record) }
                    } else {
                        // On iPhone the rooms list, where the offer sits above the profile bar, is not on screen.
                        if sizeClass == .compact, let sessionStore, let offer = sessionStore.alerts.offer {
                            NotifyOfferView(store: sessionStore, offer: offer)
                        }
                        waits
                        ComposerView(session: session, roomID: roomID, draft: draft, staging: drafts.staging, onSend: send,
                                     onHeld: { dismissedWaits = [] }, onProblem: { problem = $0 },
                                     live: composingLive, onStopLive: session.server?.has("edit") == true ? { session.stopLiveTyping() } : nil)
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
        .sheet(isPresented: $browsingThreads, onDismiss: {
            afterThreads?()
            afterThreads = nil
        }) {
            ThreadsSheet(session: session, roomID: roomID,
                         open: { thread in afterThreads = { openRoom(thread) } },
                         newThread: { afterThreads = { namingThread = true } })
        }
        .sheet(isPresented: $namingThread, onDismiss: {
            if let startedThread { openRoom(startedThread) }
            startedThread = nil
        }) {
            let parent = session.topLevelRoom(of: roomID)
            RoomFormSheet(kind: .thread, mode: .create, subtitle: "In \(session.title(of: parent))", isPrivate: session.isPrivate(parent),
                          title: "", description: "") { title, description in
                guard let thread = try await session.createRoom(title: title, description: description, parentRoomID: parent) else { return }
                startedThread = thread
                // A thread of a private room is private too: the room's other members are added, so they see it.
                Task { if let note = await session.includeMembers(of: parent, in: thread) { problem = note } }
            }
        }
        .sheet(item: $selecting) { selected in
            SelectTextSheet(text: selected.text) { selecting = nil }
        }
        .sheet(item: $signInQR) { request in
            SignInQRSheet(link: request.link) { signInQR = nil }
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
        .sheet(isPresented: $newThreadFromSelection, onDismiss: {
            if let startedThread { openRoom(startedThread) }
            startedThread = nil
        }) {
            let first = picking?.earliest(order: session.timeline(roomID).map(\.messageID)).flatMap(session.store.message)
            let count = picking?.ids.count ?? 0
            RoomFormSheet(kind: .thread, mode: .create, subtitle: count == 1 ? "Moving 1 message" : "Moving \(count) messages",
                          isPrivate: session.isPrivate(roomID), title: first.map { ThreadStart.title($0.body) } ?? "", description: "") { title, description in
                guard var selection = picking else { return }
                let parent = session.store.room(roomID)?.parentRoomID ?? roomID
                let result = await session.moveToNewThread(&selection, title: title, description: description)
                guard let thread = result.roomID else { throw SelectionProblem(text: result.problem ?? "No messages were moved") }
                picking = result.moved ? nil : selection
                problem = result.problem ?? result.unadded
                if result.moved { startedThread = thread }
                Task { if let note = await session.includeMembers(of: parent, in: thread) { problem = note } }
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
            ReactionPicker(session: session, caption: session.reactCaption(for: message)) { emoji in
                reacting = nil
                perform("Reacting…") { try await session.toggleReaction(emoji, on: message.messageID) }
            }
        }
        .modifier(MembersPresentation(session: session, roomID: roomID, showing: $showingMembers, compact: sizeClass == .compact) { id, name in
            if sizeClass == .compact { showingMembers = false }
            draft.wrappedValue.field.mention(id, named: name)
        })
        .confirmationDialog("Delete this message?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { message in
            Button("Delete Message", role: .destructive) { perform("Deleting message…") { try await session.delete(message) } }
        } message: { _ in
            Text("It is removed for everyone in the room.")
        }
        .confirmationDialog("Leave \(session.title(of: roomID))?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { perform("Leaving…") { try await session.leave(roomID) } }
        } message: {
            Text(session.isPrivate(roomID) ? "It is private, so you need an invitation to come back." : "You can join it again from Browse Rooms.")
        }
        .onAppear {
            visible = true
            session.show(roomID, true)
        }
        // Each change to the live draft goes out as it is made: typing, a mention, an emoji, a paste.
        .onChange(of: drafts[draftKey].field) { _, field in session.typedLive(field, in: roomID) }
        .onDisappear {
            visible = false
            // The media viewer covers the room without leaving it: its live message goes on.
            if viewing == nil { session.show(roomID, false) }
        }
        .onChange(of: PulseFeed(shown: session.histories[roomID] != nil && !session.held.contains(roomID), messages: session.timeline(roomID)),
                  initial: true) { _, feed in
            guard feed.shown else { return }
            for id in pulse.arrivals(in: feed.messages, latest: session.store.latestLogID(of: roomID), you: session.you?.userID) {
                pulsing.insert(id)
                Task {
                    try? await Task.sleep(for: MentionPulse.held)
                    pulsing.remove(id)
                }
            }
        }
        .onChange(of: ReadMark(reading: isReading, through: session.timeline(roomID).last?.messageID), initial: true) { _, mark in
            guard mark.reading, let through = mark.through else { return }
            Task { await session.markRead(roomID, through: through) }
        }
        // A message with new reactions half in view in the active app: they are seen, as reading marks read.
        .onChange(of: seenInView, initial: true) { _, seen in
            if !seen.isEmpty { session.markReactionsSeen(seen) }
        }
        .task(id: roomID) {
            let watch = PaneLoadingWatch(session: session, roomID: roomID)
            loadingWatch = watch
            await watch.run()
        }
        .task(id: session.status) {
            guard session.status == .signedIn else { return }
            do { try await session.open(roomID) } catch {
                problem = errorText(error)
                return
            }
            if visit == .opening { await land() }
        }
        .onChange(of: place, initial: true) { _, link in
            guard let link, link.room == roomID else { return }
            focus = link
            place = nil
        }
        .task {
            // The renderer's scrolled state: twice, as the lazy rows above settle their heights.
            guard let target = shotPins.scrollTo else { return }
            for _ in 0 ..< 2 {
                try? await Task.sleep(for: .milliseconds(300))
                jumpTarget = target
            }
        }
        .task(id: Focus(link: focus, signedIn: session.status == .signedIn)) {
            guard let link = focus, session.status == .signedIn else { return }
            await show(link)
            if !Task.isCancelled { focus = nil }
        }
    }

    /// Opens the visit at its New line, as apron-web's `landAtDivider`: the session pages back to
    /// where you had read, then the New line scrolls to the top, unless a link or a scroll moved
    /// the timeline from its latest first. Reading starts once it has landed, so nothing is
    /// marked read on the way.
    private func land() async {
        let after = session.readThrough(roomID)
        let landing = Visit.landing(after: after)
        visit = landing
        scrolledByHand = false
        let still = { visit == landing && focus == nil && !scrolledByHand }
        let line = TimelineItem.unreadLine.id
        if await session.landAtDivider(roomID, after: after, still: still) != nil, still() {
            let deadline = ContinuousClock.now + ServerSession.dividerWait
            while !items.contains(where: { $0.id == line }), ContinuousClock.now < deadline, still() {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Twice, as the lazy rows above settle their heights and the bottom anchor follows them.
            for _ in 0 ..< 2 where still() && items.contains(where: { $0.id == line }) {
                landingTarget = line
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        if visit == landing { visit = .landed(after: after) }
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
        await flash(message)
    }

    /// Scrolls to a message and highlights it for two seconds, as a link's place does.
    private func flash(_ message: LogID) async {
        highlighted = message
        try? await Task.sleep(for: .milliseconds(100))
        jumpTarget = message.text
        try? await Task.sleep(for: .seconds(2))
        if highlighted == message { withAnimation(Motion.medium(reduceMotion)) { highlighted = nil } }
    }

    /// The jump to new reactions: the oldest message with any, which is then seen.
    private func jumpToNewReactions() {
        guard let next = session.nextUnseenReaction(in: roomID) else { return }
        session.markReactionsSeen([next])
        Task { await flash(next) }
    }

    /// The messages with new reactions that are seen now: half in view while the pane is on
    /// screen in the active app, the visit landed.
    private var seenInView: [LogID] {
        guard visible, scenePhase == .active, visit.isLanded else { return [] }
        return session.unseenReactions(in: roomID).map(\.messageID).filter { rowsInView.contains($0.text) }
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

    private var mayJoin: Bool {
        session.status == .signedIn && session.server?.has("rooms") == true && session.mayWrite && !session.joinedRoomIDs.contains(roomID)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // On iPhone, what is new elsewhere rides beside Back to the rooms list (apron-web #84).
        if sizeClass == .compact {
            ToolbarItem(placement: .topBarLeading) {
                let news = session.newsElsewhere(than: roomID)
                if news.mentions > 0 {
                    UnreadCount(count: news.mentions, mentions: true)
                        .accessibilityLabel("\(news.mentions) \(news.mentions == 1 ? "mention" : "mentions") in other rooms")
                } else if news.unread > 0 {
                    UnreadCount(count: news.unread)
                        .accessibilityLabel("\(news.unread) new in other rooms")
                }
            }
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                // A thread's room above its title, a crumb back to it, as the web's `Parent › Thread`.
                if let parent = session.store.room(roomID)?.parentRoomID {
                    Button { openRoom(parent) } label: {
                        Text("\(TextDirection.isolated(session.title(of: parent))) ›")
                            .apText(.xs, .semibold).foregroundStyle(Palette.denim).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to \(session.title(of: parent))")
                }
                HStack(spacing: Tokens.Space.s1) {
                    // An untitled private room says who it is with before its name, as the web's RoomHeader.
                    if session.isNamedForMembers(roomID) { Faces(session: session, people: session.faces(of: roomID)) }
                    if session.isPrivate(roomID) { Lock(tint: Palette.private) }
                    Text(session.title(of: roomID)).font(.headline).foregroundStyle(Palette.ink).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // Read without joining: Join stays a button, since it is what such a pane is for (the web's RoomHeader).
            if mayJoin {
                let noun = session.store.room(roomID)?.parentRoomID == nil ? "room" : "thread"
                Button("Join") { perform("Joining…") { try await session.join(roomID) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .accessibilityLabel("Join \(noun)")
                    .accessibilityHint(noun == "room" ? "Gets its messages live, and lists it with your rooms" : "Gets its replies live, and lists it under the room")
            }
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
                    // On iPhone the rooms list, and the threads under the room, are out of sight in a room.
                    if sizeClass == .compact, session.offersThreads(in: roomID) {
                        Button("Threads", systemImage: "bubble.left.and.text.bubble.right") { browsingThreads = true }
                    }
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
                    if session.server?.has("rooms") == true, session.joinedRoomIDs.contains(roomID) {
                        Button("Leave Room", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { leaving = true }
                    }
                }
            }
        }
    }

    private var loading: PaneLoading.Shown { heldLoading ?? loadingWatch?.shown ?? PaneLoading.Shown() }

    /// Connection state (UX spec 4.1) and the last failure, under the navigation bar. A short
    /// drop's way back shows as the floating pill instead (`PaneLoading`).
    @ViewBuilder
    private var banner: some View {
        let state = session.reconnectingQuietly ? nil : ConnectionState(session.status)
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
                if !session.problemDismissed {
                    ActionBanner(symbol: state.symbol, title: state.title(session.record), detail: state.detail) {
                        if state.canRetry { Button(session.isDisconnected ? "Connect" : "Try Now") { session.start() }.buttonStyle(GhostButtonStyle(tone: Palette.accent)) }
                        Button("Dismiss", systemImage: "xmark") { session.problemDismissed = true }
                            .labelStyle(.iconOnly).buttonStyle(GhostButtonStyle())
                    }
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
            if let toast = feedback.current, toast.kind == .error {
                ActionBanner(symbol: "exclamationmark.triangle", title: toast.text, tone: Palette.danger) {
                    Button("Dismiss", systemImage: "xmark") { feedback.dismiss(toast) }
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
        .padding(.top, state == nil && problem == nil && feedback.current?.kind != .error && !reminding.notificationsOff && session.unavailableMessage == nil ? 0 : Tokens.Space.s2)
    }

    @ViewBuilder
    private func row(_ item: TimelineItem, receipts: [LogID: [Reader]], join: MentionJoin) -> some View {
        switch item {
        case .message(let message, let continues, let pending):
            // A queued message's row and the logged message's are one view: the same branch, the
            // same id, with what the menu and select mode offer gated on the server holding it.
            let stored = item.storedMessage != nil
            HStack(alignment: .top, spacing: 0) {
                if let picking, stored {
                    SelectMark(on: picking.contains(message.messageID))
                        .padding(.leading, Tokens.Space.s2)
                        .padding(.top, continues ? Tokens.Space.s1 : Tokens.Space.s3)
                }
                MessageRow(session: session, message: message, continues: continues, pending: pending,
                           highlighted: highlighted == message.messageID || picking?.contains(message.messageID) == true,
                           pulsing: pulsing.contains(message.messageID),
                           mentionJoin: join,
                           reminderDue: reminding.reminder(on: message)?.due,
                           onClearReminder: { reminding.forget(message) },
                           onReact: { emoji in perform("Reacting…") { try await session.toggleReaction(emoji, on: message.messageID) } },
                           onAddReaction: { reacting = message },
                           onJump: { target in
                               // A quoted message the timeline holds scrolls into view; one it
                               // doesn't (older, or in a hole) is revealed as its link would be.
                               if session.timeline(roomID).contains(where: { $0.messageID == target }) {
                                   jumpTarget = target.text
                               } else {
                                   focus = ApronLink(server: session.record.url, room: roomID, message: target)
                               }
                           },
                           onProfile: { profile = ProfileRequest(user: message.from, roomID: roomID) },
                           seenBy: editing?.field.editing?.messageID == message.messageID ? [] : receipts[message.messageID] ?? [])
                    .allowsHitTesting(picking == nil)
            }
            .padding(.horizontal, Tokens.Space.s2)
            .padding(.top, continues ? 0 : Tokens.Space.s3)
            .contentShape(Rectangle())
            .onTapGesture { if picking != nil, stored, session.maySelect(message, in: roomID) { toggle(message.messageID) } }
            .focusable(interactions: .activate)
            .onKeyPress(keys: ["x"]) { press in
                guard stored, press.modifiers.isDisjoint(with: [.command, .control, .option]), !movingSelection,
                      session.maySelect(message, in: roomID) else { return .ignored }
                if picking == nil { editing = nil }
                picking = KeyboardCommands.pressX(on: message.messageID, selection: picking, roomID: roomID,
                                                   order: session.timeline(roomID).map(\.messageID))
                return .handled
            }
            .onKeyPress(keys: [.space, .return]) { _ in
                guard picking != nil, stored, session.maySelect(message, in: roomID) else { return .ignored }
                toggle(message.messageID)
                return .handled
            }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .contextMenu { if picking == nil { if stored { actions(for: message) } else if let pending { actions(for: pending) } } }
            .accessibilityActions { if picking == nil { if stored { actions(for: message) } else if let pending { actions(for: pending) } } }
            .accessibilityAddTraits(picking?.contains(message.messageID) == true ? .isSelected : [])
        case .day(let date):
            TimelineDivider(kind: .day, label: DayLabel.text(date, now: fixedNow ?? .now))
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
        case .gap(let hole):
            let loading: Fill? = if case .hole(hole, let side) = session.histories[roomID]?.loading { side } else { nil }
            GapRow(loading: loading) { side in fill(hole, side) }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.top, Tokens.Space.s4)
        }
    }

    /// Loads one page into a hole from one side. Newer messages, read on from the span below, then
    /// start at the top of the view, as the page a tap asked for; older ones come in under the gap
    /// row, which the bottom anchor keeps where it is, as paging older does.
    private func fill(_ hole: LogSpan, _ side: Fill) {
        Task {
            do { try await session.fill(hole, in: roomID, side) } catch {
                problem = errorText(error)
                return
            }
            if side == .newerFromBelow, let first = session.timeline(roomID).first(where: { $0.messageID >= hole.lower }) {
                landingTarget = first.messageID.text
            }
        }
    }

    /// A gap row that comes into view beside the newer span's rows pages older messages into it
    /// once, as the top of the timeline pages older when it comes into view; the next page waits
    /// for a tap or for the row to leave the view and come back, so a gap that stays in view never
    /// loads its whole hole unasked. Beside the older span's rows alone it waits for a tap.
    private func fillGapsInView(_ visible: Set<String>, of items: [TimelineItem]) {
        guard !shotPins.gapWaits else { return }
        let shown = items.filter { visible.contains($0.id) }
        let gaps = shown.compactMap { item -> LogSpan? in if case .gap(let hole) = item { hole } else { nil } }
        guard let hole = gaps.first else {
            autoFilledGap = nil
            return
        }
        guard session.histories[roomID]?.loading == nil, autoFilledGap.map({ !($0.holds(hole.lower) && $0.holds(hole.upper)) }) ?? true,
              shown.contains(where: { $0.storedMessage.map { $0.messageID > hole.upper } ?? false }) else { return }
        autoFilledGap = hole
        fill(hole, .olderFromAbove)
    }

    /// A queued message's menu (UX spec 3.8): Cancel Sending, or Retry and Delete once it failed.
    @ViewBuilder
    private func actions(for pending: ServerSession.PendingMessage) -> some View {
        switch pending.state {
        case .sending:
            Button("Cancel Sending", systemImage: "xmark.circle", role: .destructive) { session.discard(pending.id) }
        case .failed:
            Button("Retry", systemImage: "arrow.clockwise") { session.retry(pending.id) }
            Button("Delete", systemImage: "trash", role: .destructive) { session.discard(pending.id) }
        case .sent:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actions(for message: MessageSnapshot) -> some View {
        let menu = MessageMenu(message, in: session)
        Section {
            if menu.reacts {
                ControlGroup {
                    ForEach(ReactionPicker.quick.prefix(4), id: \.self) { emoji in
                        Button(emoji) { perform("Reacting…") { try await session.toggleReaction(emoji, on: message.messageID) } }
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
        if session.maySelect(message, in: roomID) {
            Button("Select", systemImage: "checkmark.circle") {
                editing = nil
                picking = MessageSelection(roomID: roomID, first: message.messageID)
            }
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
        }
        if menu.removesReply {
            Button("Remove Reply Reference", systemImage: "arrowshape.turn.up.left") { perform("Removing reply reference…") { try await session.removeReply(from: message) } }
        }
        if menu.editable {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = message }
        }
    }

    // MARK: Select mode

    /// A tap, or Space or Return on a focused message, as apron-web's check box, picks or unpicks it.
    private func toggle(_ id: LogID) {
        guard !movingSelection, var selection = picking else { return }
        picking = selection.toggle(id, order: session.timeline(roomID).map(\.messageID)) ? selection : nil
    }

    /// Copy, as apron-web's `copySelectionLog`: the picked messages as a Markdown log, and as
    /// HTML for rich editors (`messageLogHtml`), then select mode ends.
    private func copySelection() {
        guard let picking else { return }
        let log = session.markdownLog(of: picking.ids, in: roomID)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: log, UTType.html.identifier: MessageLog.html(log)]])
        self.picking = nil
    }

    /// Moves the selection to a thread or back to the room; what was refused stays picked.
    private func moveSelection(to target: String) {
        guard var selection = picking, !movingSelection else { return }
        movingSelection = true
        Task {
            let result = await session.move(&selection, to: target)
            movingSelection = false
            picking = result.moved ? nil : selection
            problem = result.problem ?? result.unadded
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

    /// A notice's menu (`NoticeMenu`): its text, each sign-in link's QR code, each code span on its own, and its links.
    @ViewBuilder
    private func noticeActions(_ menu: NoticeMenu) -> some View {
        Button("Copy Text", systemImage: "doc.on.doc") { UIPasteboard.general.string = menu.text }
        Button("Select Text", systemImage: "selection.pin.in.out") { selecting = SelectableBody(text: menu.text) }
        ForEach(menu.signInLinks, id: \.self) { link in
            Button("Show QR Code", systemImage: "qrcode") { signInQR = SignInQRRequest(link: link) }
        }
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

    /// The open draft is the message being typed live here (`/live`).
    private var composingLive: Bool { editing == nil && session.liveMessage?.roomID == roomID }

    /// An edit's save closes the editor and brings the kept draft back; anything else empties
    /// the kept draft, as apron-web's `drafts.clear`. A failed command's draft comes back, and
    /// its reason is a notice in the room; `/join` shows the room it joined. `/live` keeps its
    /// draft here, emptied when it is finished and given back when it can't be made.
    private func send(_ draft: ComposerDraft) {
        let key = draftKey, drafts = drafts
        // Read before the draft empties, whose change would otherwise go out as a reset first.
        if composingLive { return session.sendLive(draft.field, in: roomID) }
        if draft.field.isEdit { editing = nil } else { drafts[key] = ComposerDraft() }
        sentCount += 1
        let live = LiveDraft(forget: { drafts[key] = ComposerDraft(files: drafts[key].files) },
                             restore: { drafts.restore(ComposerDraft(field: $0), at: key) })
        Task {
            do {
                if let room = try await session.submit(draft, in: roomID, live: live) { openRoom(room) }
            } catch let failure as CommandFailure {
                drafts.restore(failure.draft, at: key)
            } catch {
                problem = errorText(error)
            }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() } catch { problem = errorText(error) }
        }
    }

    /// A request the toast follows, as apron-web's `feedback.track`.
    private func perform(_ pending: String, _ operation: @escaping () async throws -> Void) {
        Task { await feedback.track(pending, operation) }
    }
}


/// One look at a room, as the web's `newDivider`: where you had read when it opened fixes the New
/// line for the visit, which then opens at it (`land`).
enum Visit: Equatable {
    case opening
    /// Paging back to the New line and scrolling to it; nothing is read yet.
    case landing(after: LogID?)
    case landed(after: LogID?)

    var after: LogID? {
        switch self {
        case .opening: nil
        case .landing(let after), .landed(let after): after
        }
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

/// What `MentionPulse` reads: the room's messages, once its first page is shown.
struct PulseFeed: Equatable {
    var shown: Bool
    var messages: [MessageSnapshot]
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

/// The web's JumpBar: new messages below, and the way back to them; with none counted, the way
/// back from an old span to the latest.
struct JumpBar: View {
    let count: Int
    let mentions: Int
    let jump: () -> Void

    var body: some View {
        Button(action: jump) {
            HStack(spacing: Tokens.Space.s3) {
                Text(count == 0 ? "Latest messages" : mentions > 0 ? "\(count) new, \(mentions) mention\(mentions == 1 ? "" : "s") of you" : "\(count) new message\(count == 1 ? "" : "s")")
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

/// New reactions to your messages, Ladle's own, over the timeline beside the web's JumpBar: a
/// tap (or ⌘⇧R) goes to the oldest message with any and highlights it.
struct ReactionJumpPill: View {
    let count: Int
    let jump: () -> Void

    var body: some View {
        Button(action: jump) {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: "face.smiling").foregroundStyle(Palette.denim)
                Text(UnseenReactions.shown(count)).foregroundStyle(Palette.inkMuted)
                Text("Show").fontWeight(.semibold).foregroundStyle(Palette.denim)
            }
            .apText(.ui)
            .padding(.horizontal, Tokens.Space.s3)
            .frame(minHeight: Tokens.Control.md + Tokens.Space.s2)
            .background(Palette.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.denim.opacity(0.5)))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .touchTarget()
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .accessibilityLabel(UnseenReactions.spoken(count))
        .accessibilityHint("Shows the oldest message with new reactions")
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
                if unread > 0 { UnreadCount(count: unread, quiet: true) }
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

extension EnvironmentValues {
    /// Opens a room or thread in the current navigation, from a thread card or a link.
    @Entry var openRoom = OpenRoomAction { _ in }
    /// Opens the sign-in sheet for a saved server.
    @Entry var requestSignIn = SignInAction { _ in }
    /// The signed-in session of another saved server, for a link card naming a place on it.
    @Entry var liveSessions = SessionLookup { _ in [] }
    /// Every server, for the offer to turn notifications on.
    @Entry var sessionStore: SessionStore?
}

/// Finds a saved server's signed-in sessions, one per account, by its URL; a struct, as `OpenRoomAction`.
struct SessionLookup {
    let find: (URL) -> [ServerSession]
    init(_ find: @escaping (URL) -> [ServerSession]) { self.find = find }
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

/// Between two loaded spans of a room (`TimelineItem.gap`): the messages of the hole are not
/// loaded. Load Older pages down from the span above, Load Newer up from the span below; each
/// is a 44 pt target and a VoiceOver action, and the one under way shows its spinner. The row is
/// keyed by the hole's edges, so a fill from either side remakes it; what is loading lives in the
/// session (`RoomHistory.loading`), never in row state. At accessibility sizes the buttons go
/// under the words.
struct GapRow: View {
    let loading: Fill?
    let fill: (Fill) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.fixedTypeSize) private var fixedTypeSize

    var body: some View {
        let stacked = (fixedTypeSize ?? typeSize).isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Space.s2)) : AnyLayout(HStackLayout(spacing: Tokens.Space.s2))
        VStack(spacing: Tokens.Space.s2) {
            Rectangle().fill(Palette.line).frame(height: 1)
            layout {
                Label("Messages not loaded", systemImage: "ellipsis.rectangle")
                    .labelStyle(TightLabel())
                    .apText(.sm, .medium)
                    .foregroundStyle(Palette.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    button(.olderFromAbove, "Load Older", "arrow.up", loading: "Loading older messages")
                    button(.newerFromBelow, "Load Newer", "arrow.down", loading: "Loading newer messages")
                }
                .fixedSize(horizontal: !stacked, vertical: false)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Messages not loaded here")
        .accessibilityHint("Older messages are above this point and newer ones below it")
        .accessibilityActions {
            Button("Load Older Messages") { fill(.olderFromAbove) }
            Button("Load Newer Messages") { fill(.newerFromBelow) }
        }
    }

    private func button(_ side: Fill, _ title: String, _ symbol: String, loading spoken: String) -> some View {
        Button { fill(side) } label: {
            HStack(spacing: Tokens.Space.s1) {
                if loading == side {
                    ProgressView().controlSize(.small).tint(Palette.denim)
                } else {
                    Image(systemName: symbol).imageScale(.small)
                }
                Text(title)
            }
        }
        .buttonStyle(GhostButtonStyle(tone: Palette.denim))
        .disabled(loading != nil)
        .accessibilityLabel(loading == side ? spoken : "\(title) Messages")
    }
}

/// At the top of a guest's timeline where the server asks them to sign in for older messages
/// (`HistoryEnd.signInForOlder`): the end of what loads here, not an error.
struct OlderHistoryPrompt: View {
    /// Its place in the timeline, which the renderer scrolls to at AX3.
    static let rowID = "older-history-prompt"

    let session: ServerSession
    let signIn: () -> Void

    var body: some View {
        ActionBanner(symbol: "clock.arrow.circlepath", title: "Sign in to see older messages",
                     detail: "Guests can read the latest messages. Sign in or create an account on \(session.serverName) to load earlier history.") {
            Button("Sign In", action: signIn)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Signs in to \(session.serverName) to load earlier messages")
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.top, Tokens.Space.s3)
    }
}

/// Opens a room by id; a struct so the environment can tell it apart from a new closure.
struct OpenRoomAction {
    let open: (String) -> Void
    init(_ open: @escaping (String) -> Void) { self.open = open }
    func callAsFunction(_ roomID: String) { open(roomID) }
}
