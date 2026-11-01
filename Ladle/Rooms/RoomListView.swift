import ApronKit
import SwiftUI

/// One server's rooms, as the web's sidebar: a "Rooms" section of rows, threads under their room
/// on a guide line with their description and latest message, and the profile bar at the foot.
/// The open room has a neutral fill and an accent bar; an unread room is set in ink and
/// semibold with its count, and a mention of you is an `@` count. Connection problems and
/// sign-in show as a banner at the top, never an alert or a sheet that opens by itself. The
/// title (on iPad, the head above the rooms, as the web's sidebar head) opens the server pane,
/// and the profile bar opens You.
struct RoomListView: View {
    let session: ServerSession
    var selected: String?
    let open: (String) -> Void
    var onSignIn: () -> Void = {}
    /// Connect to Another Server…: the Connect sheet for a new server.
    var onConnect: () -> Void = {}
    /// The iPad sidebar, whose navigation bar is hidden: the server's head leads the list.
    var showsServerHead = false
    /// What Search Rooms starts with: the renderer's typed words, which it cannot type.
    var startingSearch = ""
    /// The renderer's reorder mode, which it cannot tap into.
    var startsReordering = false
    @State private var browsing = false
    /// Reorder Rooms: the rooms alone, with their handles, as the web folds every room's threads
    /// away while one is carried.
    @State private var reordering: EditMode = .inactive
    /// Rooms and Private fold to their rooms with news, open from the start and kept as left on
    /// this device, as the web's `apron.sidebarFolds`.
    @AppStorage("roomsSectionFolded") private var roomsFolded = false
    @AppStorage("privateSectionFolded") private var privateFolded = false
    @State private var naming: NewRoom?
    /// New Room's Private.
    @State private var namingPrivate = false
    /// New private conversation, from the + beside Private.
    @State private var startingPrivate = false
    /// Other Threads is open until folded, and stays as it was left, as the web's.
    @AppStorage("otherThreadsOpen") private var othersOpen = true
    /// Inactive is folded until opened, as it is there to put quiet threads away, and stays as it
    /// was left (apron-web #185).
    @AppStorage("inactiveThreadsOpen") private var inactiveOpen = false
    /// The open thread and whether it was under Inactive when it was opened: it stays on that
    /// side until another is opened, so reading it never moves its row.
    @State private var opened: OpenedThread?
    /// The room whose other threads all show, past the first three, after "N more…".
    @State private var allOthersFor: String?
    @Environment(\.fixedNow) private var fixedNow
    @Environment(\.heldAwayWords) private var heldAwayWords
    @State private var problem: String?
    /// The protocol version whose warning was dismissed on this launch.
    @State private var versionWarningSeen: Int?
    @State private var leaving: String?
    /// The room a swipe asked to mute, whose choices a dialog lists.
    @State private var muting: String?
    @State private var panel: Panel?
    /// Rooms by name, as typed in the search field.
    @State private var roomQuery = ""
    /// Search Local History, from the rooms search's "Search Messages for".
    @State private var searchingHistory: HistoryQuery?
    @Environment(\.openPreferences) private var openPreferences

    struct HistoryQuery: Identifiable {
        var query: String
        var id: String { query }
    }
    /// What the server pane asked for, once it has gone.
    @State private var afterPanel: (() -> Void)?

    /// The sheets this list opens: the server pane, and You.
    enum Panel: String, Identifiable {
        case server, you
        var id: String { rawValue }
    }

    struct OpenedThread: Equatable {
        var id: String
        var quiet: Bool
    }

    /// A room to create: top level, or a thread under `parent`.
    struct NewRoom: Identifiable {
        var parent: String?
        var id: String { parent ?? "" }
    }

    var body: some View {
        List {
            if showsServerHead {
                serverHead.listRowBackground(Color.clear).listRowSeparator(.hidden)
                // The iPad sidebar hides its navigation bar, and the search field with it.
                RoomSearchField(text: $roomQuery).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if let banner = bannerView { banner.listRowBackground(Color.clear).listRowSeparator(.hidden) }
            if !roomQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                roomsFound
            } else {
            Section {
                rooms(session.publicRoomTree, folded: roomsFolded)
            } header: {
                SectionFoldHead(title: "Rooms", folded: $roomsFolded, canFold: !isReordering) {
                    if isReordering {
                        Button("Done") { withAnimation { reordering = .inactive } }
                            .apText(.ui, .semibold).foregroundStyle(Palette.accent).touchTarget()
                    } else if session.status == .signedIn, session.server?.has("rooms") == true {
                        Menu {
                            if session.mayCreateRooms {
                                Button("New Room", systemImage: "plus") {
                                    namingPrivate = false
                                    naming = NewRoom(parent: nil)
                                }
                            }
                            Button("Browse Rooms", systemImage: "magnifyingglass") { browsing = true }
                            Button("Reorder Rooms", systemImage: "arrow.up.arrow.down") { withAnimation { reordering = .active } }
                        } label: {
                            Image(systemName: "plus").foregroundStyle(Palette.inkMuted).touchTarget()
                        }
                        .accessibilityLabel("Add a room")
                    }
                }
            }
            // Shown with private rooms in it, or empty, for its +, where you could start one.
            if !session.privateRoomTree.isEmpty || session.mayStartPrivate {
                Section {
                    rooms(session.privateRoomTree, folded: privateFolded)
                } header: {
                    SectionFoldHead(title: "Private", folded: $privateFolded, canFold: !isReordering) {
                        if session.mayStartPrivate, !isReordering {
                            Button("New Private Conversation", systemImage: "plus") { startingPrivate = true }
                                .labelStyle(.iconOnly)
                                .foregroundStyle(Palette.inkMuted)
                                .touchTarget()
                        }
                    }
                }
            }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $reordering)
        .onAppear { if startsReordering { reordering = .active } }
        .background { moveKeys }
        // Where iOS puts it: at the bottom on iPhone, in reach (UX.md 1.2).
        .searchable(text: $roomQuery, prompt: "Search Rooms")
        .sheet(item: $searchingHistory) { SearchView(session: session, initial: $0.query) }
        .onAppear { if !startingSearch.isEmpty { roomQuery = startingSearch } }
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Tokens.Size.touchTarget)
        .onChange(of: selected, initial: true) { _, thread in
            guard let thread, let parent = session.store.room(thread)?.parentRoomID,
                  let node = session.roomTree.first(where: { $0.roomID == parent }) else { return opened = nil }
            let side = session.threadList(of: node, open: thread, now: fixedNow ?? .now).openThreadIsQuiet
            opened = side.map { OpenedThread(id: thread, quiet: $0) }
        }
        .background(Palette.chrome)
        .safeAreaInset(edge: .bottom, spacing: 0) { profileBar }
        .navigationTitle(session.serverName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { panel = .server } label: {
                    HStack(spacing: Tokens.Space.s1) {
                        Text(session.serverName).font(.headline).foregroundStyle(Palette.ink).lineLimit(1)
                        Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(Palette.inkMuted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(session.serverName), server details")
            }
        }
        .sheet(isPresented: $browsing) { BrowseRoomsView(session: session, open: open) }
        .sheet(item: $naming) { new in
            RoomFormSheet(kind: new.parent == nil ? .room : .thread, mode: .create,
                          subtitle: new.parent.map { "In \(session.title(of: $0))" }, isPrivate: new.parent.map(session.isPrivate) ?? false,
                          privateChoice: new.parent == nil ? $namingPrivate : nil,
                          title: "", description: "") { title, description in
                let created = try await session.createRoom(title: title, description: description, parentRoomID: new.parent,
                                                           isPrivate: new.parent == nil && namingPrivate)
                guard let created else { return }
                open(created)
                // A thread of a private room is private too: the room's other members are added, so they see it.
                if let parent = new.parent {
                    Task { if let note = await session.includeMembers(of: parent, in: created) { problem = note } }
                }
            }
        }
        .sheet(isPresented: $startingPrivate) {
            NewPrivateSheet(session: session) { roomID, note in
                open(roomID)
                problem = note
            }
        }
        .confirmationDialog(leaving.map { "Leave \(session.title(of: $0))?" } ?? "", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                            titleVisibility: .visible, presenting: leaving) { roomID in
            Button("Leave", role: .destructive) { perform { try await session.leave(roomID) } }
        } message: { roomID in
            Text(session.isPrivate(roomID) ? "It is private, so you need an invitation to come back." : "You can join it again from Browse Rooms.")
        }
        .confirmationDialog(muting.map { "Mute \(session.title(of: $0))" } ?? "", isPresented: Binding(get: { muting != nil }, set: { if !$0 { muting = nil } }),
                            titleVisibility: .visible, presenting: muting) { roomID in
            ForEach(MuteChoice.room(now: Date())) { choice in
                Button(choice.hint.map { "\(choice.title), \($0)" } ?? choice.title) { perform { try await session.setMute(roomID, choice.end) } }
            }
        } message: { _ in
            Text("No notifications from it or its threads on your devices. Only you see it.")
        }
        .sheet(item: $panel, onDismiss: {
            afterPanel?()
            afterPanel = nil
        }) { panel in
            switch panel {
            case .server:
                ServerPaneView(session: session, onEditProfile: { afterPanel = { self.panel = .you } }, onConnect: { afterPanel = onConnect })
            case .you:
                YouView(session: session)
            }
        }
    }

    /// Rooms and threads by name, and the same words searched in messages.
    @ViewBuilder
    private var roomsFound: some View {
        let typed = roomQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        Section {
            ForEach(session.rooms(named: typed), id: \.id) { room in
                roomRow(room.id, isThread: room.isThread)
            }
            Button {
                searchingHistory = HistoryQuery(query: typed)
            } label: {
                Label("Search Messages for “\(typed)”", systemImage: "text.magnifyingglass")
                    .apText(.ui).foregroundStyle(Palette.denim)
            }
            .listRowBackground(Color.clear)
        } header: {
            SectionHead(title: "Rooms").textCase(nil)
        }
    }

    /// The web's sidebar head on iPad: the server's face, name and host, which open its pane.
    private var serverHead: some View {
        Button { panel = .server } label: {
            HStack(spacing: Tokens.Space.s2) {
                RailTile(label: session.serverName, image: session.serverAvatarURL, active: false)
                    .scaleEffect(0.8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.serverName).apText(.ui, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(session.record.url.host() ?? "").apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(Palette.inkMuted)
            }
            .frame(minHeight: Tokens.Size.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.serverName), server details")
    }

    // MARK: Rows

    private var isReordering: Bool { reordering.isEditing }

    /// A section's rooms in the order kept on this device; folded, those with news and the one
    /// open. While reordering, every room, without its threads, each with its handle.
    @ViewBuilder
    private func rooms(_ nodes: [RoomNode], folded: Bool) -> some View {
        if isReordering {
            ForEach(nodes) { node in roomRow(node.roomID, isThread: false) }
                .onMove { session.moveRooms(nodes.map(\.roomID), fromOffsets: $0, toOffset: $1) }
        } else {
            ForEach(session.shownRooms(nodes, folded: folded, open: selected)) { node in
                roomRow(node.roomID, isThread: false)
                threads(of: node)
            }
        }
    }

    /// Option+↑ and Option+↓ move the open room (or the one holding the open thread) past the
    /// next room its section shows, as the web's Alt+↑/↓ on a room.
    private var moveKeys: some View {
        ZStack {
            Button("Move Room Up") { moveOpenRoom(by: -1) }.keyboardShortcut(.upArrow, modifiers: .option)
            Button("Move Room Down") { moveOpenRoom(by: 1) }.keyboardShortcut(.downArrow, modifiers: .option)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func moveOpenRoom(by step: Int) {
        guard let selected else { return }
        let roomID = session.topLevelRoom(of: selected)
        let isPrivate = session.isPrivateRoom(roomID)
        let shown = session.shownRooms(isPrivate ? session.privateRoomTree : session.publicRoomTree,
                                       folded: isPrivate ? privateFolded : roomsFolded, open: selected)
        withAnimation { _ = session.moveRoom(roomID, by: step, among: shown.map(\.roomID)) }
    }

    /// A room's threads as the web's ThreadList: under the open room, its joined threads and
    /// Other Threads; under another, only its joined threads with news.
    @ViewBuilder
    private func threads(of node: RoomNode) -> some View {
        let list = session.threadList(of: node, open: selected, othersFolded: !othersOpen, allOthers: allOthersFor == node.roomID,
                                      now: fixedNow ?? .now, inactiveFolded: !inactiveOpen,
                                      openedQuiet: opened.flatMap { $0.id == selected ? $0.quiet : nil },
                                      threadsFolded: session.threadsFolded(node.roomID))
        ForEach(list.joined, id: \.self) { roomRow($0, isThread: true) }
        if list.inactiveCount > 0 {
            FoldHeading(label: "Inactive", count: list.inactiveCount, open: $inactiveOpen)
            ForEach(list.inactive, id: \.self) { roomRow($0, isThread: true) }
        }
        if list.othersCount > 0 {
            FoldHeading(label: "Other Threads", count: list.othersCount, open: $othersOpen)
            ForEach(list.others, id: \.self) { roomRow($0, isThread: true) }
            if list.moreOthers > 0 {
                Button { allOthersFor = node.roomID } label: {
                    Text("\(list.moreOthers) more…").apText(.sm, .medium).foregroundStyle(Palette.denim)
                        .padding(.leading, RoomRow.threadInset)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: Tokens.Space.s2, bottom: 0, trailing: Tokens.Space.s2))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityHint("Shows every other thread of \(session.title(of: node.roomID))")
            }
        }
    }

    private func roomRow(_ roomID: String, isThread: Bool) -> some View {
        let isSelected = roomID == selected
        // The open room folded to its threads with news: a … that shows them all, as the web's FoldPill.
        let foldedOpen = !isThread && !isReordering && selected.map(session.topLevelRoom(of:)) == roomID && session.threadsFolded(roomID)
        return Button {
            // Picking the open room again folds its threads, and once more unfolds them (#145).
            if isSelected, !isThread, !isReordering { session.foldThreads(roomID, !session.threadsFolded(roomID)) } else { open(roomID) }
        } label: {
            RoomRow(session: session, roomID: roomID, isThread: isThread, isSelected: isSelected, now: fixedNow ?? .now,
                    trailingSpace: foldedOpen ? Tokens.Size.touchTarget : 0)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isSelected && !isThread ? (session.threadsFolded(roomID) ? "Shows all its threads" : "Folds its threads to those with news") : "")
        .overlay(alignment: .trailing) {
            if foldedOpen {
                FoldPill(label: "Show all threads in \(session.title(of: roomID))") { session.foldThreads(roomID, false) }
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: Tokens.Space.s2, bottom: 1, trailing: Tokens.Space.s2))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .leading) {
            if session.unreadCount(in: roomID) > 0, session.status == .signedIn {
                Button("Mark as Read", systemImage: "checkmark.message") { Task { await session.markAllRead(roomID) } }.tint(Palette.denim)
            }
            if isThread, !session.joinedRoomIDs.contains(roomID), session.server?.has("rooms") == true, session.mayWrite {
                Button("Join", systemImage: "plus.circle") { perform { try await session.join(roomID) } }.tint(Palette.denim)
            }
        }
        .swipeActions {
            if session.joinedRoomIDs.contains(roomID), session.server?.has("rooms") == true {
                Button("Leave", systemImage: "rectangle.portrait.and.arrow.right") { leaving = roomID }.tint(Palette.danger)
            }
            if session.mayMute {
                if let mute = session.mute(of: roomID) {
                    Button("Unmute", systemImage: "bell") {
                        let target = if case .withRoom(let parent, _) = mute { parent } else { roomID }
                        perform { try await session.setMute(target, nil) }
                    }
                    .tint(Palette.denim)
                } else {
                    Button("Mute", systemImage: "bell.slash") { muting = roomID }.tint(Palette.inkMuted)
                }
            }
        }
        .contextMenu { roomActions(roomID, isThread: isThread) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func roomActions(_ roomID: String, isThread: Bool) -> some View {
        Button("Mark as Read", systemImage: "checkmark.message") { Task { await session.markAllRead(roomID) } }
            .disabled(session.status != .signedIn || session.readMark(of: roomID) == nil)
        if !isThread {
            Button("Reorder Rooms", systemImage: "arrow.up.arrow.down") { withAnimation { reordering = .active } }
        }
        if let link = session.link(to: roomID) {
            Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = link }
        }
        MuteActions(session: session, roomID: roomID, perform: perform)
        if session.server?.has("rooms") == true, session.status == .signedIn {
            if session.joinedRoomIDs.contains(roomID) {
                if !isThread {
                    Section {
                        Button("New Thread", systemImage: "bubble.left.and.text.bubble.right") { naming = NewRoom(parent: roomID) }
                            .disabled(!session.mayWrite)
                    } header: {
                        if !session.mayWrite { Text(ReadOnlyPrompt.reason(session)) }
                    }
                }
                Button("Leave", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { leaving = roomID }
                    .disabled(!session.mayWrite)
            } else {
                Button("Join", systemImage: "plus.circle") { perform { try await session.join(roomID) } }
                    .disabled(!session.mayWrite)
            }
        }
    }

    // MARK: Banner and profile

    private var bannerView: AnyView? {
        if let problem {
            return AnyView(ActionBanner(symbol: "exclamationmark.triangle", title: problem, tone: Palette.danger) {
                Button("Dismiss", systemImage: "xmark") { self.problem = nil }.labelStyle(.iconOnly).buttonStyle(GhostButtonStyle())
            })
        }
        switch session.status {
        case .signedOut where session.passkeyHold, .stopped(.signedOut) where session.passkeyHold:
            // apron-web's held session: the account signs back in with one tap.
            return AnyView(ActionBanner(symbol: "person.badge.key", title: "Sign in with your passkey to continue.",
                                        detail: session.signInNeeded) {
                Button("Sign In") {
                    perform { try await session.usePasskey(.login, with: PlatformPasskeys()) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Sign in with passkey")
            })
        case .signedOut where session.server != nil, .stopped(.signedOut) where session.server != nil:
            return AnyView(ActionBanner(symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in to \(session.serverName)",
                                        detail: session.signInNeeded) {
                Button("Sign In", action: onSignIn).buttonStyle(PrimaryButtonStyle())
            })
        case .signedIn where session.server?.versionWarning != nil && versionWarningSeen != session.server?.apron:
            // §3.1: a server on a version Ladle doesn't read is said once a launch, then the
            // server pane keeps saying it.
            return AnyView(ActionBanner(symbol: "exclamationmark.triangle", title: "Some features may not work",
                                        detail: session.server?.versionWarning, tone: Palette.warn) {
                Button("Dismiss", systemImage: "xmark") { versionWarningSeen = session.server?.apron }
                    .labelStyle(.iconOnly).buttonStyle(GhostButtonStyle())
            })
        default:
            // A short drop's way back says so only in your own dot, as on the web.
            guard !session.reconnectingQuietly, let state = ConnectionState(session.status) else { return nil }
            if state.isProblem {
                return AnyView(ActionBanner(symbol: state.symbol, title: state.title(session.record), detail: state.detail) {
                    if state.canRetry { Button("Try Now") { session.start() }.buttonStyle(GhostButtonStyle(tone: Palette.accent)) }
                })
            }
            return AnyView(Label(state.title(session.record), systemImage: state.symbol)
                .apText(.sm, .semibold).foregroundStyle(Palette.inkMuted))
        }
    }

    /// The web's ProfileBar: you, your status in words (else your `@user_id`), and the gear that
    /// opens Preferences at Profile, for this server.
    @ViewBuilder
    private var profileBar: some View {
        if let you = session.you {
            let name = session.displayName(for: you)
            let line = heldAwayWords ?? session.profileLine
            let away = heldAwayWords ?? session.ownPresenceWords
            let presence = heldAwayWords != nil ? .unknown : session.ownPresence
            Button { openPreferences(.profile, server: session.record.id) } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Avatar(name: name, userID: you.userID, presence: presence, image: session.avatarURL(of: you.userID))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).apText(.ui, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
                        if let paused = session.pausedLine {
                            Label(paused, systemImage: "bell.slash")
                                .labelStyle(TightLabel())
                                .apText(.sm).foregroundStyle(Palette.warn).lineLimit(1)
                        } else if let note = session.profileNote {
                            Text(note).apText(.sm, .medium).foregroundStyle(Palette.accent).lineLimit(1)
                        } else if let line {
                            Text(line).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape").foregroundStyle(Palette.inkMuted)
                        .overlay(alignment: .bottomTrailing) {
                            if session.pause != nil {
                                Image(systemName: "bell.slash.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Palette.warn)
                                    .padding(2)
                                    .background(Palette.timeline, in: Circle())
                                    .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
                                    .offset(x: 5, y: 5)
                            }
                        }
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
                .frame(minHeight: Tokens.Size.touchTarget + Tokens.Space.s2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Palette.chrome)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
            .accessibilityLabel(profileLabel(name: name, away: away))
            .accessibilityHint("Opens your profile and status")
        }
    }

    private func profileLabel(name: String, away: String?) -> String {
        let paused = session.pausedLine.map { "Notifications \($0.lowercased()). " } ?? ""
        let status = (away ?? Presence.words(session.chosenStatus, yours: true)).map { ", \($0)" } ?? ""
        let note = session.profileNote.map { ". \($0)" } ?? ""
        return paused + "Your profile on \(session.serverName): \(name)" + status + note
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() } catch { problem = errorText(error) }
        }
    }
}

/// The web's RoomItem and ThreadItem.
struct RoomRow: View {
    let session: ServerSession
    let roomID: String
    let isThread: Bool
    let isSelected: Bool
    /// What a thread you have not joined counts its last activity from.
    var now = Date()
    /// Room at the row's end for the open room's "…", drawn over it.
    var trailingSpace: CGFloat = 0

    /// Where a thread's text starts, right of the guide line.
    static let threadInset = Tokens.Space.s3 + Tokens.Space.s4 + Tokens.Space.s2

    var body: some View {
        let unread = session.unreadCount(in: roomID)
        let mentions = session.mentionCount(in: roomID)
        let joined = session.joinedRoomIDs.contains(roomID)
        let muted = session.mute(of: roomID) != nil
        // A muted room's news stays quiet: no bold name, a quiet count (the web's RoomItem).
        let strong = isSelected || (unread > 0 && !muted)
        // A private room's row leads with who it is with; the Private heading says it is private.
        let faced = !isThread && session.isPrivateRoom(roomID)
        HStack(alignment: isThread ? .top : .center, spacing: Tokens.Space.s2) {
            if faced { Faces(session: session, people: session.faces(of: roomID)) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Tokens.Space.s1) {
                    Text(session.title(of: roomID))
                        .apText(.body, strong ? .semibold : (isThread ? .medium : .regular))
                        .foregroundStyle(strong || isThread ? Palette.ink : Palette.inkMuted)
                        .lineLimit(1)
                    if session.isPrivate(roomID), !faced { Lock() }
                }
                if !isThread, let topic = session.roomDescription(roomID) {
                    EmojiText(text: descriptionText(topic, session.emojiCatalog), catalog: session.emojiCatalog, role: .sm)
                        .apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
                }
                if isThread {
                    if let description = session.roomDescription(roomID) {
                        line(icon: "text.alignleft") {
                            EmojiText(text: descriptionText(description, session.emojiCatalog), catalog: session.emojiCatalog, role: .sm)
                        }
                    }
                    if let last = session.timeline(roomID).last {
                        line(icon: "arrow.turn.down.right") {
                            let sender = Text(TextDirection.isolated(session.displayName(for: last.from))).fontWeight(.medium).foregroundStyle(Palette.ink)
                            let text = Text(previewText(last.body)).foregroundStyle(unread > 0 ? Palette.ink : Palette.inkMuted)
                            Text("\(sender) \(text)")
                        }
                    }
                }
            }
            Spacer(minLength: Tokens.Space.s2)
            if muted { MutedBell() }
            if mentions > 0 {
                UnreadCount(count: mentions, mentions: true, quiet: muted)
            } else if unread > 0 {
                UnreadCount(count: unread, quiet: muted)
            } else if !joined, isThread, let active = session.lastActive(of: roomID) {
                // When it was last active, as the web's Other Threads rows say it.
                Text(LastActive.words(active, now: now)).apText(.sm).monospacedDigit().foregroundStyle(Palette.inkMuted)
            } else if !joined {
                Text("Not joined").apText(.sm).foregroundStyle(Palette.inkMuted)
            }
        }
        .padding(.vertical, isThread ? Tokens.Space.s1_5 : Tokens.Space.s2)
        .padding(.trailing, Tokens.Space.s3 + trailingSpace)
        .padding(.leading, isThread ? Self.threadInset : Tokens.Space.s3)
        .frame(minHeight: Tokens.Size.touchTarget)
        .background(isSelected ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                if isThread { Rectangle().fill(Palette.line).frame(width: 1).padding(.leading, 21 - 1) }
                if isSelected {
                    Capsule().fill(Palette.accent).frame(width: 3)
                        .padding(.vertical, Tokens.Space.s1_5)
                        .padding(.leading, isThread ? 21 - 1 : Tokens.Space.s1)
                }
            }
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(unread: unread, mentions: mentions, joined: joined, muted: muted))
        .task(id: session.server?.emojiCatalogURL) { await session.loadEmojiCatalog(for: session.roomDescription(roomID)) }
    }

    private func line(icon: String, @ViewBuilder _ text: () -> some View) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            Image(systemName: icon).imageScale(.small)
            text().lineLimit(1)
        }
        .apText(.sm)
        .foregroundStyle(Palette.inkMuted)
    }

    private func accessibilityText(unread: Int, mentions: Int, joined: Bool, muted: Bool) -> String {
        var parts = [session.title(of: roomID)]
        if isThread {
            parts.append("thread in \(session.store.room(roomID)?.parentRoomID.map(session.title(of:)) ?? "a room")")
        }
        if session.isPrivate(roomID) { parts.append("private") }
        if muted { parts.append("muted") }
        if mentions > 0 { parts.append("\(mentions) \(mentions == 1 ? "mention" : "mentions") of you") }
        if unread > 0 { parts.append("\(unread) new") }
        if !joined { parts.append("not joined") }
        if !joined, isThread, let active = session.lastActive(of: roomID) {
            parts.append("last active \(active.formatted(.relative(presentation: .named)))")
        }
        if isThread, let description = session.roomDescription(roomID) { parts.append(EmojiKeys.spoken(description, catalog: session.emojiCatalog)) }
        return parts.joined(separator: ", ")
    }
}

/// The web's FoldHeading over a room's threads ("Other Threads · 4") or a member list section
/// ("Offline · 1"), which folds them away.
struct FoldHeading: View {
    let label: String
    let count: Int
    @Binding var open: Bool
    var inset: CGFloat = RoomRow.threadInset

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Tokens.Space.s1) {
                Text("\(label) · \(count)").apText(.caps, .semibold).textCase(.uppercase)
                Image(systemName: "chevron.right").imageScale(.small).rotationEffect(.degrees(open ? 90 : 0))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.inkMuted)
            .padding(.leading, inset)
            .frame(minHeight: Tokens.Size.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.Space.s2, bottom: 0, trailing: Tokens.Space.s2))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel("\(label), \(count)")
        .accessibilityValue(open ? "Shown" : "Folded")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The web's FoldPill: the … of a list folded to what has news, which says it is cut short and
/// shows it all.
struct FoldPill: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .imageScale(.small)
                .foregroundStyle(Palette.inkMuted)
                .padding(.horizontal, Tokens.Space.s2)
                .padding(.vertical, Tokens.Space.s1)
                .background(Palette.raised, in: Capsule())
                .touchTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The web's SidebarSection head: its title folds the section to its rooms with news, and the
/// FoldPill after it shows them all again; `trailing` is its +.
struct SectionFoldHead<Trailing: View>: View {
    let title: String
    @Binding var folded: Bool
    var canFold = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            Button { withAnimation { folded.toggle() } } label: {
                SectionHead(title: title).frame(minHeight: Tokens.Size.touchTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canFold)
            .accessibilityValue(folded ? "Folded to rooms with news" : "Shown")
            .accessibilityHint(folded ? "Shows every room" : "Folds to rooms with news")
            if folded, canFold {
                FoldPill(label: "Show all \(title)") { withAnimation { folded = false } }
            }
            Spacer()
            trailing()
        }
        .textCase(nil)
    }
}

extension EnvironmentValues {
    /// The time the rooms list counts "4d" and Inactive from; the renderer pins it, so its shots
    /// read the same every run. The app never sets it.
    @Entry var fixedNow: Date?
}

/// The visible rooms the user has not joined, from `room_list`, as the web's Other Rooms: each
/// with its description and member count. A tap opens it to read before joining, and Join
/// joins it from here.
struct BrowseRoomsView: View {
    let session: ServerSession
    /// Opens a room, read without joining until Join.
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var roomIDs: [String]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).apText(.ui).foregroundStyle(Palette.danger) }
                ForEach(roomIDs ?? [], id: \.self) { roomID in
                    HStack(spacing: Tokens.Space.s2) {
                        Button {
                            dismiss()
                            open(roomID)
                        } label: {
                            listing(roomID)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens it to read before joining")
                        if session.joinedRoomIDs.contains(roomID) {
                            Label("Joined", systemImage: "checkmark").apText(.sm).foregroundStyle(Palette.inkMuted)
                        } else if session.mayWrite {
                            Button("Join") {
                                Task {
                                    do { try await session.join(roomID) } catch { self.error = errorText(error) }
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityLabel("Join \(session.title(of: roomID))")
                        }
                    }
                    .listRowBackground(Palette.chrome)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .overlay {
                if roomIDs == nil {
                    ProgressView()
                } else if roomIDs?.isEmpty == true {
                    EmptyState(title: "No other rooms", detail: "You are in every room you can see on \(session.serverName).") { EmptyView() }
                }
            }
            .navigationTitle("Browse Rooms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task {
                do { roomIDs = try await session.listUnjoinedRooms() } catch {
                    roomIDs = []
                    self.error = errorText(error)
                }
            }
        }
    }
}

extension BrowseRoomsView {
    /// A listing's title, description and "3 members", as the web's Other Rooms row.
    private func listing(_ roomID: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Tokens.Space.s1) {
                Text(session.title(of: roomID)).apText(.body, .medium).foregroundStyle(Palette.ink).lineLimit(1)
                if session.isPrivate(roomID) { Lock() }
            }
            if let description = session.roomDescription(roomID) {
                EmojiText(text: descriptionText(description, session.emojiCatalog), catalog: session.emojiCatalog, role: .sm)
                    .apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(2)
            }
            if let members = session.memberTotal(roomID), members > 0 {
                Text(members == 1 ? "1 member" : "\(members) members").apText(.sm).monospacedDigit().foregroundStyle(Palette.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchTarget, alignment: .leading)
        .padding(.vertical, Tokens.Space.s1)
        .contentShape(Rectangle())
    }
}

/// Search Rooms where the list has no navigation bar to put `.searchable` in: the iPad sidebar.
struct RoomSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.inkMuted)
            TextField("Search Rooms", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Palette.inkMuted)
            }
        }
        .apText(.ui)
        .padding(.horizontal, Tokens.Space.s3)
        .frame(minHeight: Tokens.Size.touchTarget)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
    }
}
