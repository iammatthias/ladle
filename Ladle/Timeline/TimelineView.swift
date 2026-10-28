import ApronKit
import SwiftUI

/// A room's messages, oldest first, paging back as the top comes into view.
struct TimelineView: View {
    let session: ServerSession
    let roomID: String
    @State private var draft: Draft
    @State private var error: String?
    @State private var reacting: MessageSnapshot?
    @Environment(\.theme) private var theme

    init(session: ServerSession, roomID: String, draft: Draft = Draft()) {
        self.session = session
        self.roomID = roomID
        _draft = State(initialValue: draft)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if session.histories[roomID]?.canLoadOlder == true {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task(id: session.timeline(roomID).count) {
                            do { try await session.loadOlder(roomID) } catch { self.error = errorText(error) }
                        }
                }
                ForEach(session.timelineItems(roomID)) { item in
                    row(item)
                }
            }
            .padding(.horizontal, theme.layout == .dense ? 12 : 16)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .background(theme.palette.background.color)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if theme.direction == .enamel {
                    RoomSwitcher(session: session, current: roomID)
                }
                ComposerView(session: session, draft: $draft) { text in
                    let draft = self.draft
                    self.draft = Draft()
                    perform {
                        switch draft.mode {
                        case .new: try await session.send(text, in: roomID)
                        case .reply(let target): try await session.send(text, in: roomID, replyTo: target.messageID)
                        case .edit(let target): try await session.edit(target, text: text)
                        }
                    }
                }
            }
        }
        .background {
            Button("Reply to Last Message") {
                if let last = session.timeline(roomID).last(where: { !$0.isTombstone && $0.from.userID != session.you?.userID }) {
                    draft = Draft(mode: .reply(last))
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .navigationTitle(session.title(of: roomID))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.status == .signedIn, session.server?.has("rooms") == true {
                Menu("Room", systemImage: "ellipsis") {
                    if session.joinedRoomIDs.contains(roomID) {
                        Button("Leave", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            perform { try await session.leave(roomID) }
                        }
                    } else {
                        Button("Join", systemImage: "plus.circle") { perform { try await session.join(roomID) } }
                    }
                }
            }
        }
        .confirmationDialog("React", isPresented: Binding(get: { reacting != nil }, set: { if !$0 { reacting = nil } })) {
            ForEach(Self.quickReactions, id: \.self) { emoji in
                Button(emoji) {
                    if let message = reacting { perform { try await session.toggleReaction(emoji, on: message.messageID) } }
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
        .task(id: session.status) {
            guard session.status == .signedIn else { return }
            do { try await session.open(roomID) } catch { self.error = errorText(error) }
        }
    }

    static let quickReactions = ["👍", "❤️", "😂", "🎉", "👀", "🙏"]

    @ViewBuilder
    private func row(_ item: TimelineItem) -> some View {
        switch item {
        case .message(let message, let continues):
            MessageRow(session: session, message: message, continues: continues) { emoji in
                perform { try await session.toggleReaction(emoji, on: message.messageID) }
            }
            .padding(.top, continues ? theme.runSpacing : theme.groupSpacing)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12))
            .contextMenu { actions(for: message) }
            .modifier(SwipeToReply(enabled: theme.direction == .mise && !message.isTombstone) {
                draft = Draft(mode: .reply(message))
            })
        case .unreadLine:
            UnreadLine()
                .padding(.top, theme.groupSpacing)
        case .thread(let threadID):
            NavigationLink(value: threadID) {
                ThreadCard(session: session, threadID: threadID)
            }
            .buttonStyle(.plain)
            .padding(.top, theme.groupSpacing)
        }
    }

    @ViewBuilder
    private func actions(for message: MessageSnapshot) -> some View {
        if !message.isTombstone, session.status == .signedIn {
            if session.server?.has("reactions") == true {
                ControlGroup {
                    ForEach(Self.quickReactions.prefix(4), id: \.self) { emoji in
                        Button(emoji) { perform { try await session.toggleReaction(emoji, on: message.messageID) } }
                    }
                }
                .controlGroupStyle(.compactMenu)
            }
            Button("Reply", systemImage: "arrowshape.turn.up.left") { draft = Draft(mode: .reply(message)) }
            if session.server?.has("reactions") == true {
                Button("More Reactions", systemImage: "face.smiling") { reacting = message }
            }
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.plainText }
            if message.from.userID == session.you?.userID, session.server?.has("edit") == true {
                Button("Edit", systemImage: "pencil") {
                    draft = Draft(mode: .edit(message), text: message.plainText)
                }
                Button("Delete", systemImage: "trash", role: .destructive) { perform { try await session.delete(message) } }
            }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() } catch { self.error = errorText(error) }
        }
    }
}

/// What the composer is writing: a new message, a reply, or an edit.
struct Draft {
    enum Mode {
        case new
        case reply(MessageSnapshot)
        case edit(MessageSnapshot)
    }

    var mode = Mode.new
    var text = ""
}

/// Mise: drag a message right past a threshold to reply. One light impact marks the threshold;
/// the context menu's Reply stays as the non-gesture path.
private struct SwipeToReply: ViewModifier {
    let enabled: Bool
    let reply: () -> Void
    @State private var offset: CGFloat = 0
    @Environment(\.theme) private var theme
    private let threshold: CGFloat = 64

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(x: offset)
                .background(alignment: .leading) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .foregroundStyle(theme.palette.accent.color)
                        .opacity(Double(min(offset / threshold, 1)))
                        .padding(.leading, 4)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            offset = min(max(0, value.translation.width), threshold * 1.4)
                        }
                        .onEnded { _ in
                            if offset >= threshold { reply() }
                            withAnimation(.spring(duration: 0.3)) { offset = 0 }
                        }
                )
                .sensoryFeedback(.impact(weight: .light), trigger: offset >= threshold) { _, crossed in crossed }
        } else {
            content
        }
    }
}

/// The read line: the first message from someone else after this user's read cursor.
private struct UnreadLine: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(theme.palette.accent.color).frame(height: 1)
            Text("New")
                .font(theme.font(.caption, theme.metaFace, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(theme.palette.accent.color)
            Rectangle().fill(theme.palette.accent.color).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
    }
}

/// A thread opened from this room: its title, message count, and new messages.
private struct ThreadCard: View {
    let session: ServerSession
    let threadID: String
    @Environment(\.theme) private var theme

    var body: some View {
        let palette = theme.palette
        let count = session.timeline(threadID).count
        let unread = session.unreadCount(in: threadID)
        let last = session.lastMessage(in: threadID)
        let summary = [
            "\(count) \(count == 1 ? "message" : "messages")",
            unread > 0 ? "\(unread) new" : nil,
            last.map { "last from \(session.displayName(for: $0.from))" },
        ].compactMap { $0 }.joined(separator: " · ")
        switch theme.layout {
        case .dense:
            HStack(spacing: 6) {
                Image(systemName: "number")
                Text(session.title(of: threadID)).fontWeight(.bold)
                Text(summary).foregroundStyle(palette.secondary.color).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(palette.secondary.color)
            }
            .font(theme.font(.footnote, .mono))
            .foregroundStyle(palette.accent.color)
            .frame(minHeight: 44)
            .padding(.horizontal, 10)
            .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 6))
        default:
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.title3)
                    .foregroundStyle(palette.accent.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title(of: threadID))
                        .font(theme.font(.headline, theme.titleFace, weight: .semibold))
                        .foregroundStyle(palette.text.color)
                    Text(summary)
                        .font(theme.font(.footnote))
                        .foregroundStyle(palette.secondary.color)
                }
                Spacer(minLength: 0)
                if unread > 0 {
                    UnreadBadge(count: unread)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondary.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(palette.surface.color, in: RoundedRectangle(cornerRadius: theme.layout == .bubbles ? 22 : 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.layout == .bubbles ? 22 : 12, style: .continuous).strokeBorder(palette.separator.color))
        }
    }
}

/// Enamel: the joined rooms of this server as a strip just above the composer, within thumb
/// reach. Unread rooms show their count; the current room is marked with a check and a fill.
private struct RoomSwitcher: View {
    let session: ServerSession
    let current: String
    @Environment(\.theme) private var theme

    var body: some View {
        let palette = theme.palette
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.roomTree.flatMap { [$0.roomID] + $0.threadIDs }, id: \.self) { roomID in
                        let selected = roomID == current
                        let unread = session.unreadCount(in: roomID)
                        NavigationLink(value: roomID) {
                            HStack(spacing: 6) {
                                if selected { Image(systemName: "checkmark") }
                                Text(session.title(of: roomID)).lineLimit(1)
                                if unread > 0 { Text("\(unread)").fontWeight(.bold).monospacedDigit() }
                            }
                            .font(theme.font(.subheadline, weight: selected || unread > 0 ? .semibold : .regular))
                            .foregroundStyle(selected ? palette.onAccent.color : palette.text.color)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(selected ? palette.accent.color : palette.surface.color, in: Capsule())
                            .overlay(Capsule().strokeBorder(palette.separator.color, lineWidth: selected ? 0 : 1))
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!selected)
                        .id(roomID)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityLabel(session.title(of: roomID) + (unread > 0 ? ", \(unread) new" : ""))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
        .background(.bar)
    }
}

struct UnreadBadge: View {
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        Text("\(count)")
            .font(theme.font(.caption, theme.metaFace, weight: .bold).monospacedDigit())
            .foregroundStyle(theme.palette.onAccent.color)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(theme.palette.accent.color, in: Capsule())
            .accessibilityLabel("\(count) new")
    }
}
