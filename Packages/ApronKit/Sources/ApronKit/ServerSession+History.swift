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
/// account per server, in ARCHIVE.md's form (`Archive`) with each room's catch-up under the
/// header's `ladle_kept`. It is written two seconds after a change, and at once as the app goes
/// to the background; a sign-out, a sign-in as someone else, or removing the server deletes it.
extension ServerSession {
    /// The longest a change waits to be written (apron-web's `FLUSH_MS`).
    static let keptSaveDelay: Duration = .seconds(2)

    /// Reads what was kept for this server's saved account, off the main actor, and shows it before
    /// the connection signs in (`run` waits for it).
    func restoreKept() {
        guard let keeping, restoring == nil, let account = record.account?.userID, hasSavedToken else { return }
        let files = keeping.files, server = record.id, retention = keeping.settings.retention, now = environment.now()
        restoring = Task {
            let plan = await Task.detached { files.read(server).flatMap { KeptRestore(data: $0, account: account, retention: retention, now: now) } }.value
            if let plan, !Task.isCancelled { adopt(plan) }
        }
    }

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
        guard keepsHistory, let keeping, let source = keptSource(now: environment.now()) else { return }
        let files = keeping.files, server = record.id, now = environment.now()
        let result: Result<Int, any Error> = await Task.detached {
            let data = Data(Archive.text(of: source, exportedAt: now).utf8)
            return Result { try files.write(data, for: server); return data.count }
        }.value
        // Signed out, or another account, while it was written: what was written goes.
        guard keepsHistory, you?.userID == source.you?.userID else {
            keeping.files.remove(record.id)
            return
        }
        switch result {
        case .success(let bytes):
            keeping.settings.keptBytes[record.id] = bytes
        case .failure(let error as CocoaError) where error.code == .fileWriteOutOfSpace:
            keeping.settings.failure = "There isn’t enough space on this device to keep more history."
        case .failure:
            keeping.settings.failure = "History couldn’t be saved on this device."
        }
    }

    /// Deletes what is kept for this server, and keeps only what the session holds from now on.
    func forgetKept() {
        keptSave?.cancel()
        keptSave = nil
        restoring?.cancel()
        kept = store
        keptCoverage = [:]
        caughtUp = [:]
        keeping?.files.remove(record.id)
        keeping?.settings.keptBytes[record.id] = nil
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
