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

    /// Sends a request on `connection` and gives its result, as every request after sign-in goes.
    /// A wait this account is under refuses it before it is sent (`heldBack`). A refusal with a
    /// `retry_after` of at most `ShortWait.longest`, of a request `ShortWait.waitsOut` allows, is
    /// waited out here and sent again under the same `id` (§1.2), at most `ShortWait.resends`
    /// times; any other refusal, or the last, notes what it holds back and throws. So the hold is
    /// checked only before the first send and noted only once nothing will be resent: the two
    /// never both wait. The resend goes on `connection`, so a reconnect meanwhile fails it with
    /// `Connection.Failure.closed`, as it fails every pending request.
    func ask(_ method: String, _ params: JSONValue, id: String? = nil, on connection: Connection) async throws -> JSONValue {
        if let held = heldBack(method, params) { throw held }
        let waitsOut = ShortWait.waitsOut(method, params)
        let id = id ?? (waitsOut ? environment.makeRequestID() : nil)
        var resends = 0
        while true {
            do {
                return try await connection.request(method, params: params, id: id)
            } catch let error as RPCError {
                // A wait cut short (its task cancelled) shows the refusal, as it would have unwaited.
                if waitsOut, resends < ShortWait.resends, let wait = error.retryAfter, wait <= ShortWait.longest,
                   (try? await environment.sleep(wait)) != nil {
                    resends += 1
                    continue
                }
                noteLimit(error, method: method, params: params)
                throw error
            }
        }
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
