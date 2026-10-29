import ApronKit
import Network
import SwiftUI

/// The web's layouts, by size class. Compact (the web under 720 px) shows one pane at a time:
/// servers, then a server's rooms, then a room. Regular (the web at 960 px and wider) is a split
/// view: the server rail and the rooms in the sidebar, the room beside them, and its members in
/// a column of their own. The open server and room survive a relaunch (`@SceneStorage`), and
/// `apron:` links open them.
struct RootView: View {
    let store: SessionStore
    var loadError: String?
    @SceneStorage("server") private var serverID: String?
    @SceneStorage("room") private var roomID: String?
    @State private var path: [Route] = []
    @State private var connecting: ConnectRequest?
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
                if request.record == nil { open(id, room: request.room) }
            }
        }
        .environment(\.requestSignIn, SignInAction { connecting = ConnectRequest(record: $0) })
        .onOpenURL(perform: handle)
        .environment(\.openURL, OpenURLAction { url in
            guard DeepLink(url) != nil else { return .systemAction }
            handle(url)
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
        .onChange(of: store.records.count, initial: true) { restore() }
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
                                .onAppear { serverID = id.uuidString; roomID = nil }
                        }
                    case .room(let id, let room):
                        if let session = store.session(for: id) {
                            TimelineView(session: session, roomID: room)
                                .environment(\.openRoom, OpenRoomAction { path.append(.room(id, $0)) })
                                .onAppear { serverID = id.uuidString; roomID = room }
                        }
                    }
                }
        }
    }

    // MARK: iPad

    private var split: some View {
        SplitLayout(store: store, serverID: $serverID, roomID: $roomID, connecting: $connecting)
    }

    private var selectedServer: UUID? { SplitLayout.server(serverID, in: store) }

    /// Rebuilds the iPhone path from the saved selection once the servers have loaded.
    private func restore() {
        guard !restored, let id = serverID.flatMap(UUID.init(uuidString:)), store.session(for: id) != nil else { return }
        restored = true
        path = [.server(id)] + (roomID.map { [.room(id, $0)] } ?? [])
    }

    // MARK: Links (§A.4)

    private func handle(_ url: URL) {
        guard let link = DeepLink(url) else { return }
        guard let server = link.server else {
            if let room = link.room, let id = selectedServer { open(id, room: room) }
            return
        }
        if let record = store.records.first(where: { $0.url == server }) {
            open(record.id, room: link.room)
        } else {
            connecting = ConnectRequest(prefill: TokenPayload(token: link.token ?? "", server: server), room: link.room)
        }
    }

    private func open(_ id: UUID, room: String?) {
        serverID = id.uuidString
        roomID = room
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

/// An Apron link (§A.4): `apron:?server=…&room=…`, or `https://link.apron.chat/#…`. A token
/// in an `apron:` link is ignored, since any app can send one; one in an `https` link that you
/// tapped prefills the sign-in, which still waits for you.
struct DeepLink {
    var server: URL?
    var room: String?
    var token: String?

    init?(_ url: URL) {
        let text = url.absoluteString
        let query: String
        if text.hasPrefix("apron:?") {
            query = String(text.dropFirst("apron:?".count))
        } else if url.scheme == "https", url.host() == "link.apron.chat", let fragment = url.fragment(percentEncoded: true) {
            query = fragment
        } else {
            return nil
        }
        var components = URLComponents()
        components.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%20")
        let items = components.queryItems ?? []
        server = items.first { $0.name == "server" }?.value.flatMap(URL.init(string:))
        room = items.first { $0.name == "room" }?.value
        token = text.hasPrefix("apron:") ? nil : items.first { $0.name == "token" }?.value
    }
}

/// The regular-width layout: the rail and rooms in the sidebar, the room in the detail, and its
/// members in the inspector column.
struct SplitLayout: View {
    let store: SessionStore
    @Binding var serverID: String?
    @Binding var roomID: String?
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
                    TimelineView(session: session, roomID: roomID, showingMembers: true)
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
