import ApronKit
import Network
import SwiftUI

/// The web's layouts, by size class. Compact (the web under 720 px) shows one pane at a time:
/// servers, then a server's rooms, then a room. Regular (the web at 960 px and wider) is a split
/// view: the server rail and the rooms in the sidebar, the room beside them, and its members in
/// a column of their own. The open server and room survive a relaunch (`@SceneStorage`), and
/// Apron links open them (`ApronLink`), with the message or member a link names.
struct RootView: View {
    let store: SessionStore
    var loadError: String?
    @SceneStorage("server") private var serverID: String?
    @SceneStorage("room") private var roomID: String?
    @State private var path: [Route] = []
    @State private var connecting: ConnectRequest?
    /// A link's message or member, for the room it opens to show.
    @State private var place: ApronLink?
    @State private var restored = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    enum Route: Hashable {
        case server(UUID)
        case room(UUID, String)
    }

    var body: some View {
        Group {
            if sizeClass == .compact { stack } else { split }
        }
        .background(Palette.chrome)
        .apronStyle()
        .sheet(item: $connecting) { request in
            ConnectView(store: store, record: request.record, prefill: request.prefill) { id in
                if request.record == nil { show(id, request.place) }
            }
        }
        .environment(\.requestSignIn, SignInAction { connecting = ConnectRequest(record: $0) })
        .environment(\.liveSessions, SessionLookup(store.liveSession(for:)))
        .onOpenURL { url in ApronLink(url).map(open) }
        .environment(\.openURL, OpenURLAction { url in
            guard let link = ApronLink(url) else { return .systemAction }
            open(link)
            return .handled
        })
        .onChange(of: scenePhase) { _, phase in
            for record in store.records {
                guard let session = store.session(for: record.id) else { continue }
                switch phase {
                case .background: Task { await session.stop() }
                case .active: session.start()
                default: break
                }
            }
        }
        .task { await watchNetwork() }
        .onChange(of: store.records.count, initial: true) {
            restore()
            openReminder()
        }
        .onChange(of: ReminderRoutes.shared.opened) { openReminder() }
    }

    // MARK: iPhone

    private var stack: some View {
        NavigationStack(path: $path) {
            ServerListView(store: store, loadError: loadError, open: { path = [.server($0)] }, connecting: $connecting)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .server(let id):
                        if let session = store.session(for: id) {
                            RoomListView(session: session, open: { path.append(.room(id, $0)) },
                                         onSignIn: { connecting = ConnectRequest(record: session.record) })
                                .resolvingLinks(from: session)
                                .onAppear { serverID = id.uuidString; roomID = nil }
                        }
                    case .room(let id, let room):
                        if let session = store.session(for: id) {
                            TimelineView(session: session, roomID: room, reminders: store.reminders, place: $place)
                                .resolvingLinks(from: session)
                                .environment(\.openRoom, OpenRoomAction { path.append(.room(id, $0)) })
                                .onAppear { serverID = id.uuidString; roomID = room }
                        }
                    }
                }
        }
    }

    // MARK: iPad

    private var split: some View {
        SplitLayout(store: store, serverID: $serverID, roomID: $roomID, place: $place, connecting: $connecting)
    }

    /// Rebuilds the iPhone path from the saved selection once the servers have loaded.
    private func restore() {
        guard !restored, let id = serverID.flatMap(UUID.init(uuidString:)), store.session(for: id) != nil else { return }
        restored = true
        path = [.server(id)] + (roomID.map { [.room(id, $0)] } ?? [])
    }

    // MARK: Links (link.apron.chat SPEC)

    /// Opens a link's place on a saved server, or that server's sign-in sheet for a sign-in link,
    /// or offers to add the server, which waits for you. A relative link here has no server that sent it (`resolvingLinks` resolves those in
    /// a server's own content), so it opens nothing.
    private func open(_ link: ApronLink) {
        guard let server = link.server else { return }
        if let record = store.records.first(where: { $0.url == server }) {
            // A sign-in link opens the server's sign-in sheet with its token filled in; it never
            // signs in by itself (link.apron.chat SPEC §6).
            if let token = link.token {
                connecting = ConnectRequest(record: record, prefill: TokenPayload(token: token, server: server))
            } else {
                show(record.id, link)
            }
        } else {
            connecting = ConnectRequest(prefill: TokenPayload(token: link.token ?? "", server: server), place: link)
        }
    }

    /// A tapped reminder's message, once its server has loaded: revealed and highlighted, as a link to it.
    private func openReminder() {
        guard let key = ReminderRoutes.shared.opened, let record = store.records.first(where: { $0.id == key.server }) else { return }
        ReminderRoutes.shared.opened = nil
        restored = true
        show(record.id, ApronLink(server: record.url, room: key.roomID, message: key.messageID))
    }

    private func show(_ id: UUID, _ link: ApronLink?) {
        let room = link?.room
        serverID = id.uuidString
        roomID = room
        place = room == nil ? nil : link
        path = [.server(id)] + (room.map { [.room(id, $0)] } ?? [])
    }

    /// Reconnects every session when the network comes back, rather than waiting out a backoff.
    private func watchNetwork() async {
        let monitor = NWPathMonitor()
        let paths = AsyncStream<NWPath.Status> { continuation in
            monitor.pathUpdateHandler = { continuation.yield($0.status) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "ladle.network"))
        }
        var previous: NWPath.Status?
        for await status in paths {
            if status == .satisfied, previous == .unsatisfied {
                for record in store.records { store.session(for: record.id)?.start() }
            }
            previous = status
        }
    }
}

extension View {
    /// Resolves a relative link in this server's content against the server (§5), not the one
    /// on screen, and hands every link up as its absolute web form.
    func resolvingLinks(from session: ServerSession) -> some View {
        modifier(ResolvingLinks(server: session.record.url))
    }
}

private struct ResolvingLinks: ViewModifier {
    let server: URL
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            openURL(ApronLink.outbound(url, from: server))
            return .handled
        })
    }
}

/// The regular-width layout: the rail and rooms in the sidebar, the room in the detail, and its
/// members in the inspector column.
struct SplitLayout: View {
    let store: SessionStore
    @Binding var serverID: String?
    @Binding var roomID: String?
    @Binding var place: ApronLink?
    @Binding var connecting: ConnectRequest?

    var body: some View {
        let selected = Self.server(serverID, in: store)
        let session = selected.flatMap(store.session(for:))
        NavigationSplitView {
            HStack(spacing: 0) {
                ServerRail(store: store, selected: selected, open: { serverID = $0.uuidString; roomID = nil }, connecting: $connecting)
                if let session {
                    NavigationStack {
                        RoomListView(session: session, selected: roomID, open: { roomID = $0 },
                                     onSignIn: { connecting = ConnectRequest(record: session.record) })
                            .resolvingLinks(from: session)
                    }
                } else {
                    NoServers(connecting: $connecting).background(Palette.chrome)
                }
            }
            .navigationSplitViewColumnWidth(Tokens.Size.railW + Tokens.Size.sidebarW + Tokens.Space.s8)
            .toolbar(removing: .sidebarToggle)
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            NavigationStack {
                if let session, let roomID {
                    TimelineView(session: session, roomID: roomID, reminders: store.reminders, place: $place, showingMembers: true)
                        .resolvingLinks(from: session)
                        .id(roomID)
                        .environment(\.openRoom, OpenRoomAction { self.roomID = $0 })
                } else {
                    EmptyState(title: "No room open", detail: "Pick a room from the list.") { EmptyView() }
                        .background(Palette.timeline)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    static func server(_ id: String?, in store: SessionStore) -> UUID? {
        id.flatMap(UUID.init(uuidString:)).flatMap { id in store.records.contains { $0.id == id } ? id : nil }
            ?? store.records.first?.id
    }
}
