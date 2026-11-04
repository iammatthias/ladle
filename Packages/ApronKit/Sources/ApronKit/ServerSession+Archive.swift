import Foundation

/// An archive ready to share, as apron-web's `ArchiveFile`.
public struct ArchiveExport: Sendable {
    public var name: String
    public var text: String
    public var rooms: Int
    public var messages: Int
    /// The private rooms left out, threads in them not counted.
    public var privateLeftOut: Int

    /// "Saved apron-chat.example-2026-10-27.jsonl: 12 messages in 3 rooms; 1 private room left
    /// out.", as apron-web's Preferences says it.
    public var words: String {
        func count(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }
        let leftOut = privateLeftOut > 0 ? "; \(count(privateLeftOut, "private room")) left out" : ""
        return "Saved \(name): \(count(messages, "message")) in \(count(rooms, "room"))\(leftOut)."
    }
}

extension Archive {
    /// `apron-chat.example-2026-10-27.jsonl`: the server's host and the day, in UTC, as
    /// apron-web's `archiveFileName`.
    public static func fileName(server: URL, date: Date) -> String {
        let host = (server.host(percentEncoded: false) ?? "") + (server.port.map { ":\($0)" } ?? "")
        let safe = host.lowercased()
            .replacingOccurrences(of: "[^a-z0-9.-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^[-.]+|[-.]+$", with: "", options: .regularExpression)
        let day = String(timestamp(date).prefix(10))
        return "apron-\(safe.isEmpty ? "" : "\(safe)-")\(day).jsonl"
    }

    /// The hosts an archive's media loads from, each once: what opening it asks about.
    public var mediaHosts: [String] {
        var seen = Set<String>()
        return media.compactMap { URL(string: $0)?.host(percentEncoded: false) }.filter { seen.insert($0).inserted }
    }
}

extension ServerSession {
    /// The archive of what this session holds of the server (apron-web's `exportArchive`): the
    /// rooms it has records of and their parents, each opened one with its unbroken stretch of
    /// records (the newest span the device holds, loaded or kept; a span loaded around an old
    /// message stays out, since an archive's stretch runs whole to the room's latest, ARCHIVE.md
    /// §3.1), the rest listed without one, and the messages its stretches reply to. Without
    /// `includingPrivate` (apron-web #171), private rooms, the threads in them, their records and
    /// anyone known only from them are left out. Statuses aren't kept: they are about now.
    public func exportArchive(includingPrivate: Bool, now: Date = Date()) -> ArchiveExport {
        var listed = Set(kept.roomIDs.filter { kept.room($0) != nil || histories[$0] != nil })
        for id in listed {
            var parent = kept.room(id)?.parentRoomID
            while let next = parent, listed.insert(next).inserted { parent = kept.room(next)?.parentRoomID }
        }
        func isPrivateAt(_ id: String) -> Bool {
            var at: String? = id
            for _ in 0 ..< 64 {
                guard let current = at else { return false }
                if kept.room(current)?.isPrivate == true { return true }
                at = kept.room(current)?.parentRoomID
            }
            return false
        }
        var privateLeftOut = 0
        var hidden = Set<String>()
        if !includingPrivate {
            for id in listed where isPrivateAt(id) {
                hidden.insert(id)
                if kept.room(id)?.parentRoomID == nil { privateLeftOut += 1 }
            }
            listed.subtract(hidden)
        }
        let paged = server?.has("history") ?? true
        let rooms: [(id: String, stretch: ArchiveStretch)] = listed.sorted(by: codePointLess).map { id in
            guard paged else { return (id, .fromOldest) }
            guard let history = histories[id], let start = keptSpans(of: id, history).coverage.newest?.lower else {
                return (id, histories[id] == nil ? .none : .fromOldest)
            }
            let floor = kept.floor(of: id)
            return (id, .from(floor.map { max($0, start) } ?? start))
        }
        var users = self.users.userIDs.compactMap { self.users.user($0).flatMap(UserObject.init) }
        if !includingPrivate {
            var seen = Set(you.map { [$0.userID] } ?? [])
            for (id, stretch) in rooms {
                seen.formUnion((kept.members(of: id) ?? []).map(\.userID))
                for entry in kept.logEntries(of: id) where stretch.holds(entry.logID) {
                    switch entry {
                    case .message(let message): seen.insert(message.from.userID)
                    case .reaction(let set): seen.insert(set.from.userID)
                    case .membership(let membership): seen.insert(membership.user.userID)
                    case .room: break
                    }
                }
            }
            users = users.filter { seen.contains($0.userID) }
        }
        var media = [MediaGate.httpOrigin(of: record.url)].compactMap(\.self)
        media += (MediaLimits(server: server)?.origins ?? []).filter { !media.contains($0) }
        let source = ArchiveSource(server: record.url.absoluteString, you: you, media: media, store: kept, users: users,
                                   joined: joinedRoomIDs, rooms: rooms, hiddenRooms: hidden)
        let messages = rooms.reduce(0) { total, room in total + kept.messages(in: room.id).filter { room.stretch.holds($0.logID) }.count }
        return ArchiveExport(name: Archive.fileName(server: record.url, date: now), text: Archive.text(of: source, exportedAt: now),
                             rooms: listed.count, messages: messages, privateLeftOut: privateLeftOut)
    }

    /// The address an export's session has, which no server holds (`.invalid`, RFC 2606): links
    /// to it stay in the viewer.
    public static let archiveURL = URL(string: "wss://archive.invalid/")!

    /// A session that reads `archive` read-only through an `ArchiveServer`, as apron-web's
    /// `/archive` page does: its media loads from the sites the archive names only `withImages`,
    /// and from nowhere else, whatever Preferences say, since a file says what it likes; the
    /// viewer's blocked sites in `mediaSettings` still never load, and Block there adds to them.
    /// Nothing is kept and no token saved. Start it, then sign in as a guest.
    public static func reading(_ archive: Archive, withImages: Bool, mediaSettings: MediaSettings = MediaSettings(),
                               environment: Environment = .live) -> ServerSession {
        var environment = environment
        environment.makeTransport = { _ in ArchiveServer(archive: archive, withImages: withImages) }
        let host = URL(string: archive.server)?.host(percentEncoded: false)
        let record = ServerRecord(url: archiveURL, label: host.map { "Export from \($0)" } ?? "Export")
        mediaSettings.holdExport()
        return ServerSession(record: record, tokens: InMemoryTokenStore(), mediaSettings: mediaSettings, environment: environment)
    }

    /// What an archive's server says of it (`ext:archive`, ARCHIVE.md §4.1), in place of the
    /// composer: "An export from chat.example, saved Oct 27, 2026 at 12:00 PM. It’s read-only."
    public var archiveNote: String? {
        guard let server, server.has("ext:archive"), let archive = server.ext?["archive"] else { return nil }
        let host = archive["server"]?.stringValue.flatMap { URL(string: $0)?.host(percentEncoded: false) }
        let saved = archive["exported_at"]?.stringValue.flatMap { text -> Date? in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        let when = saved.map { ", saved \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "An export from \(host ?? "an Apron server")\(when). It’s read-only."
    }
}
