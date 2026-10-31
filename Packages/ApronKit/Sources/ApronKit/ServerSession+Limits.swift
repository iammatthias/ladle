import Foundation

/// Waits the server asked for (§1.1 `retry_after`, EXTENSIONS.md `ext:limits`), as apron-web's
/// `noteLimit` and `heldBack`: a refused request notes what it holds back, and until the wait is
/// over those requests are refused here, in the server's words, rather than sent.
extension ServerSession {
    /// The wait on `scope`, while it lasts.
    public func wait(_ scope: LimitScope) -> LimitWait? {
        limits[scope].flatMap { $0.until > environment.now() ? $0 : nil }
    }

    /// What holds sending back: a `write` wait, or a refused `message`'s, the longer.
    public var sendWait: LimitWait? {
        [wait(.write), wait(.message)].compactMap { $0 }.max { $0.until < $1.until }
    }

    /// The wait on the composer's Send: sending's, and with files the upload wait too, the longer.
    public func composerWait(withFiles: Bool) -> LimitWait? {
        [sendWait, withFiles ? wait(.upload) : nil].compactMap { $0 }.max { $0.until < $1.until }
    }

    /// The `retry_after` refusal for a request a wait holds back, or nil to send it. A sending wait
    /// says "Sending is paused"; an `ext:limits` one keeps the server's words, which name the limit.
    func heldBack(_ method: String, _ params: JSONValue) -> RPCError? {
        let held = LimitScope.allCases.compactMap { scope in wait(scope).flatMap { scope.holds(method, params: params) ? (scope, $0) : nil } }
            .max { $0.1.until < $1.1.until }
        guard let (scope, wait) = held else { return nil }
        let words = scope == .message ? "Sending is paused" : wait.message
        let seconds = max(1, Int(wait.until.timeIntervalSince(environment.now()).rounded(.up)))
        return RPCError(code: RPCError.Code.retryAfter, message: words, data: ["retry_after": .number(String(seconds))])
    }

    /// Notes what a refusal holds back, and until when, unless a longer wait runs already. The
    /// category counts only while the server has `ext:limits`. Waits belong to who was asked.
    func noteLimit(_ error: RPCError, method: String, params: JSONValue) {
        guard let retry = error.retryAfter,
              let scope = LimitScope(refused: method, params: params,
                                     category: server?.has("ext:limits") == true ? error.limitCategory : nil)
        else { return }
        if limitsUserID != you?.userID {
            limits = [:]
            limitsUserID = you?.userID
        }
        let now = environment.now()
        let until = now.addingTimeInterval(Double(retry.components.seconds))
        if let current = wait(scope), current.until >= until { return }
        limits[scope] = LimitWait(until: until, since: now, message: error.message)
        Task { [weak self] in
            try? await Task.sleep(for: retry)
            guard let self, let kept = self.limits[scope], kept.until <= self.environment.now() else { return }
            self.limits[scope] = nil
        }
    }
}
