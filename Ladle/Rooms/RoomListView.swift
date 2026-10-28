import ApronKit
import PhotosUI
import SwiftUI

/// One server's rooms, as the web's sidebar: a "Rooms" section of rows, threads under their room
/// on a guide line with their description and latest message, and the profile bar at the foot.
/// The open room has a neutral fill and an accent bar; an unread room is set in ink and
/// semibold with its count, and a mention of you is an `@` count. Connection problems and
/// sign-in show as a banner at the top, never an alert or a sheet that opens by itself.
struct RoomListView: View {
    let session: ServerSession
    var selected: String?
    let open: (String) -> Void
    var onSignIn: () -> Void = {}
    @State private var browsing = false
    @State private var naming: NewRoom?
    @State private var newTitle = ""
    @State private var problem: String?
    @State private var leaving: String?
    @State private var signingOut = false
    @State private var pickingAvatar = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var settingAvatar = false

    /// A room to create: top level, or a thread under `parent`.
    struct NewRoom: Identifiable {
        var parent: String?
        var id: String { parent ?? "" }
    }

    var body: some View {
        List {
            if let banner = bannerView { banner.listRowBackground(Color.clear).listRowSeparator(.hidden) }
            Section {
                ForEach(session.roomTree) { node in
                    roomRow(node.roomID, isThread: false)
                    ForEach(node.threadIDs, id: \.self) { roomRow($0, isThread: true) }
                }
            } header: {
                HStack {
                    SectionHead(title: "Rooms")
                    Spacer()
                    if session.status == .signedIn, session.server?.has("rooms") == true {
                        Menu {
                            Button("New Room", systemImage: "plus") { naming = NewRoom(parent: nil) }
                            Button("Browse Rooms", systemImage: "magnifyingglass") { browsing = true }
                        } label: {
                            Image(systemName: "plus").foregroundStyle(Palette.inkMuted).touchTarget()
                        }
                        .accessibilityLabel("Add a room")
                    }
                }
                .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Tokens.Size.touchTarget)
        .background(Palette.chrome)
        .safeAreaInset(edge: .bottom, spacing: 0) { profileBar }
        .navigationTitle(session.record.label)
        .navigationBarTitleDisplayMode(.inline)
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
        .confirmationDialog(leaving.map { "Leave \(session.title(of: $0))?" } ?? "", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                            titleVisibility: .visible, presenting: leaving) { roomID in
            Button("Leave", role: .destructive) { perform { try await session.leave(roomID) } }
        } message: { roomID in
            Text(session.isPrivate(roomID) ? "It is private, so you need an invitation to come back." : "You can join it again from Browse Rooms.")
        }
        .confirmationDialog("Sign out of \(session.record.label)?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
        } message: {
            Text(session.record.account?.scheme == "guest" || session.record.account?.scheme == "token"
                 ? "This account signs in only with its token, which is deleted. You may not get back into it."
                 : "You can sign in again with the same method.")
        }
    }

    // MARK: Rows

    private func roomRow(_ roomID: String, isThread: Bool) -> some View {
        let isSelected = roomID == selected
        return Button { open(roomID) } label: {
            RoomRow(session: session, roomID: roomID, isThread: isThread, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: Tokens.Space.s2, bottom: 1, trailing: Tokens.Space.s2))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions {
            if session.joinedRoomIDs.contains(roomID), session.server?.has("rooms") == true {
                Button("Leave", systemImage: "rectangle.portrait.and.arrow.right") { leaving = roomID }.tint(Palette.danger)
            }
        }
        .contextMenu { roomActions(roomID, isThread: isThread) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func roomActions(_ roomID: String, isThread: Bool) -> some View {
        if session.server?.has("rooms") == true, session.status == .signedIn {
            if session.joinedRoomIDs.contains(roomID) {
                if !isThread {
                    Button("New Thread", systemImage: "bubble.left.and.text.bubble.right") { naming = NewRoom(parent: roomID) }
                }
                Button("Leave", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { leaving = roomID }
            } else {
                Button("Join", systemImage: "plus.circle") { perform { try await session.join(roomID) } }
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
        case .signedOut where session.server != nil:
            return AnyView(ActionBanner(symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in to \(session.record.label)",
                                        detail: session.signInNeeded) {
                Button("Sign In", action: onSignIn).buttonStyle(PrimaryButtonStyle())
            })
        default:
            guard let state = ConnectionState(session.status) else { return nil }
            if state.isProblem {
                return AnyView(ActionBanner(symbol: state.symbol, title: state.title(session.record), detail: state.detail) {
                    if state.canRetry { Button("Try Now") { session.start() }.buttonStyle(GhostButtonStyle(tone: Palette.accent)) }
                })
            }
            return AnyView(Label(state.title(session.record), systemImage: state.symbol)
                .apText(.sm, .semibold).foregroundStyle(Palette.inkMuted))
        }
    }

    /// The web's ProfileBar: you, and the server you are on.
    @ViewBuilder
    private var profileBar: some View {
        if let you = session.you {
            let name = session.displayName(for: you)
            Menu {
                Section(name + " on " + session.record.label) {
                    if session.canSetAvatar {
                        Button("Change Avatar", systemImage: "person.crop.circle") { pickingAvatar = true }
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { signingOut = true }
                }
            } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Avatar(name: name, userID: you.userID, presence: session.presence(of: you.userID) ?? .online, image: session.avatarURL(of: you.userID))
                        .overlay { if settingAvatar { ProgressView().controlSize(.small) } }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).apText(.ui, .semibold).foregroundStyle(Palette.ink)
                        Text("on \(session.record.label)").apText(.sm).foregroundStyle(Palette.inkMuted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
                .frame(minHeight: Tokens.Size.touchTarget + Tokens.Space.s2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Palette.chrome)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
            .accessibilityLabel("Your profile on \(session.record.label): \(name)")
            .photosPicker(isPresented: $pickingAvatar, selection: $avatarItem, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: avatarItem) {
                guard let item = avatarItem else { return }
                avatarItem = nil
                setAvatar(from: item)
            }
        }
    }

    /// Crops the picked image to the avatar the server takes, then sends it with `/avatar`
    /// (§4.8.6). The server sends `user` with the new avatar once it is written.
    private func setAvatar(from item: PhotosPickerItem) {
        let limits = session.mediaLimits?.avatar
        settingAvatar = true
        perform {
            defer { settingAvatar = false }
            guard let file = try await item.loadTransferable(type: ImportedFile.self) else { throw CocoaError(.fileReadUnknown) }
            let avatar = try await Task.detached {
                try AttachmentPreparer.prepareAvatar(file.url, limits: limits, into: AttachmentStaging.directory)
            }.value
            try await session.setAvatar(avatar)
        }
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

    var body: some View {
        let unread = session.unreadCount(in: roomID)
        let mentions = session.mentionCount(in: roomID)
        let joined = session.joinedRoomIDs.contains(roomID)
        let strong = isSelected || unread > 0
        HStack(alignment: isThread ? .top : .center, spacing: Tokens.Space.s2) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Tokens.Space.s1) {
                    Text(session.title(of: roomID))
                        .apText(.body, strong ? .semibold : (isThread ? .medium : .regular))
                        .foregroundStyle(strong || isThread ? Palette.ink : Palette.inkMuted)
                        .lineLimit(1)
                    if session.isPrivate(roomID) { Lock() }
                }
                if !isThread, let topic = session.roomDescription(roomID) {
                    Text(topic).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
                }
                if isThread {
                    if let description = session.roomDescription(roomID) {
                        line(icon: "text.alignleft") { Text(description) }
                    }
                    if let last = session.lastMessage(in: roomID) {
                        line(icon: "arrow.turn.down.right") {
                            let sender = Text(session.displayName(for: last.from)).fontWeight(.medium).foregroundStyle(Palette.ink)
                            let text = Text(previewText(last.body)).foregroundStyle(unread > 0 ? Palette.ink : Palette.inkMuted)
                            Text("\(sender) \(text)")
                        }
                    }
                }
            }
            Spacer(minLength: Tokens.Space.s2)
            if mentions > 0 {
                UnreadCount(count: mentions, mentions: true)
            } else if unread > 0 {
                UnreadCount(count: unread)
            } else if !joined {
                Text("Not joined").apText(.sm).foregroundStyle(Palette.inkMuted)
            }
        }
        .padding(.vertical, isThread ? Tokens.Space.s1_5 : Tokens.Space.s2)
        .padding(.trailing, Tokens.Space.s3)
        .padding(.leading, isThread ? Tokens.Space.s3 + Tokens.Space.s4 + Tokens.Space.s2 : Tokens.Space.s3)
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
        .accessibilityLabel(accessibilityText(unread: unread, mentions: mentions, joined: joined))
    }

    private func line(icon: String, @ViewBuilder _ text: () -> Text) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            Image(systemName: icon).imageScale(.small)
            text().lineLimit(1)
        }
        .apText(.sm)
        .foregroundStyle(Palette.inkMuted)
    }

    private func accessibilityText(unread: Int, mentions: Int, joined: Bool) -> String {
        var parts = [session.title(of: roomID)]
        if isThread {
            parts.append("thread in \(session.store.room(roomID)?.parentRoomID.map(session.title(of:)) ?? "a room")")
        }
        if session.isPrivate(roomID) { parts.append("private") }
        if mentions > 0 { parts.append("\(mentions) \(mentions == 1 ? "mention" : "mentions") of you") }
        if unread > 0 { parts.append("\(unread) new") }
        if !joined { parts.append("not joined") }
        if isThread, let description = session.roomDescription(roomID) { parts.append(description) }
        return parts.joined(separator: ", ")
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
                if let error { Text(error).apText(.ui).foregroundStyle(Palette.danger) }
                ForEach(roomIDs ?? [], id: \.self) { roomID in
                    HStack {
                        Text(session.title(of: roomID)).apText(.body).foregroundStyle(Palette.ink)
                        if session.isPrivate(roomID) { Lock() }
                        Spacer()
                        if session.joinedRoomIDs.contains(roomID) {
                            Label("Joined", systemImage: "checkmark").apText(.sm).foregroundStyle(Palette.inkMuted)
                        } else {
                            Button("Join") {
                                Task {
                                    do { try await session.join(roomID) } catch { self.error = errorText(error) }
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
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
                    EmptyState(title: "No other rooms", detail: "You are in every room you can see on \(session.record.label).") { EmptyView() }
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
