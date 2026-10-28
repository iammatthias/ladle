import ApronKit
import SwiftUI

struct ServerListView: View {
    let store: SessionStore
    @State private var editing: ServerRecord?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.records) { record in
                    if let session = store.session(for: record.id) {
                        NavigationLink(value: record.id) {
                            ServerRow(session: session)
                        }
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

private struct ServerRow: View {
    let session: ServerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.record.label)
                .font(.headline)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let server = session.server {
                Text(([server.agent].compactMap { $0 } + ["Sign-in: " + server.auth.joined(separator: ", ")]).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
