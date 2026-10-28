import ApronKit
import SwiftUI

/// The servers, as the web's BackendRail: a tile per server, accent when it is the open one, a pip
/// for unread, a count for mentions. On iPhone it is the first screen, a list of tiles with
/// their names and state. On iPad it is the rail at the left of the sidebar.
struct ServerListView: View {
    let store: SessionStore
    var loadError: String?
    let open: (UUID) -> Void
    @Binding var connecting: ConnectRequest?
    @State private var removing: ServerRecord?

    var body: some View {
        List {
            if let problem = loadError ?? store.saveError {
                Callout(title: loadError != nil ? "Your saved servers could not be read" : "Your server list could not be saved") { Text(problem) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(store.records) { record in
                    if let session = store.session(for: record.id) {
                        Button { open(record.id) } label: { ServerRow(session: session) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions {
                                Button("Remove", systemImage: "trash") { removing = record }.tint(Palette.danger)
                                Button("Edit", systemImage: "pencil") { connecting = ConnectRequest(record: record) }
                            }
                            .contextMenu {
                                Button("Sign In or Edit", systemImage: "pencil") { connecting = ConnectRequest(record: record) }
                                Button("Remove", systemImage: "trash", role: .destructive) { removing = record }
                            }
                    }
                }
            } header: {
                if !store.records.isEmpty { SectionHead(title: "Servers").textCase(nil) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .overlay {
            if store.records.isEmpty { NoServers(connecting: $connecting) }
        }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Add Server", systemImage: "plus") { connecting = ConnectRequest() }
        }
        .removeServerDialog(store: store, removing: $removing)
    }
}

/// One server: its tile, name, who you are there or the connection state, and what is new.
private struct ServerRow: View {
    let session: ServerSession

    var body: some View {
        let unread = session.joinedRoomIDs.reduce(0) { $0 + session.unreadCount(in: $1) }
        let mentions = session.joinedRoomIDs.reduce(0) { $0 + session.mentionCount(in: $1) }
        HStack(spacing: Tokens.Space.s3) {
            RailTile(label: session.record.label, active: false, offline: session.status != .signedIn)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.record.label).apText(.body, unread > 0 ? .semibold : .medium).foregroundStyle(Palette.ink)
                Text(statusText).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
            }
            Spacer(minLength: Tokens.Space.s2)
            if mentions > 0 {
                UnreadCount(count: mentions, mentions: true)
            } else if unread > 0 {
                UnreadCount(count: unread)
            }
        }
        .frame(minHeight: Tokens.Size.touchTarget + Tokens.Space.s2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if session.status == .signedIn {
            return (session.you.map(session.displayName(for:)) ?? "") + " on " + (session.record.url.host() ?? "")
        }
        return ConnectionState(session.status)?.title(session.record) ?? ""
    }
}

/// The web's rail tile: initials on a rounded square that rounds into an accent circle when
/// it is the open server.
struct RailTile: View {
    let label: String
    let active: Bool
    var offline = false

    var body: some View {
        Text(Avatar.initials(label))
            .apText(.ui, .bold)
            .foregroundStyle(active ? Palette.onAccent : Palette.ink)
            .frame(width: Tokens.Size.railTile, height: Tokens.Size.railTile)
            .background(active ? Palette.accent : Palette.raised,
                        in: RoundedRectangle(cornerRadius: active ? Tokens.Size.railTile / 2 : Tokens.Radius.lg, style: .continuous))
            .opacity(offline ? Tokens.Opacity.dim : 1)
            .accessibilityHidden(true)
    }
}

/// The web's BackendRail, for iPad: a column of tiles on the rail ground.
struct ServerRail: View {
    let store: SessionStore
    let selected: UUID?
    let open: (UUID) -> Void
    @Binding var connecting: ConnectRequest?
    @State private var removing: ServerRecord?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: Tokens.Space.s2) {
                ForEach(store.records) { record in
                    if let session = store.session(for: record.id) { tile(record, session) }
                }
                Button { connecting = ConnectRequest() } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Palette.inkMuted)
                        .frame(width: Tokens.Size.railTile, height: Tokens.Size.railTile)
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                            .strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .frame(width: Tokens.Size.railW, height: Tokens.Size.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Server")
            }
            .padding(.vertical, Tokens.Space.s3)
        }
        .frame(width: Tokens.Size.railW)
        .background(Palette.rail)
        .removeServerDialog(store: store, removing: $removing)
    }

    private func tile(_ record: ServerRecord, _ session: ServerSession) -> some View {
        let active = record.id == selected
        let unread = session.joinedRoomIDs.contains { session.unreadCount(in: $0) > 0 }
        let mentions = session.joinedRoomIDs.reduce(0) { $0 + session.mentionCount(in: $1) }
        return Button { open(record.id) } label: {
            RailTile(label: record.label, active: active, offline: session.status != .signedIn)
                .frame(width: Tokens.Size.railW, height: Tokens.Size.touchTarget)
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                        .fill(Palette.ink)
                        .frame(width: 4, height: active ? Tokens.Size.railTile : unread ? 8 : 0)
                }
                .overlay(alignment: .bottomTrailing) {
                    if mentions > 0 { UnreadCount(count: mentions, mentions: true).padding(.trailing, 6).offset(y: 4) }
                }
                .animation(Motion.medium(reduceMotion), value: active)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Sign In or Edit", systemImage: "pencil") { connecting = ConnectRequest(record: record) }
            Button("Remove", systemImage: "trash", role: .destructive) { removing = record }
        }
        .accessibilityLabel([record.label, active ? "open" : nil, mentions > 0 ? "\(mentions) mentions" : unread ? "new messages" : nil,
                             session.status == .signedIn ? nil : ConnectionState(session.status)?.title(record)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The first run: Ladle runs no server, so it points at the Apron project's demo server (in the
/// Add Server sheet) and at hosting your own.
struct NoServers: View {
    @Binding var connecting: ConnectRequest?

    var body: some View {
        EmptyState(title: "No servers yet", detail: "Ladle connects to Apron chat servers. Try the public demo server run by the Apron project, or host your own.") {
            VStack(spacing: Tokens.Space.s1) {
                Button("Add Server") { connecting = ConnectRequest() }.buttonStyle(PrimaryButtonStyle())
                HostYourOwnLink()
            }
        }
    }
}

/// Where the Apron project's own server lives, for running one.
struct HostYourOwnLink: View {
    var body: some View {
        Link(destination: OfficialServer.selfHosting) {
            Label("Host Your Own Server", systemImage: "arrow.up.right")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(GhostButtonStyle(tone: Palette.denim))
        .accessibilityHint("Opens the Apron server project on GitHub")
    }
}

/// What the Connect sheet opens with: a new server, a saved one, or a link's contents. A new
/// server opens once signed in, at the link's room when it named one.
struct ConnectRequest: Identifiable {
    var record: ServerRecord?
    var prefill: TokenPayload?
    var room: String?
    let id = UUID()
}

extension View {
    /// Confirms removing a server, since a token-only account cannot be signed in to again.
    func removeServerDialog(store: SessionStore, removing: Binding<ServerRecord?>) -> some View {
        confirmationDialog(removing.wrappedValue.map { "Remove \($0.label)?" } ?? "", isPresented: Binding(
            get: { removing.wrappedValue != nil }, set: { if !$0 { removing.wrappedValue = nil } }
        ), titleVisibility: .visible, presenting: removing.wrappedValue) { record in
            Button("Remove Server", role: .destructive) { Task { await store.remove(record.id) } }
        } message: { record in
            Text(["guest", "token"].contains(record.account?.scheme ?? "token")
                 ? "Ladle forgets this server and its sign-in. If you signed in with a token or as a guest, you may not get back into this account."
                 : "Ladle forgets this server and its sign-in. You can add it again and sign in with your email.")
        }
    }
}
