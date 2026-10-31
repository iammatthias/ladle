import Foundation
import Observation

/// How long history is kept on this device, as apron-web's `RETENTIONS` (#137), by when it was
/// logged, on servers whose positions are times. "Don't keep" still keeps the last view, as
/// apron-web's `session-cache.ts` does: a day of messages, the newest 150 per room.
public enum HistoryRetention: String, CaseIterable, Sendable {
    case off
    case day = "1"
    case week = "7"
    case month = "30"
    case year = "365"
    case forever = "all"

    public static let `default` = HistoryRetention.month

    public var label: String {
        switch self {
        case .off: "Don’t keep"
        case .day: "A day"
        case .week: "A week"
        case .month: "30 days"
        case .year: "A year"
        case .forever: "Forever"
        }
    }

    /// The label title-cased, as a title shows it: "30 Days", "Don’t Keep".
    public var title: String {
        label.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// What is kept: records logged since `age` ago (all of them when nil), at most `perRoom`
    /// messages in each room (any number when nil).
    public var rule: (age: TimeInterval?, perRoom: Int?) {
        let day: TimeInterval = 24 * 60 * 60
        switch self {
        case .off: return (day, 150)
        case .day: return (day, nil)
        case .week: return (7 * day, nil)
        case .month: return (30 * day, nil)
        case .year: return (365 * day, nil)
        case .forever: return (nil, nil)
        }
    }
}

/// The retention chosen on this device, for every server, as apron-web's `HistorySettings`: kept
/// in `history-settings.json` beside `servers.json`, a file that cannot be read giving the
/// default. Also why keeping stopped, and how much each server's kept history takes.
@MainActor
@Observable
public final class HistorySettings {
    public private(set) var retention: HistoryRetention = .default
    /// Why history stopped being kept on this launch, such as a full disk.
    public internal(set) var failure: String?
    /// The size of each server's kept history as last written, in bytes.
    public internal(set) var keptBytes: [UUID: Int] = [:]

    @ObservationIgnored private let fileURL: URL?

    /// `directory` nil keeps the choice in memory only.
    public init(directory: URL? = nil) {
        fileURL = directory?.appending(path: "history-settings.json")
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let json = try? JSONValue(parsing: data),
              let saved = json["retention"]?.stringValue.flatMap(HistoryRetention.init(rawValue:)) else { return }
        retention = saved
    }

    public func update(_ retention: HistoryRetention) {
        self.retention = retention
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONValue.object(["retention": .string(retention.rawValue)]).serializedData().write(to: fileURL, options: .atomic)
    }

    /// About how much history this device keeps, every server's together, in words ("12 MB"), as
    /// apron-web's `storageUsed`; nil before anything is written.
    public var used: String? {
        guard !keptBytes.isEmpty else { return nil }
        return Self.words(bytes: keptBytes.values.reduce(0, +))
    }

    public nonisolated static func words(bytes: Int) -> String {
        let megabyte = 1024.0 * 1024
        if Double(bytes) < megabyte { return "under 1 MB" }
        let megabytes = Double(bytes) / megabyte
        return megabytes < 1024 ? "\(Int(megabytes.rounded())) MB" : String(format: "%.1f GB", megabytes / 1024)
    }
}

/// Where each server's kept history is: one file per server, for the one account signed in there.
public protocol HistoryFiles: Sendable {
    func read(_ server: UUID) -> Data?
    func write(_ data: Data, for server: UUID) throws
    func remove(_ server: UUID)
}

/// Kept history in `History/<server id>.jsonl` beside `servers.json`. The folder is excluded from
/// backup: the server holds what it holds, and a backup would keep a signed-out account's chats.
public struct FileHistoryFiles: HistoryFiles {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.appending(path: "History", directoryHint: .isDirectory)
    }

    private func file(_ server: UUID) -> URL { directory.appending(path: "\(server.uuidString).jsonl") }

    public func read(_ server: UUID) -> Data? { try? Data(contentsOf: file(server)) }

    public func write(_ data: Data, for server: UUID) throws {
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        try data.write(to: file(server), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func remove(_ server: UUID) { try? FileManager.default.removeItem(at: file(server)) }
}

/// Kept history in memory, for tests and previews.
public final class InMemoryHistoryFiles: HistoryFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [UUID: Data] = [:]

    public init() {}

    public func read(_ server: UUID) -> Data? { lock.withLock { files[server] } }
    public func write(_ data: Data, for server: UUID) throws { lock.withLock { files[server] = data } }
    public func remove(_ server: UUID) { _ = lock.withLock { files.removeValue(forKey: server) } }
}

/// How a kept room goes on: from its checkpoint, with its kept log reaching down to `start`
/// (nil: to the start of the room's log, when `older` is false), and whether the server has
/// older below that. Kept under the archive header's `ladle_kept` key.
public struct KeptSync: Hashable, Sendable {
    public var checkpoint: LogID?
    public var start: LogID?
    public var older: Bool
    public var floor: LogID?
    /// When the room was last caught up, on this device.
    public var caughtUpAt: Date?

    var json: JSONValue {
        var fields: [String: JSONValue] = ["older": .bool(older)]
        fields["checkpoint"] = checkpoint?.json
        fields["start"] = start?.json
        fields["floor"] = floor?.json
        fields["caught_up_at"] = caughtUpAt.map { .number(String(Int64(($0.timeIntervalSince1970 * 1000).rounded()))) }
        return .object(fields)
    }

    init(checkpoint: LogID?, start: LogID?, older: Bool, floor: LogID?, caughtUpAt: Date?) {
        self.checkpoint = checkpoint
        self.start = start
        self.older = older
        self.floor = floor
        self.caughtUpAt = caughtUpAt
    }

    init(json: JSONValue) {
        checkpoint = LogID(json["checkpoint"])
        start = LogID(json["start"])
        older = json["older"]?.boolValue ?? false
        floor = LogID(json["floor"])
        caughtUpAt = json["caught_up_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// What a session restores from its kept history, planned as apron-web's `restoredState` and
/// `plannedRoom`: each kept room within the retention, its log clamped at the cutoff, and the
/// newest `window` entries of it to show; older entries page in from the device first.
public struct KeptRestore: Sendable {
    /// How many of a room's newest entries a restore shows (apron-web's `RESTORE_WINDOW`).
    public static let window = 50

    public var you: UserObject
    public var users: [UserObject]
    public var joined: Set<String>
    /// The listed rooms' records and deliveries, members seeded.
    public var listing: Records
    /// Everything kept within the retention: what device paging reads.
    public var kept: ReplayStore
    /// Each restored room's history: its newest window loaded, its sync.
    public var rooms: [String: (history: RoomHistory, window: [LogEntry], sync: KeptSync)]

    /// Nil for a file that isn't a kept history of `account`.
    public init?(data: Data, account: String, retention: HistoryRetention, now: Date) {
        guard let text = String(data: data, encoding: .utf8), let archive = try? Archive(text: text),
              let you = archive.you, you.userID == account else { return nil }
        self.you = you
        users = archive.users
        joined = Set(archive.rooms.filter(\.joined).map(\.record.roomID))
        let byID = Dictionary(archive.users.map { ($0.userID, $0) }, uniquingKeysWith: { $1 })
        let syncs = (archive.header["ladle_kept"]?["rooms"]?.objectValue ?? [:]).mapValues(KeptSync.init(json:))
        let cutoff = retention.rule.age.map { now.addingTimeInterval(-$0) }

        var planned: [String: KeptSync] = [:]
        listing = Records()
        for room in archive.rooms {
            var delivery = RoomDelivery()
            delivery.latestLogID = room.latest
            delivery.members = room.members?.map { byID[$0] ?? UserObject(["user_id": .string($0)])! }
            delivery.floor = syncs[room.record.roomID]?.floor
            listing.rooms.append((room.record, delivery))
            guard var sync = syncs[room.record.roomID] else { continue }
            if let cutoff, let checkpoint = sync.checkpoint, checkpoint.isTimeLike {
                // Not caught up since before the cutoff: paging forward from there would fetch everything since.
                if (sync.caughtUpAt ?? checkpoint.date) < cutoff { continue }
                let bound = LogID(time: cutoff)
                if sync.start.map({ $0 < bound }) ?? true {
                    sync.start = bound
                    sync.older = true
                }
            }
            planned[room.record.roomID] = sync
        }

        func holds(_ roomID: String?, _ logID: LogID) -> Bool {
            guard let roomID, let sync = planned[roomID] else { return false }
            return sync.start.map { logID >= $0 } ?? true
        }
        var records = Records()
        let homes = Dictionary(archive.records.messages.map { ($0.messageID, $0.roomID) }, uniquingKeysWith: { $1 })
        records.rooms = archive.records.rooms.filter { holds($0.record.roomID, $0.record.logID!) }
        records.messages = archive.records.messages.filter { holds($0.roomID, $0.logID) }
        records.reactions = archive.records.reactions.filter { holds(homes[$0.messageID] ?? $0.roomID, $0.logID) }
        records.memberships = archive.records.memberships.filter { holds($0.roomID, $0.logID) }
        kept = ReplayStore()
        kept.apply(listing)
        kept.apply(records)
        for (roomID, sync) in planned { if let floor = sync.floor { kept.raiseFloor(of: roomID, to: floor) } }

        rooms = [:]
        for (roomID, sync) in planned {
            let log = kept.logEntries(of: roomID)
            let (page, below) = LogEntry.slice(log, limit: Self.window)
            var history = RoomHistory()
            history.checkpoint = sync.checkpoint
            if let first = page.first {
                history.olderBefore = first.logID.predecessor
                history.more = below || sync.older
            } else {
                history.olderBefore = sync.start?.predecessor
                history.more = sync.older && history.olderBefore != nil
            }
            if history.olderBefore == nil { history.more = false }
            rooms[roomID] = (history, Array(page), sync)
        }
    }
}

extension LogID {
    /// The earliest time a `log_id` reads as (apron-web's `EARLIEST_TIME`, 2000-01-01 UTC):
    /// before it, a server counts its positions some other way.
    static let earliestTime: UInt64 = 946_684_800_000

    /// Whether the position reads as a time (epoch milliseconds).
    var isTimeLike: Bool { UInt64(text)! >= Self.earliestTime }

    var date: Date { Date(timeIntervalSince1970: Double(UInt64(text)!) / 1000) }

    /// The position a time reads as.
    init(time: Date) {
        self.init(String(max(1, Int64((time.timeIntervalSince1970 * 1000).rounded(.down)))))!
    }
}
