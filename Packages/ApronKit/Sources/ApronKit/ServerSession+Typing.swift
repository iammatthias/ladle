import Foundation

/// Someone else typing in a room (§4.6), shown until their `typing` seconds run out, a message
/// from them arrives there, or they send `typing: 0`.
public struct Typist: Hashable, Sendable {
    public var user: UserObject
    /// This showing of them, so a timer from an earlier one cannot end a refreshed one.
    let token: UUID
}

/// How typing is reported, as apron-web's client does it.
public struct TypingTimes: Hashable, Sendable {
    /// The `typing` seconds this client sends: others show you typing that long without a
    /// refresh (`TYPING_TIMEOUT_S`).
    public var seconds: Int
    /// The least time between two `typing` frames for one room while typing goes on
    /// (`TYPING_REFRESH_MS`): well inside `seconds`, and far from one frame a keystroke.
    public var refresh: Duration
    /// How long the composer may sit untouched before `typing: 0` goes (the composer's 5 s timer).
    public var idle: Duration
    /// The longest someone else shows as typing without a refresh, whatever they sent (`MAX_TYPING_S`).
    public var longest: Duration

    public init(seconds: Int = 15, refresh: Duration = .seconds(12), idle: Duration = .seconds(5), longest: Duration = .seconds(300)) {
        self.seconds = seconds
        self.refresh = refresh
        self.idle = idle
        self.longest = longest
    }
}

extension ServerSession {
    /// The names of everyone else typing in `roomID`, in the order they last started or
    /// refreshed, as apron-web lists `typing`.
    public func typingNames(in roomID: String) -> [String] {
        (typing[roomID] ?? []).map { displayName(for: $0.user) }
    }

    /// The composer's text changed in `roomID`: with capability `activity`, says this user is
    /// typing (`typing: TypingTimes.seconds`), again only once `refresh` has passed, and
    /// `typing: 0` once the composer has been left alone for `idle`, as apron-web's
    /// `composerInput` and `sendTyping`. Nothing goes to a server without the capability, before
    /// sign-in, or from someone who may not write.
    public func composerChanged(in roomID: String) {
        onInput?()
        // A live message shows itself as it is typed: no typing indicator besides.
        guard status == .signedIn, server?.has("activity") == true, mayWrite, liveMessage?.roomID != roomID else { return }
        let times = environment.typing
        let now = ContinuousClock.now
        // Typing somewhere else now: it ends where it was, rather than show there until it runs out (apron-web #209).
        let elsewhere = typingSentAt.keys.filter { $0 != roomID }.sorted(by: codePointLess)
        for other in elsewhere { forgetOwnTyping(in: other) }
        let starts = typingSentAt[roomID].map { now - $0 >= times.refresh } ?? true
        if starts { typingSentAt[roomID] = now }
        if starts || !elsewhere.isEmpty {
            Task {
                for other in elsewhere { await notify("activity", ["room_id": .string(other), "typing": 0]) }
                if starts { await notify("activity", ["room_id": .string(roomID), "typing": .number(String(times.seconds))]) }
            }
        }
        typingIdle[roomID]?.cancel()
        typingIdle[roomID] = Task { [weak self] in
            try? await Task.sleep(for: times.idle)
            guard !Task.isCancelled else { return }
            await self?.stoppedTyping(in: roomID)
        }
    }

    /// Sends `typing: 0` for `roomID` if this user was last said to be typing there.
    func stoppedTyping(in roomID: String) async {
        guard forgetOwnTyping(in: roomID) else { return }
        await notify("activity", ["room_id": .string(roomID), "typing": 0])
    }

    /// Forgets that this user is typing in `roomID`; true if they were said to be.
    @discardableResult
    private func forgetOwnTyping(in roomID: String) -> Bool {
        typingIdle.removeValue(forKey: roomID)?.cancel()
        return typingSentAt.removeValue(forKey: roomID) != nil
    }

    /// A message ends this user's typing for everyone (§4.6), so no `typing: 0` follows it.
    func sentMessage(in roomID: String) {
        typingSentAt[roomID] = nil
        typingIdle.removeValue(forKey: roomID)?.cancel()
    }

    /// An `activity` broadcast's `typing` (§4.6) from someone else: seconds show or refresh them,
    /// at most `longest`, and `0` ends it. Absent or not a number of seconds, nothing changes.
    func applyTyping(_ params: JSONValue?) {
        guard let from = UserObject(params?["from"]), !isYou(from.userID), let roomID = OpaqueID.validated(params?["room_id"]),
              let seconds = params?["typing"]?.doubleValue, seconds.isFinite, seconds >= 0 else { return }
        endTyping(from.userID, in: roomID)
        guard seconds > 0 else { return }
        let typist = Typist(user: from, token: UUID())
        typing[roomID, default: []].append(typist)
        let wait = min(Duration.milliseconds(Int64(seconds * 1000)), environment.typing.longest)
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.expire(typist, in: roomID)
        }
    }

    /// A new message from `userID` in `roomID` ends their typing there (§4.6).
    func endTyping(_ userID: String, in roomID: String) {
        guard let typists = typing[roomID], typists.contains(where: { $0.user.userID == userID }) else { return }
        let rest = typists.filter { $0.user.userID != userID }
        typing[roomID] = rest.isEmpty ? nil : rest
    }

    /// Forgets all typing, both ways, when the connection ends: the next one starts afresh.
    func clearTyping() {
        typing = [:]
        typingSentAt = [:]
        for task in typingIdle.values { task.cancel() }
        typingIdle = [:]
    }

    private func expire(_ typist: Typist, in roomID: String) {
        guard typing[roomID]?.contains(typist) == true else { return }
        endTyping(typist.user.userID, in: roomID)
    }
}

/// What says who is typing, as apron-web's TypingIndicator (above the composer, wide) and
/// RoomHeader (the subtitle, on a phone). Each name is isolated in its own direction.
public enum TypingLine {
    /// "Ada is typing…", "Ada and Bram are typing…", then "Several people are typing…".
    public static func line(_ names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: "\(TextDirection.isolated(names[0])) is typing…"
        case 2: "\(TextDirection.isolated(names[0])) and \(TextDirection.isolated(names[1])) are typing…"
        default: "Several people are typing…"
        }
    }

    /// "Ada is typing…", then "3 people are typing…".
    public static func subtitle(_ names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: "\(TextDirection.isolated(names[0])) is typing…"
        default: "\(names.count) people are typing…"
        }
    }
}
