import Foundation

/// What the server takes `idle` (§4.5) to be on one connection: a connection starts attended.
struct IdleReport {
    var connection: Int
    /// What the server applied; nil after a request that got no answer, which may have applied.
    var applied: Bool? = false
    var sending = false
    var failures = 0
    var retry: Task<Void, Never>?
}

/// Idle reporting (§4.5 `status {idle}`), as apron-web's `setIdle` and `syncIdle`.
extension ServerSession {
    /// The first wait before a refused or unanswered `idle` goes again; it doubles to `idleRetryMax`.
    static let idleRetry: Duration = .seconds(5)
    static let idleRetryMax: Duration = .seconds(300)

    /// Whether anyone attends the app, and when it was last used. A server with capability
    /// `status` hears it as `idle`: the whole seconds since `inputAt` (since now where unknown), or
    /// `false`. Kept across connections; a connection starts attended, so an attended app sends
    /// nothing until it goes idle.
    public func setIdle(_ idle: Bool, inputAt: Date?) {
        idleInputAt = idle ? (inputAt ?? (wantsIdle ? idleInputAt : environment.now())) : nil
        wantsIdle = idle
        syncIdle()
    }

    /// Sends `idle` when the server's view of this connection differs from the app's, one request
    /// at a time so they apply in order (§1); a change meanwhile goes after the reply. On
    /// `retry_after` the current state goes after the wait; after another failure, after a
    /// backoff from `idleRetry`, so an app that is back is not left idle.
    func syncIdle() {
        guard status == .signedIn, server?.has("status") == true else { return }
        if idleReport?.connection != connectionNumber {
            idleReport?.retry?.cancel()
            idleReport = IdleReport(connection: connectionNumber)
        }
        guard let report = idleReport, !report.sending, report.retry == nil, report.applied != wantsIdle else { return }
        let idle = wantsIdle
        let value: JSONValue = idle
            ? .number(String(max(0, Int(environment.now().timeIntervalSince(idleInputAt ?? environment.now())))))
            : .bool(false)
        idleReport?.sending = true
        idleSending = Task {
            do {
                _ = try await request("status", ["idle": value])
                idleSending = nil
                guard idleReport?.connection == report.connection else { return }
                idleReport?.sending = false
                idleReport?.applied = idle
                idleReport?.failures = 0
                syncIdle()
            } catch {
                idleSending = nil
                guard idleReport?.connection == report.connection else { return }
                idleReport?.sending = false
                let rpc = error as? RPCError
                if rpc == nil { idleReport?.applied = nil }
                var wait = rpc?.retryAfter
                if wait == nil {
                    let failures = (idleReport?.failures ?? 0) + 1
                    idleReport?.failures = failures
                    wait = min(Self.idleRetry * (1 << min(failures - 1, 16)), Self.idleRetryMax)
                }
                idleReport?.retry = Task { [weak self, wait] in
                    try? await self?.environment.sleep(wait ?? Self.idleRetry)
                    guard let self, !Task.isCancelled, self.idleReport?.connection == report.connection else { return }
                    self.idleReport?.retry = nil
                    self.syncIdle()
                }
            }
        }
    }

    /// Tells the server this app is idle, waiting up to `deadline` for the answer, then stops: what
    /// the app does as it goes to the background, so the server can push what comes after.
    /// A message being typed live is finished first, as Send would, since its write would not
    /// outlive the app's suspension.
    public func suspend(deadline: Duration = .seconds(3)) async {
        suspensions += 1
        let suspension = suspensions
        setIdle(true, inputAt: idleInputAt)
        await finishLiveTypingNow()
        await flushReadCursors()
        await flushKept()
        if let sending = idleSending {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await sending.value }
                group.addTask { try? await Task.sleep(for: deadline) }
                await group.next()
                group.cancelAll()
            }
        }
        guard suspensions == suspension else { return }
        await stop()
    }
}
