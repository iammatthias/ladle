import ApronKit
import SwiftUI

/// A room's messages, oldest first, paging back as the top comes into view.
struct TimelineView: View {
    let session: ServerSession
    let roomID: String
    @State private var draft = Draft()
    @State private var error: String?
    @State private var reacting: MessageSnapshot?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if session.histories[roomID]?.canLoadOlder == true {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task(id: session.timeline(roomID).count) {
                            do { try await session.loadOlder(roomID) } catch { self.error = errorText(error) }
                        }
                }
                ForEach(session.timeline(roomID), id: \.messageID) { message in
                    MessageRow(session: session, message: message) { emoji in
                        perform { try await session.toggleReaction(emoji, on: message.messageID) }
                    }
                    .contextMenu { actions(for: message) }
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom) {
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
        .navigationTitle(session.title(of: roomID))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.status == .signedIn, session.server?.has("rooms") == true {
                if session.joinedRoomIDs.contains(roomID) {
                    Button("Leave") { perform { try await session.leave(roomID) } }
                } else {
                    Button("Join") { perform { try await session.join(roomID) } }
                }
            }
        }
        .confirmationDialog("React", isPresented: Binding(get: { reacting != nil }, set: { if !$0 { reacting = nil } })) {
            ForEach(["👍", "❤️", "😂", "🎉", "👀", "🙏"], id: \.self) { emoji in
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

    @ViewBuilder
    private func actions(for message: MessageSnapshot) -> some View {
        if !message.isTombstone, session.status == .signedIn {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { draft = Draft(mode: .reply(message)) }
            if session.server?.has("reactions") == true {
                Button("React", systemImage: "face.smiling") { reacting = message }
            }
            if let text = message.body?["text"]?.stringValue {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            }
            if message.from.userID == session.you?.userID, session.server?.has("edit") == true {
                Button("Edit", systemImage: "pencil") {
                    draft = Draft(mode: .edit(message), text: message.body?["text"]?.stringValue ?? "")
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
