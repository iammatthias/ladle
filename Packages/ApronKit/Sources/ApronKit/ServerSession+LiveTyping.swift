import Foundation

/// Where a live message's draft is kept (`Drafts`, by the room's `DraftKey`): emptied when the
/// message is finished, and given back when the message can't be made.
public struct LiveDraft {
    /// Empties the draft: its text and reply, kept files aside.
    public var forget: @MainActor () -> Void
    /// Gives the draft back, when nothing else was typed there since (`Drafts.restore`).
    public var restore: @MainActor (DraftField) -> Void

    public init(forget: @escaping @MainActor () -> Void, restore: @escaping @MainActor (DraftField) -> Void) {
        self.forget = forget
        self.restore = restore
    }
}

/// A message the composer types live, as apron-web's `LiveComposer` keeps it: its write, its room,
/// and the draft as last seen, whose mentions and any reply picked meanwhile the save that
/// finishes it sets.
@MainActor
public final class LiveMessage {
    public let roomID: String
    private(set) var typing: LiveTyping!
    let draft: LiveDraft
    /// The reply the message was posted with, kept by the save unless another was picked.
    let postedReply: LogID?
    var field = DraftField()

    /// `typing` makes the write, given the message its end reports on.
    init(roomID: String, draft: LiveDraft, postedReply: LogID?, typing: (LiveMessage) -> LiveTyping) {
        self.roomID = roomID
        self.draft = draft
        self.postedReply = postedReply
        self.typing = typing(self)
    }

    /// The draft as given back: what was typed, its mentions, and its reply.
    var given: DraftField {
        DraftField(mode: (field.replyTo ?? postedReply).map { .reply($0) } ?? .new, text: typing.text, mentions: field.mentions)
    }
}

extension ServerSession {
    /// Typing live needs `embed:append` (§4.8.5); Ladle's URLSession streams any upload, over
    /// HTTP/1.1 or HTTP/2, so no device lacks the rest.
    public var canTypeLive: Bool { server?.has("embed:append") == true }

    /// `/live` in `roomID`: what is typed next is the room's newest message, live, until Send, as
    /// apron-web's `LiveComposer.start`. The message is posted at once, as Markdown with an empty
    /// `body.text` and one `append` embed, replying to `replyTo`, and its `write_url` gets one
    /// streaming `PUT` that follows the composer (`typedLive`). A message already live is
    /// finished first. `transport` replaces the post and the write, for tests and the renderer.
    public func startLiveTyping(in roomID: String, replyTo: LogID?, draft: LiveDraft, transport: LiveTyping.Transport? = nil) {
        finishLiveTyping()
        draft.forget()
        sentMessage(in: roomID)
        let transport = transport ?? LiveTyping.Transport(start: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await postAppend(in: roomID, replyTo: replyTo)
        }, write: environment.writeLiveText)
        liveMessage = LiveMessage(roomID: roomID, draft: draft, postedReply: replyTo) { live in
            LiveTyping(transport: transport) { [weak self, unowned live] end in self?.ended(live, end) }
        }
    }

    /// The live draft changed in `roomID`: its edit goes out, and its mentions and reply are kept
    /// for the save that finishes it.
    public func typedLive(_ field: DraftField, in roomID: String) {
        guard let live = liveMessage, live.roomID == roomID, !field.isEdit else { return }
        live.field = field
        live.typing.update(field.text)
    }

    /// Send on the live draft: `field` is its final text.
    func sendLive(_ field: DraftField, in roomID: String) {
        typedLive(field, in: roomID)
        finishLiveTyping()
    }

    /// Finishes the live message as Send would, from the draft as last seen: leaving its room does.
    /// The composer empties at once; the save that ends the text follows (`settle`). One that
    /// never got going gives the draft back (`ended`).
    public func finishLiveTyping() {
        guard let live = takeLiveMessage() else { return }
        Task { await finish(live) }
    }

    /// The same, returning once the save is made.
    func finishLiveTypingNow() async {
        guard let live = takeLiveMessage() else { return }
        await finish(live)
    }

    private func takeLiveMessage() -> LiveMessage? {
        guard let live = liveMessage else { return nil }
        liveMessage = nil
        live.draft.forget()
        return live
    }

    private func finish(_ live: LiveMessage) async {
        if let messageID = await live.typing.finish() { await settle(live, messageID) }
    }

    /// Stops typing live and takes the message back (capability `edit`): it is deleted for
    /// everyone, and the draft stays in the composer as an ordinary draft. Ladle's own: on the web,
    /// Send with an empty field does it.
    public func stopLiveTyping() {
        guard let live = liveMessage else { return }
        liveMessage = nil
        Task {
            guard let messageID = await live.typing.finish() else { return }
            live.typing.close()
            if server?.has("edit") == true {
                _ = try? await request("message", ["message_id": messageID.json, "room_id": .string(live.roomID), "deleted": true])
            }
        }
    }

    /// Ends the write without a save, as the session stops: the server keeps what arrived.
    func closeLiveTyping() {
        liveMessage?.typing.close()
        liveMessage = nil
    }

    /// Posts an empty Markdown message whose text continues as live text (§4.8.5), joining the
    /// room first as `send` does. Returns the message and the `write_url` its result lists for
    /// the sender alone (§4.8.3).
    func postAppend(in roomID: String, replyTo: LogID?) async throws -> (messageID: LogID, writeURL: URL) {
        if !joinedRoomIDs.contains(roomID), server?.has("rooms") == true, connection != nil, status == .signedIn {
            try await join(roomID)
        }
        var params: [String: JSONValue] = ["room_id": .string(roomID), "body": ["text": "", "format": "markdown", "embeds": [["kind": "append"]]]]
        if let replyTo { params["reply_to"] = ["message_id": replyTo.json] }
        let result = try await request("message", .object(params))
        let written = result["embeds"]?.arrayValue?.first { $0["kind"]?.stringValue == "append" }?["write_url"]?.stringValue
        guard let messageID = LogID(result["message_id"]), let writeURL = written.flatMap(URL.init(string:)) else { throw LiveTypingRefused() }
        return (messageID, writeURL)
    }

    /// A live message's final text, once its write is finished, as apron-web's `#settle`. With
    /// capability `edit` a save puts the draft in `body.text`, with its mentions and its reply, and
    /// without the embed, which ends the text (§4.8.5: the composer's own state is the text it
    /// means), or deletes the message when nothing was typed; then the write ends. A save that
    /// fails gives the draft back. Without `edit`, the write ends, and the server keeps what arrived.
    private func settle(_ live: LiveMessage, _ messageID: LogID) async {
        let typing: LiveTyping = live.typing
        guard server?.has("edit") == true else { return typing.close() }
        let text = typing.liveText
        var params: [String: JSONValue] = ["message_id": messageID.json, "room_id": .string(live.roomID)]
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["deleted"] = true
        } else {
            var body: [String: JSONValue] = ["text": .string(text), "format": "markdown"]
            let mentions = live.field.sentMentions(holders: roleHolders(in: live.roomID))
            if !mentions.isEmpty { body["mentions"] = .array(mentions.map(JSONValue.string)) }
            params["body"] = .object(body)
            if let reply = live.field.replyTo ?? live.postedReply { params["reply_to"] = ["message_id": reply.json] }
        }
        do {
            _ = try await request("message", .object(params))
            typing.close()
        } catch {
            typing.close()
            live.draft.restore(live.given)
            postNotice("Unable to finish the live message: \(errorText(error))", in: live.roomID)
        }
    }

    /// A live message that stopped by itself, as apron-web's `#ended`. One that never got going
    /// is taken back, where it can be, and the draft is kept, or given back if it was already
    /// sent. One the server ended keeps what arrived, and is finished as Send would, from the draft.
    private func ended(_ live: LiveMessage, _ end: LiveTypingEnd) {
        if liveMessage === live { liveMessage = nil }
        switch end.kind {
        case .failed:
            if let messageID = end.messageID, server?.has("edit") == true {
                Task { _ = try? await request("message", ["message_id": messageID.json, "room_id": .string(live.roomID), "deleted": true]) }
            }
            live.draft.restore(live.given)
            postNotice("Live typing stopped: \(end.reason)", in: live.roomID)
        case .ended:
            live.draft.forget()
            postNotice("The live message ended early: \(end.reason)", in: live.roomID)
            if let messageID = end.messageID { Task { await settle(live, messageID) } }
        }
    }

    /// The holders of each role the room's `@&role` can mention, for `sentMentions`.
    func roleHolders(in roomID: String) -> [String: [String]] {
        Dictionary(mentionableRoles(in: roomID).map { ($0.role, $0.members) }, uniquingKeysWith: { first, _ in first })
    }

    /// A `~private` notice in `roomID`, where a command's replies land too.
    func postNotice(_ text: String, in roomID: String) {
        notices.append(Notice(roomID: roomID, from: UserObject(["user_id": "~private"])!, body: ["text": .string(text), "format": "plain"]))
    }
}

/// The server's result listed no `write_url` for the live text.
struct LiveTypingRefused: Error, LocalizedError {
    var errorDescription: String? { "The server did not accept the live text." }
}
