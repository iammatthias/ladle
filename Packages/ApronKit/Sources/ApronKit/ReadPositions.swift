import Foundation
import Synchronization

/// How far this user has read each room on this device, as apron-web's `readPositions`: kept by
/// server, account and room, moved only forward, and never sent to the server. It places the
/// New line on the next visit and counts unread on a server that keeps no read cursors.
public protocol ReadPositionStore: Sendable {
    /// Every position kept for one account, by `room_id`.
    func positions(server: UUID, user: String) -> [String: LogID]
    /// Keeps `position` for the room if it is further than the one kept.
    func advance(_ roomID: String, to position: LogID, server: UUID, user: String)
}

/// `read-positions.json` in the store's directory: `{server id: {user id: {room id: message id}}}`,
/// written whole and atomically. A file that cannot be read or written is treated as empty, as
/// apron-web treats blocked storage.
public struct FileReadPositionStore: ReadPositionStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "read-positions.json")
    }

    public func positions(server: UUID, user: String) -> [String: LogID] {
        (load()[server.uuidString]?[user] ?? [:]).compactMapValues(LogID.init)
    }

    public func advance(_ roomID: String, to position: LogID, server: UUID, user: String) {
        var all = load()
        let kept = all[server.uuidString, default: [:]][user, default: [:]][roomID].flatMap(LogID.init)
        if let kept, kept >= position { return }
        all[server.uuidString, default: [:]][user, default: [:]][roomID] = position.text
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() -> [String: [String: [String: String]]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: [String: String]]] ?? [:]
    }
}

public final class InMemoryReadPositionStore: ReadPositionStore {
    private let kept = Mutex<[UUID: [String: [String: LogID]]]>([:])

    public init() {}

    public func positions(server: UUID, user: String) -> [String: LogID] {
        kept.withLock { $0[server]?[user] ?? [:] }
    }

    public func advance(_ roomID: String, to position: LogID, server: UUID, user: String) {
        kept.withLock { all in
            if let current = all[server]?[user]?[roomID], current >= position { return }
            all[server, default: [:]][user, default: [:]][roomID] = position
        }
    }
}
