import ApronKit
import SwiftUI

/// One server's joined rooms, with each room's threads under it.
struct RoomListView: View {
    let session: ServerSession
    @State private var signingIn = false
    @State private var browsing = false
    @State private var naming: NewRoom?
    @State private var newTitle = ""
    @State private var error: String?
    @Environment(\.theme) private var theme

    /// A room to create: top level, or a thread under `parent`.
    struct NewRoom: Identifiable {
        var parent: String?
        var id: String { parent ?? "" }
    }

    var body: some View {
        List {
            switch session.status {
            case .signedIn:
                EmptyView()
            case .offline, .stopped:
                Section {
                    Button("Reconnect") { session.start() }
                }
            default:
                Section {
                    Button("Sign In") { signingIn = true }
                        .disabled(session.server == nil)
                }
            }
            ForEach(session.roomTree) { node in
                Section {
                    NavigationLink(value: node.roomID) { RoomRow(session: session, roomID: node.roomID, isThread: false) }
                        .contextMenu { roomActions(node.roomID, isThread: false) }
                    ForEach(node.threadIDs, id: \.self) { threadID in
                        NavigationLink(value: threadID) {
                            RoomRow(session: session, roomID: threadID, isThread: true)
                        }
                        .contextMenu { roomActions(threadID, isThread: true) }
                    }
                }
                .listRowBackground(theme.layout == .bubbles ? theme.palette.surface.color : theme.palette.background.color)
                .listRowSeparatorTint(theme.palette.separator.color)
            }
        }
        .modifier(ThemedList())
        .navigationTitle(session.record.label)
        .navigationDestination(for: String.self) { roomID in TimelineView(session: session, roomID: roomID) }
        .toolbar {
            if session.status == .signedIn {
                Menu("More", systemImage: "ellipsis.circle") {
                    if session.server?.has("rooms") == true {
                        Button("New Room", systemImage: "plus") { naming = NewRoom(parent: nil) }
                        Button("Browse Rooms", systemImage: "magnifyingglass") { browsing = true }
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await session.signOut() }
                    }
                }
            }
        }
        .sheet(isPresented: $signingIn) { SignInView(session: session) }
        .sheet(isPresented: $browsing) { BrowseRoomsView(session: session) }
        .alert(naming?.parent == nil ? "New Room" : "New Thread", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Create") {
                let parent = naming?.parent
                let title = newTitle
                newTitle = ""
                perform { try await session.createRoom(title: title, parentRoomID: parent) }
            }
            Button("Cancel", role: .cancel) { newTitle = "" }
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
        .onAppear {
            if session.status == .signedOut { signingIn = true }
        }
    }

    @ViewBuilder
    private func roomActions(_ roomID: String, isThread: Bool) -> some View {
        if session.joinedRoomIDs.contains(roomID) {
            if !isThread {
                Button("New Thread", systemImage: "bubble.left.and.text.bubble.right") { naming = NewRoom(parent: roomID) }
            }
            Button("Leave", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                perform { try await session.leave(roomID) }
            }
        } else {
            Button("Join", systemImage: "plus.circle") { perform { try await session.join(roomID) } }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() } catch { self.error = errorText(error) }
        }
    }
}

/// A room or thread: its title, the latest message, and how many messages are new. Unread rooms
/// are also set in bold, so the state never rests on the badge color alone.
private struct RoomRow: View {
    let session: ServerSession
    let roomID: String
    let isThread: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let palette = theme.palette
        let unread = session.unreadCount(in: roomID)
        let last = session.lastMessage(in: roomID)
        let dense = theme.layout == .dense
        HStack(alignment: dense ? .center : .top, spacing: 10) {
            Image(systemName: isThread ? "arrow.turn.down.right" : "number")
                .font(theme.font(dense ? .footnote : .body, weight: .semibold))
                .foregroundStyle(isThread ? palette.secondary.color : palette.accent.color)
                .frame(width: 22)
                .padding(.leading, isThread && !dense ? 16 : 0)
                .accessibilityLabel(isThread ? "Thread" : "Room")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title(of: roomID))
                    .font(theme.font(dense ? .callout : .headline, theme.titleFace, weight: unread > 0 ? .bold : (dense ? .regular : .medium)))
                    .foregroundStyle(palette.text.color)
                if let last {
                    Text("\(Text(last.from.userID == session.you?.userID ? "You" : session.displayName(for: last.from)).fontWeight(.semibold)): \(Text(rendered(last.body)))")
                        .font(theme.font(dense ? .footnote : .subheadline))
                        .foregroundStyle(palette.secondary.color)
                        .lineLimit(theme.layout == .log ? 2 : 1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let last, !dense {
                    Text(last.date, format: .dateTime.hour().minute())
                        .font(theme.font(.caption, theme.metaFace).monospacedDigit())
                        .foregroundStyle(unread > 0 ? palette.accent.color : palette.secondary.color)
                }
                if unread > 0 {
                    UnreadBadge(count: unread)
                } else if !session.joinedRoomIDs.contains(roomID) {
                    Text("Not joined")
                        .font(theme.font(.caption))
                        .foregroundStyle(palette.secondary.color)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// The direction's list style and background, shared by the server and room lists.
struct ThemedList: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let styled = content
            .scrollContentBackground(.hidden)
            .background(theme.palette.background.color)
            .environment(\.defaultMinListRowHeight, 44)
        switch theme.layout {
        case .bubbles: styled.listStyle(.insetGrouped)
        case .log: styled.listStyle(.plain)
        case .dense: styled.listStyle(.plain).listSectionSpacing(0)
        }
    }
}

/// The visible rooms the user has not joined, from `room_list`.
private struct BrowseRoomsView: View {
    let session: ServerSession
    @Environment(\.dismiss) private var dismiss
    @State private var roomIDs: [String]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(roomIDs ?? [], id: \.self) { roomID in
                    HStack {
                        Text(session.title(of: roomID))
                        Spacer()
                        if session.joinedRoomIDs.contains(roomID) {
                            Image(systemName: "checkmark").foregroundStyle(.secondary)
                        } else {
                            Button("Join") {
                                Task {
                                    do { try await session.join(roomID) } catch { self.error = errorText(error) }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .overlay {
                if roomIDs == nil { ProgressView() } else if roomIDs?.isEmpty == true {
                    ContentUnavailableView("No Other Rooms", systemImage: "bubble.left.and.bubble.right")
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
