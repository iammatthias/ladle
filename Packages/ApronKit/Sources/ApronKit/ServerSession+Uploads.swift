import Foundation

/// Attachments (§4.8.3, §4.8.4) and avatars (§4.8.6): what the server takes, the writes after a
/// result lists their URLs, and what a failed write leaves behind.
extension ServerSession {
    /// Whether the server takes attachments; without `embed:upload` there are none (§4).
    public var canAttach: Bool { server?.has("embed:upload") == true }

    /// Whether `/avatar` with an upload can set this user's avatar (§4.8.6).
    public var canSetAvatar: Bool { canAttach && server?.has("command") == true }

    /// Which URLs this server's embeds and avatars may load from.
    public var mediaPolicy: MediaPolicy { MediaPolicy(serverURL: record.url, server: server) }

    /// What the server says it takes (EXT.md §6), or nil when it says nothing.
    public var mediaLimits: MediaLimits? { MediaLimits(server: server) }

    /// The user's avatar (§4.8.6) from the kept user object, when the policy lets it load.
    public func avatarURL(of userID: String) -> URL? {
        let value = users.user(userID)?["avatar"]
        guard let url = webURL(value) ?? dataImageURL(value), mediaPolicy.allowsAvatar(url) else { return nil }
        return url
    }

    /// Sets this user's avatar from an image: a `/avatar` command with one `upload` embed, then
    /// the image written to the result's `write_url`. The server sends `user` once it is set.
    public func setAvatar(_ image: Attachment) async throws {
        try require("command")
        try require("embed:upload")
        let result = try await request("command", ["body": ["text": "/avatar", "embeds": [Self.uploadEmbed(image)]]])
        guard let target = Self.writeTargets(in: result).first else { throw Failure.attachmentNotAccepted }
        uploadProgress[target.embedID] = 0
        defer { uploadProgress[target.embedID] = nil }
        try await environment.writeEmbed(target.writeURL, image, progressReporter(target.embedID))
    }

    static func uploadEmbed(_ attachment: Attachment) -> JSONValue {
        ["kind": "upload", "title": .string(attachment.title)]
    }

    /// The new `upload` embeds a result lists, in request order (§4.8.3).
    static func writeTargets(in result: JSONValue) -> [(embedID: String, writeURL: URL)] {
        (result["embeds"]?.arrayValue ?? []).compactMap { embed in
            guard embed["kind"]?.stringValue == "upload", let id = embed["embed_id"]?.stringValue, let url = webURL(embed["write_url"])
            else { return nil }
            return (id, url)
        }
    }

    /// Starts one write per attachment. A result that lists fewer write URLs than attachments
    /// leaves the unlisted ones as Not sent.
    func startWrites(for attachments: [Attachment], listedIn result: JSONValue, roomID: String) {
        guard !attachments.isEmpty else { return }
        let targets = Self.writeTargets(in: result)
        for (index, attachment) in attachments.enumerated() {
            guard index < targets.count else {
                notSent(attachment, in: roomID, EmbedWriteError.notAccepted)
                continue
            }
            let target = targets[index]
            uploadProgress[target.embedID] = 0
            Task { await write(attachment, to: target, roomID: roomID) }
        }
    }

    private func write(_ attachment: Attachment, to target: (embedID: String, writeURL: URL), roomID: String) async {
        do {
            try await environment.writeEmbed(target.writeURL, attachment, progressReporter(target.embedID))
            uploadProgress[target.embedID] = nil
        } catch {
            uploadProgress[target.embedID] = nil
            notSent(attachment, in: roomID, error)
        }
    }

    /// The write URL was single-use, so a retry posts the file again in a message of its own.
    private func notSent(_ attachment: Attachment, in roomID: String, _ error: any Error) {
        let reason = (error as? LocalizedError)?.errorDescription ?? "The upload failed."
        outbox.append(PendingMessage(id: "q-" + environment.makeRequestID(), roomID: roomID, text: "", replyTo: nil, mentions: [],
                                     attachments: [attachment], userID: you?.userID, queuedAt: Date(), state: .failed(reason)))
    }

    private func progressReporter(_ embedID: String) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.uploadProgress[embedID] != nil else { return }
                self.uploadProgress[embedID] = fraction
            }
        }
    }
}
