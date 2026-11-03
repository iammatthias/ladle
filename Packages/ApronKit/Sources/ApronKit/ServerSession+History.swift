import Foundation

/// Where a session keeps its history, and for how long: one `HistoryFiles` and the retention every
/// server shares, both owned by `SessionStore`.
@MainActor
public struct HistoryKeeping {
    public let files: any HistoryFiles
    public let settings: HistorySettings

    public init(files: any HistoryFiles, settings: HistorySettings) {
        self.files = files
        self.settings = settings
    }
}

/// Keeping history on the device, as apron-web's `HistoryKeeper` and `ViewKeeper` (#56, #137):
/// only for an account this device signs back in to (`resumable`), never a passing guest's; one
/// file per account, in ARCHIVE.md's form (`Archive`) with each room's catch-up under the
/// header's `ladle_kept`. It is written two seconds after a change, and at once as the app goes
/// to the background. Each account's stays as accounts sign out and in, and is shown again when
/// that account signs back in (#199); it goes only when asked (`forgetKept`), or with the server.
extension ServerSession {
    /// The longest a change waits to be written (apron-web's `FLUSH_MS`).
    static let keptSaveDelay: Duration = .seconds(2)

    /// Reads what was kept for this server's saved account, off the main actor, and shows it before
    /// the connection signs in (`run` waits for it).
    func restoreKept() {
        guard restoring == nil, let account = record.account?.userID, hasSavedToken else { return }
        restoring = Task {
            if let plan = await keptPlan(of: account), !Task.isCancelled { adopt(plan) }
        }
    }

    /// What is kept of `account`'s history here, read off the main actor; nil if nothing is.
    func keptPlan(of account: String) async -> KeptRestore? {
        guard let keeping else { return nil }
        let files = keeping.files, kept = KeptAccount(server: record.id, userID: account)
        let retention = keeping.settings.retention, now = environment.now()
        return await Task.detached { files.read(kept).flatMap { KeptRestore(data: $0, account: account, retention: retention, now: now) } }.value
    }

    /// Whose history this session keeps: the signed-in account, while it is kept.
    public var keptAccount: KeptAccount? {
        guard keepsHistory, let you else { return nil }
        return KeptAccount(server: record.id, userID: you.userID)
    }

    /// Whether Sign Out offers Keep Local History: this account's history is kept here.
    public var offersKeepingHistory: Bool { keptAccount != nil && keeping?.settings.retention != .off }

    /// Whether this session's history is kept: an account this device signs back in to, on a
    /// server that pages history, while keeping has not failed on this launch.
    var keepsHistory: Bool {
        guard let keeping, keeping.settings.failure == nil, resumable, you != nil else { return false }
        return server?.has("history") ?? true
    }

    /// Something kept changed: it is written within `keptSaveDelay`.
    func keptChanged() {
        guard keepsHistory, keptSave == nil else { return }
        keptSave = Task {
            try? await Task.sleep(for: Self.keptSaveDelay)
            guard !Task.isCancelled else { return }
            keptSave = nil
            await saveKept()
        }
    }

    /// Writes what is kept now, as the app goes to the background or the retention changes.
    public func flushKept() async {
        keptSave?.cancel()
        keptSave = nil
        await saveKept()
    }

    private func saveKept() async {
        guard let keeping, let account = keptAccount, let source = keptSource(now: environment.now()) else { return }
        let files = keeping.files, now = environment.now(), generation = keptGeneration
        let result: Result<Int, any Error> = await Task.detached {
            let data = Data(Archive.text(of: source, exportedAt: now).utf8)
            return Result { try files.write(data, for: account); return data.count }
        }.value
        // Deleted while it was written: what was written goes too. Signed out meanwhile, it stays.
        guard generation == keptGeneration else {
            keeping.files.remove(server: account.server, userID: account.userID)
            return
        }
        switch result {
        case .success(let bytes):
            keeping.settings.keptBytes[account] = bytes
        case .failure(let error as CocoaError) where error.code == .fileWriteOutOfSpace:
            keeping.settings.failure = "There isn’t enough space on this device to keep more history."
        case .failure:
            keeping.settings.failure = "History couldn’t be saved on this device."
        }
    }

    /// Lets go of what the session holds of the kept history, leaving the files: a sign-out, a
    /// sign-in as someone else, a refused token.
    func resetKept() {
        keptSave?.cancel()
        keptSave = nil
        restoring?.cancel()
        restoring = nil
        kept = store
        keptCoverage = [:]
        caughtUp = [:]
    }

    /// Deletes what is kept of `userID`'s history here (every account's with nil), and keeps
    /// only what the session holds from now on: what is loaded is kept again as it goes, as
    /// apron-web's Clear current user.
    func forgetKept(of userID: String?) {
        resetKept()
        keptGeneration += 1
        keeping?.files.remove(server: record.id, userID: userID)
        keeping?.settings.keptBytes = keeping?.settings.keptBytes.filter { $0.key.server != record.id || (userID != nil && $0.key.userID != userID) } ?? [:]
    }

    /// Preferences' Clear Current User: deletes this account's kept history.
    public func clearKept() {
        guard let you else { return }
        forgetKept(of: you.userID)
    }

    /// The account just signed in on a session that holds nothing yet, such as after a sign-out:
    /// shows what this device kept of it, as a launch would, so its next write keeps it.
    func restoreKeptOnSignIn(_ identity: UserObject) async {
        guard you == nil, keeping != nil, let plan = await keptPlan(of: identity.userID) else { return }
        adopt(plan, as: identity.userID)
    }

    /// What is written: every room with a record, each opened one with its stretch of records
    /// from where its kept log starts, clamped at the retention (by `log_id`, where positions are
    /// times) and, under Don't keep, at its newest 150 messages; and how each goes on.
    func keptSource(now: Date) -> ArchiveSource? {
        guard let you else { return nil }
        let rule = (keeping?.settings.retention ?? .forever).rule
        let cutoff = rule.age.map { LogID(time: now.addingTimeInterval(-$0)) }
        var rooms: [(id: String, stretch: ArchiveStretch)] = []
        var syncs: [String: JSONValue] = [:]
        for roomID in kept.roomIDs where kept.room(roomID) != nil || histories[roomID] != nil {
            guard let history = histories[roomID] else {
                rooms.append((roomID, .none))
                continue
            }
            var start = keptCoverage[roomID].map { $0.start } ?? history.olderBefore?.successor
            var older = keptCoverage[roomID]?.older ?? history.more
            if let cutoff, history.checkpoint?.isTimeLike ?? cutoff.isTimeLike, start.map({ $0 < cutoff }) ?? true {
                start = cutoff
                older = true
            }
            if let cap = rule.perRoom {
                let messages = kept.messages(in: roomID).filter { message in start.map { message.logID >= $0 } ?? true }
                if messages.count > cap {
                    start = messages.map(\.logID).sorted()[messages.count - cap]
                    older = true
                }
            }
            if history.isLive { caughtUp[roomID] = now }
            rooms.append((roomID, start.map(ArchiveStretch.from) ?? .fromOldest))
            let sync = KeptSync(checkpoint: history.checkpoint, start: start, older: older, floor: kept.floor(of: roomID), caughtUpAt: caughtUp[roomID])
            syncs[roomID] = sync.json
        }
        var media = [MediaGate.httpOrigin(of: record.url)].compactMap(\.self)
        media += (MediaLimits(server: server)?.origins ?? []).filter { !media.contains($0) }
        return ArchiveSource(server: record.url.absoluteString, you: you, media: media, store: kept,
                             users: users.userIDs.compactMap { users.user($0).flatMap(UserObject.init) },
                             joined: joinedRoomIDs, rooms: rooms, header: ["ladle_kept": ["rooms": .object(syncs)]], references: false)
    }
}
