import ApronKit
import SwiftUI

struct ServerListView: View {
    let store: SessionStore
    @State private var editing: ServerRecord?
    @State private var adding = false
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.records) { record in
                    if let session = store.session(for: record.id) {
                        NavigationLink(value: record.id) {
                            ServerRow(session: session)
                        }
                        .listRowBackground(theme.layout == .bubbles ? theme.palette.surface.color : theme.palette.background.color)
                        .listRowSeparatorTint(theme.palette.separator.color)
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await store.remove(record.id) } }
                            Button("Edit") { editing = record }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = record }
                            Button("Remove", systemImage: "trash", role: .destructive) { Task { await store.remove(record.id) } }
                        }
                    }
                }
            }
            .modifier(ThemedList())
            .overlay {
                if store.records.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers", systemImage: "server.rack")
                    } description: {
                        Text("Add an Apron server by its WebSocket address.")
                    } actions: {
                        Button("Add Server") { adding = true }
                    }
                }
            }
            .navigationTitle("Servers")
            .navigationDestination(for: UUID.self) { id in
                if let session = store.session(for: id) { RoomListView(session: session) }
            }
            .toolbar {
                Button("Add Server", systemImage: "plus") { adding = true }
                #if DEBUG
                DirectionPicker()
                #endif
            }
            .sheet(isPresented: $adding) {
                ServerEditorView(record: nil) { store.add($0) }
            }
            .sheet(item: $editing) { record in
                ServerEditorView(record: record) { updated in Task { await store.update(updated) } }
            }
        }
    }
}

/// A server: its name, who you are there, the connection state as a symbol and words, and the
/// new messages across its rooms.
private struct ServerRow: View {
    let session: ServerSession
    @Environment(\.theme) private var theme

    var body: some View {
        let palette = theme.palette
        let unread = session.joinedRoomIDs.reduce(0) { $0 + session.unreadCount(in: $1) }
        HStack(spacing: 12) {
            Text(String(session.record.label.prefix(1)))
                .font(theme.font(.title3, theme.titleFace, weight: .bold))
                .foregroundStyle(palette.onAccent.color)
                .frame(width: 44, height: 44)
                .background(palette.accent.color, in: RoundedRectangle(cornerRadius: theme.layout == .dense ? 8 : 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.record.label)
                    .font(theme.font(.headline, theme.titleFace, weight: unread > 0 ? .bold : .semibold))
                    .foregroundStyle(palette.text.color)
                Label(statusText, systemImage: statusSymbol)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(palette.secondary.color)
                Text(session.record.url.host() ?? "")
                    .font(theme.font(.caption, theme.metaFace))
                    .foregroundStyle(palette.secondary.color)
            }
            Spacer(minLength: 8)
            if unread > 0 { UnreadBadge(count: unread) }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch session.status {
        case .signedIn: "checkmark.circle"
        case .connecting, .signingIn, .reconnecting: "arrow.triangle.2.circlepath"
        case .signedOut: "person.crop.circle.badge.questionmark"
        case .offline: "wifi.slash"
        case .stopped: "exclamationmark.triangle"
        }
    }

    private var statusText: String {
        switch session.status {
        case .offline: "Offline"
        case .connecting: "Connecting…"
        case .signedOut: "Not signed in"
        case .signingIn: "Signing in…"
        case .signedIn: "Signed in as " + (session.you.map(session.displayName(for:)) ?? "")
        case .reconnecting(_, let delay): "Reconnecting in \(Int(delay.components.seconds) + 1) s"
        case .stopped(.denied(let message)): "Refused: \(message)"
        case .stopped(.rejected(let status)): "Connection refused (HTTP \(status)). Check the origin."
        }
    }
}

#if DEBUG
/// Debug builds only: switches between the design directions under review.
private struct DirectionPicker: View {
    @AppStorage("debug.direction") private var direction = Direction.mise

    var body: some View {
        Menu("Design Direction", systemImage: "paintpalette") {
            Picker("Design Direction", selection: $direction) {
                ForEach(Direction.allCases) { Text($0.name).tag($0) }
            }
        }
    }
}
#endif
