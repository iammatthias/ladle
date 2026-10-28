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

    /// A room to create: top level, or a thread under `parent`.
    struct NewRoom: Identifiable {
        var parent: String?
        var id: String { parent ?? "" }
    }

    var body: some View {
        List {
            if session.status != .signedIn {
                Section {
                    Button("Sign In") { signingIn = true }
                        .disabled(session.server == nil)
                }
            }
            ForEach(session.roomTree) { node in
                Section {
                    NavigationLink(value: node.roomID) { RoomRow(session: session, roomID: node.roomID) }
                        .contextMenu { roomActions(node.roomID, isThread: false) }
                    ForEach(node.threadIDs, id: \.self) { threadID in
                        NavigationLink(value: threadID) {
                            RoomRow(session: session, roomID: threadID)
                                .padding(.leading)
                        }
                        .contextMenu { roomActions(threadID, isThread: true) }
                    }
                }
            }
        }
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

private struct RoomRow: View {
    let session: ServerSession
    let roomID: String

    var body: some View {
        HStack {
            Text(session.title(of: roomID))
            Spacer()
            if !session.joinedRoomIDs.contains(roomID) {
                Text("Not joined")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
