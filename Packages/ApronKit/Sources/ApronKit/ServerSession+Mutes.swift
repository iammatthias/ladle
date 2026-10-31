import Foundation

/// Pausing notifications and muting rooms (§4.5 `status` `mute`), as apron-web's `setMute` and
/// `handleStatus`. A request only asks: nothing changes here until the server's `status`
/// notification says so, which it sends to each of your connections, this one included. Each
/// sign-in starts with none, and the server sends those in effect after its result.
extension ServerSession {
    /// Whether you may pause or mute here: capability `status`, signed in.
    public var mayMute: Bool { server?.has("status") == true && status == .signedIn && you != nil }

    /// Your pause, while it lasts.
    public var pause: MuteEnd? {
        pausedUntil.flatMap { $0.isActive(at: environment.now()) ? $0 : nil }
    }

    /// "Paused until 14:30", the profile bar's line while paused.
    public var pausedLine: String? {
        pause.map { "Paused \($0.words(now: environment.now()))" }
    }

    /// A room's or thread's mute, while it lasts: its own, else, for a thread, its room's.
    public func mute(of roomID: String) -> RoomMute? {
        let now = environment.now()
        if let own = roomMutes[roomID], own.isActive(at: now) { return .own(own) }
        if let parent = store.room(roomID)?.parentRoomID, let end = roomMutes[parent], end.isActive(at: now) { return .withRoom(parent, end) }
        return nil
    }

    /// When a room's mute ends, in words: "until 14:30", or "until you unmute".
    public func muteWords(_ mute: RoomMute) -> String {
        mute.end.words(now: environment.now(), open: "until you unmute")
    }

    /// Asks to pause your notifications on all your devices until `end`, or to resume them with nil.
    /// Throws the server's error, such as a `retry_after`, when nothing changed.
    public func setPause(_ end: MuteEnd?) async throws {
        try require("status")
        _ = try await request("status", ["mute": end?.wire(now: environment.now()) ?? .bool(false)])
    }

    /// Asks to mute a room or thread and its threads until `end`, or to unmute it with nil.
    public func setMute(_ roomID: String, _ end: MuteEnd?) async throws {
        try require("status")
        _ = try await request("status", ["room_id": .string(roomID), "mute": end?.wire(now: environment.now()) ?? .bool(false)])
    }

    /// A `status` from the server: a change to one of your mutes, or after a sign-in one in effect.
    /// Without `room_id` it is your pause. An invalid `mute` or `room_id` is ignored.
    func applyStatus(_ params: JSONValue?) {
        guard let params, MuteEnd.isMute(params["mute"]) else { return }
        let end = MuteEnd(wire: params["mute"], now: environment.now())
        switch params["room_id"] {
        case nil:
            pausedUntil = end
        case .string(let roomID):
            roomMutes[roomID] = end
        default:
            return
        }
        scheduleMuteExpiry()
    }

    func resetMutes() {
        pausedUntil = nil
        roomMutes = [:]
        scheduleMuteExpiry()
    }

    /// At the earliest end, drops the mutes that are over, so rows and the profile bar change
    /// without a word from the server, as apron-web's timers do. A `mute: false` the server
    /// sends later finds them gone.
    private func scheduleMuteExpiry() {
        muteExpiry?.cancel()
        muteExpiry = nil
        let now = environment.now()
        let ends = ([pausedUntil] + roomMutes.values.map(Optional.some)).compactMap { end -> Date? in
            if case .at(let date)? = end { date } else { nil }
        }
        guard let first = ends.min() else { return }
        let wait = max(0, first.timeIntervalSince(now))
        muteExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            let now = self.environment.now()
            if let pause = self.pausedUntil, !pause.isActive(at: now) { self.pausedUntil = nil }
            self.roomMutes = self.roomMutes.filter { $0.value.isActive(at: now) }
            self.scheduleMuteExpiry()
        }
    }
}
