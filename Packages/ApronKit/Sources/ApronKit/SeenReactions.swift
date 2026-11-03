import Foundation
import Observation

/// How far each account has seen the reactions to its own messages on this device, in
/// `reactions-seen.json` beside `servers.json`: Ladle's own (apron-web has no such news). Owned by
/// `SessionStore`, passed to every session, dropped with the server and moved on a rename, by
/// `ArrangementKey` as the rooms list's arrangement is.
///
/// Two marks, both reaction `log_id`s. A room's `baseline` is its head when this account first
/// saw it, so nothing from before shows as new. A message's `mark` is the newest reaction on it
/// that was on screen. On-screen-ness is per message, so one watermark per room would either hide
/// the unseen reactions further up once a newer one is seen, or never move; a mark per message
/// never does either. A reaction set is unseen when it is past both.
@MainActor
@Observable
public final class SeenReactions {
    /// The most messages marked per account; the oldest by `message_id` go first, and fall back
    /// to their room's baseline.
    public static let marksMax = 2000

    struct Kept: Equatable {
        var baselines: [String: LogID] = [:]
        var marks: [LogID: LogID] = [:]
    }

    private var kept: [ArrangementKey: Kept] = [:]
    @ObservationIgnored private let fileURL: URL?

    /// `directory` nil keeps it in memory only.
    public init(directory: URL? = nil) {
        fileURL = directory?.appending(path: "reactions-seen.json")
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let json = try? JSONValue(parsing: data) else { return }
        for entry in json.arrayValue ?? [] {
            guard let server = entry["server"]?.stringValue.flatMap(UUID.init(uuidString:)), let account = entry["account"]?.stringValue else { continue }
            var value = Kept()
            for (roomID, logID) in entry["baselines"]?.objectValue ?? [:] {
                if let logID = LogID(logID) { value.baselines[roomID] = logID }
            }
            for (messageID, logID) in entry["marks"]?.objectValue ?? [:] {
                if let messageID = LogID(messageID), let logID = LogID(logID) { value.marks[messageID] = logID }
            }
            kept[ArrangementKey(server: server, account: account)] = value
        }
    }

    /// The room's head when this account first saw it; nil before.
    public func baseline(of roomID: String, _ key: ArrangementKey) -> LogID? { kept[key]?.baselines[roomID] }

    /// The newest reaction seen on the message; nil when none was.
    public func mark(on messageID: LogID, _ key: ArrangementKey) -> LogID? { kept[key]?.marks[messageID] }

    /// Sets each room's baseline it does not have yet; one it has never moves.
    public func firstSight(_ heads: [String: LogID], _ key: ArrangementKey) {
        let new = heads.filter { kept[key]?.baselines[$0.key] == nil }
        guard !new.isEmpty else { return }
        kept[key, default: Kept()].baselines.merge(new) { kept, _ in kept }
        save()
    }

    /// Raises each message's mark to the reaction given, never lowering one.
    public func see(_ marks: [LogID: LogID], _ key: ArrangementKey) {
        var value = kept[key] ?? Kept()
        let before = value
        for (messageID, logID) in marks where value.marks[messageID].map({ $0 < logID }) ?? true {
            value.marks[messageID] = logID
        }
        if value.marks.count > Self.marksMax {
            for messageID in value.marks.keys.sorted().prefix(value.marks.count - Self.marksMax) { value.marks[messageID] = nil }
        }
        guard value != before else { return }
        kept[key] = value
        save()
    }

    /// The account took another `user_id` (§3.3.3): what it has seen goes with it.
    public func rename(server: UUID, from old: String, to new: String) {
        guard old != new, let moving = kept.removeValue(forKey: ArrangementKey(server: server, account: old)) else { return }
        kept[ArrangementKey(server: server, account: new)] = moving
        save()
    }

    /// Forgets a server's, as it goes.
    public func removeAll(server: UUID) {
        let before = kept.count
        kept = kept.filter { $0.key.server != server }
        if kept.count != before { save() }
    }

    private func save() {
        guard let fileURL else { return }
        let entries = kept.sorted { ($0.key.server.uuidString, $0.key.account) < ($1.key.server.uuidString, $1.key.account) }
        let json = JSONValue.array(entries.map { key, value in
            ["server": .string(key.server.uuidString), "account": .string(key.account),
             "baselines": .object(value.baselines.mapValues { .string($0.text) }),
             "marks": .object(Dictionary(uniqueKeysWithValues: value.marks.map { ($0.key.text, JSONValue.string($0.value.text)) }))]
        })
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.serializedData().write(to: fileURL, options: .atomic)
    }
}
