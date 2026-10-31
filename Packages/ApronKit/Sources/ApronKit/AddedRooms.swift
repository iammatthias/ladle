import Foundation
import Observation

/// The private rooms someone else added you to whose "You were added to this private room."
/// banner still shows, as apron-web's `loadAddedRooms`: by server and `room_id` (`DraftKey`), until
/// Dismiss or the × puts it away. The newest 200 are kept, in `added-rooms.json` beside
/// `servers.json`; a file that cannot be read keeps none.
@MainActor
@Observable
public final class AddedRooms {
    public static let limit = 200

    /// Oldest first.
    private var keys: [DraftKey] = []
    @ObservationIgnored private let fileURL: URL?

    /// `directory` nil keeps them in memory only.
    public init(directory: URL? = nil) {
        fileURL = directory?.appending(path: "added-rooms.json")
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let json = try? JSONValue(parsing: data) else { return }
        keys = (json.arrayValue ?? []).compactMap { entry in
            guard let server = entry["server"]?.stringValue.flatMap(UUID.init(uuidString:)), let room = entry["room"]?.stringValue else { return nil }
            return DraftKey(server: server, roomID: room)
        }
    }

    public func contains(_ key: DraftKey) -> Bool { keys.contains(key) }

    /// Someone added you to the room: its banner shows until dismissed. Added again, it shows again.
    public func add(_ key: DraftKey) {
        keys.removeAll { $0 == key }
        keys.append(key)
        if keys.count > Self.limit { keys.removeFirst(keys.count - Self.limit) }
        save()
    }

    public func dismiss(_ key: DraftKey) {
        guard keys.contains(key) else { return }
        keys.removeAll { $0 == key }
        save()
    }

    /// Forgets a server's, as it goes.
    public func removeAll(server: UUID) {
        keys.removeAll { $0.server == server }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        let json = JSONValue.array(keys.map { ["server": .string($0.server.uuidString), "room": .string($0.roomID)] })
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.serializedData().write(to: fileURL, options: .atomic)
    }
}
