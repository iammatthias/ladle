import Foundation
import Observation

/// The room and thread descriptions put away with their ×, as apron-web's `hideDescription`: each
/// by server and `room_id` (`DraftKey`), as a fingerprint of the text put away, so an edited
/// description pins itself again. The newest 200 are kept, in `hidden-descriptions.json` beside
/// `servers.json`; a file that cannot be read keeps none.
@MainActor
@Observable
public final class HiddenDescriptions {
    public static let limit = 200

    /// Oldest first.
    private var entries: [(key: DraftKey, fingerprint: String)] = []
    @ObservationIgnored private let fileURL: URL?

    /// `directory` nil keeps them in memory only.
    public init(directory: URL? = nil) {
        fileURL = directory?.appending(path: "hidden-descriptions.json")
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let json = try? JSONValue(parsing: data) else { return }
        entries = (json.arrayValue ?? []).compactMap { entry in
            guard let server = entry["server"]?.stringValue.flatMap(UUID.init(uuidString:)), let room = entry["room"]?.stringValue,
                  let fingerprint = entry["fingerprint"]?.stringValue else { return nil }
            return (DraftKey(server: server, roomID: room), fingerprint)
        }
    }

    /// Whether the description was put away as it now reads.
    public func isHidden(_ key: DraftKey, description: String) -> Bool {
        entries.last { $0.key == key }?.fingerprint == Self.fingerprint(description)
    }

    /// Puts the description away until it is edited or shown again.
    public func hide(_ key: DraftKey, description: String) {
        entries.removeAll { $0.key == key }
        entries.append((key, Self.fingerprint(description)))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        save()
    }

    /// The header's Description button: pins it again.
    public func show(_ key: DraftKey) {
        entries.removeAll { $0.key == key }
        save()
    }

    /// Forgets a server's, as it goes.
    public func removeAll(server: UUID) {
        entries.removeAll { $0.key.server == server }
        save()
    }

    /// apron-web's `descriptionFingerprint`: FNV-1a over the UTF-16 code units, in base 36.
    public nonisolated static func fingerprint(_ description: String) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for unit in description.utf16 { hash = (hash ^ UInt32(unit)) &* 0x0100_0193 }
        return String(hash, radix: 36)
    }

    private func save() {
        guard let fileURL else { return }
        let json = JSONValue.array(entries.map { entry in
            ["server": .string(entry.key.server.uuidString), "room": .string(entry.key.roomID), "fingerprint": .string(entry.fingerprint)]
        })
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.serializedData().write(to: fileURL, options: .atomic)
    }
}
