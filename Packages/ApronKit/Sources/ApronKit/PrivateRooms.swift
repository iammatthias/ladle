import Foundation

/// Private rooms (§4.2.4) as people use them to talk, as apron-web's `private-rooms.ts`: the joined
/// top-level ones the rooms list shows under Private, the one you already have with someone,
/// starting one, adding people, and what a room someone else added you to says. Everything goes
/// by `private: true` and `parent_room_id`, never by a `room_id`, which is opaque (§2.4).

/// Someone who couldn't be added to a room, with the server's words why.
public struct Refusal: Hashable, Sendable {
    public let userID: String
    public let message: String

    public init(userID: String, message: String) {
        self.userID = userID
        self.message = message
    }

    /// "Couldn’t add Carol: Unknown user." for each, as apron-web's `couldNotAdd`.
    public static func words(_ refused: [Refusal], name: (String) -> String) -> String {
        refused.map { refusal in
            let reason = refusal.message.replacing(/[.\s]+$/, with: "")
            return "Couldn’t add \(name(refusal.userID)): \(reason)."
        }.joined(separator: " ")
    }
}

/// A private room just started, and anyone who couldn't be added to it.
public struct StartedRoom: Hashable, Sendable {
    public let roomID: String
    public let refused: [Refusal]
}

/// What starting or creating a private room can end in besides a refusal from the server.
public enum PrivateRoomError: Error, Hashable, Sendable, LocalizedError {
    /// The server keeps no private rooms (§4.2.4: it rejects one as `unsupported`).
    case noPrivateRooms
    /// New Room with Private on such a server: nothing was created.
    case noPrivateRoomsUncheck
    /// The room came back without `private: true`. It stays joined, for the user to leave.
    case notPrivate(title: String?)
    /// A thread of a private room came back visible to others.
    case threadNotPrivate
    /// The server named the room, but its record never arrived.
    case neverArrived

    public var errorDescription: String? {
        switch self {
        case .noPrivateRooms: "This server doesn’t have private rooms."
        case .noPrivateRoomsUncheck: "This server doesn’t keep private rooms. Uncheck Private to create an ordinary room."
        case .notPrivate(let title):
            "The server made \(title.map { "“\($0)”" } ?? "the new conversation") an ordinary room that others can see and join, not a private one. Leave it, or use it knowing that."
        case .threadNotPrivate:
            "The server made the new thread visible to people outside this private room, so nothing was posted into it. Leave it, or use it knowing that."
        case .neverArrived: "The new room never arrived. Look for it under Private."
        }
    }
}

/// The title of an untitled top-level private room, as apron-web's `peopleTitle`: its members
/// other than you by name, without bidi overrides, sorted ignoring case and accents, joined with
/// ", ". "You" when no one else is in it.
public enum PeopleTitle {
    /// While its members are unknown.
    public static let unknown = "Private room"

    public static func title(_ names: [String]) -> String {
        guard !names.isEmpty else { return "You" }
        return names.map(TextDirection.withoutOverrides).sorted(by: byName).joined(separator: ", ")
    }

    /// Ignoring case and accents, then by code point, so names that differ only so keep one order.
    static func byName(_ a: String, _ b: String) -> Bool {
        switch a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: codePointLess(a, b)
        }
    }

    /// The line under an untitled private room's name: who can see it, with the one other
    /// person's status where there is one, as apron-web's `privateRoomLine`.
    public static func line(others: [String], status: String?) -> String {
        guard let first = others.first else { return "Only you can see this room" }
        if others.count > 1 { return "Only members can see this room" }
        if let status { return "\(status) · only you and \(first) can see this room" }
        return "Only you and \(first) can see this room"
    }
}

/// The start of a private room's timeline, once its history reaches back to it: who it is with,
/// and one line about them.
public struct PrivateIntro: Hashable, Sendable {
    public let name: String
    /// The others in it, or you, alone in it.
    public let faces: [UserObject]
    /// One person's `@user_id` and the first line of their bio, or "3 members".
    public let detail: String?
}

/// Rooms that arrived joined without this device asking, as apron-web's `ArrivalWatch`: someone
/// else added you to them, perhaps while you were away. The first listing for an account is the
/// baseline; each later listing or `room_update` is compared with the last. A room joined on
/// another device of yours arrives the same way, as membership records don't say who made a
/// change (§4.2.2).
struct ArrivalWatch {
    private var user: String?
    private var known: Set<String> = []
    private var mine: Set<String> = []
    /// Rooms being created: one arriving meanwhile may be the one asked for, before its `room_id`
    /// is known.
    var creating = 0
    /// This sign-in's rooms are listed: until then the joined set is incomplete.
    var listed = false

    /// A room this device started or joined, which never counts as added.
    mutating func mine(_ roomID: String) { mine.insert(roomID) }

    /// The rooms in `joined` that arrived since the last call without being asked for.
    mutating func next(you: String, joined: Set<String>) -> [String] {
        defer { known = joined }
        guard you == user else {
            user = you
            return []
        }
        guard creating == 0 else { return [] }
        return joined.subtracting(known).subtracting(mine).sorted(by: codePointLess)
    }
}

extension ServerInfo {
    /// The most top-level private rooms one user may be in at once: `ext.settings.private_rooms`
    /// under `ext:settings`, a count. Nil states no limit.
    public var privateRoomLimit: Int? {
        guard has("ext:settings"), let limit = ext?["settings"]?["private_rooms"]?.intValue, limit >= 0 else { return nil }
        return limit
    }
}

extension ServerSession {
    /// How long starting a room waits for its record after the server named it.
    static let recordWait: Duration = .seconds(10)

    /// A joined top-level private room: listed under Private, and counted against the limit.
    public func isPrivateRoom(_ roomID: String) -> Bool {
        guard let room = store.room(roomID) else { return false }
        return joinedRoomIDs.contains(roomID) && room.isPrivate == true && room.parentRoomID == nil
    }

    /// An untitled top-level private room, which is named for its members.
    public func isNamedForMembers(_ roomID: String) -> Bool {
        guard let room = store.room(roomID), room.isPrivate == true, room.parentRoomID == nil else { return false }
        return (room.title?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The room's members other than you; empty while they aren't known.
    public func others(in roomID: String) -> [UserObject] {
        (store.members(of: roomID) ?? []).filter { !isYou($0.userID) }
    }

    /// Who a private room is with: the others in it, or you, alone in it.
    public func faces(of roomID: String) -> [UserObject] {
        let others = others(in: roomID)
        if !others.isEmpty { return others.sorted { PeopleTitle.byName(users.plainName(for: $0), users.plainName(for: $1)) } }
        return you.map { [$0] } ?? []
    }

    /// An untitled private room's title: who else is in it ("Dev, Mira"), "You", or "Private
    /// room" while its members are unknown.
    func membersTitle(_ roomID: String) -> String {
        guard store.members(of: roomID) != nil else { return PeopleTitle.unknown }
        return PeopleTitle.title(others(in: roomID).map { users.plainName(for: $0) })
    }

    /// The line under an untitled private room's name in its header.
    public func privateLine(_ roomID: String) -> String? {
        guard isNamedForMembers(roomID) else { return nil }
        let others = others(in: roomID)
        let status = others.count == 1 ? Presence.words(users.user(others[0].userID)?["status"]?.stringValue, yours: false) : nil
        return PeopleTitle.line(others: others.map { users.plainName(for: $0) }, status: status)
    }

    /// The private rooms the rooms list shows under Private, by title.
    public var privateRoomIDs: [String] {
        joinedRoomIDs.filter(isPrivateRoom).sorted { codePointLess(title(of: $0), title(of: $1)) }
    }

    /// Private rooms by how long they've been quiet, the quietest (oldest activity, or none known) first.
    public var privateRoomsQuietestFirst: [String] {
        privateRoomIDs.sorted { a, b in
            switch (activity(of: a), activity(of: b)) {
            case (nil, nil): codePointLess(a, b)
            case (nil, _): true
            case (_, nil): false
            case (let x?, let y?): x < y
            }
        }
    }

    /// Private rooms you are in, of the most the server allows: "2 of 5". Nil without a limit.
    public var privateRoomQuota: (used: Int, max: Int)? {
        server?.privateRoomLimit.map { (privateRoomIDs.count, $0) }
    }

    /// A room offered to leave at the limit says when it was last active: "Active now", "Last
    /// active 3d ago", "Last active 9w".
    public func lastActiveDetail(of roomID: String, now: Date) -> String? {
        guard let active = lastActive(of: roomID) else { return nil }
        let since = LastActive.words(active, now: now)
        if since == "now" { return "Active now" }
        return since.wholeMatch(of: /[0-9]+[mhd]/) != nil ? "Last active \(since) ago" : "Last active \(since)"
    }

    public var atPrivateRoomLimit: Bool {
        privateRoomQuota.map { $0.used >= $0.max } ?? false
    }

    /// The conversation you already have with someone: joined, private, top-level and untitled,
    /// with exactly the two of you as members, from a complete listing: a truncated one
    /// (`member_count`) says nothing for sure.
    public func directRoom(with userID: String) -> String? {
        guard let you, !isYou(userID) else { return nil }
        let id = users.current(userID)
        return privateRoomIDs.first { roomID in
            guard isNamedForMembers(roomID), let members = store.members(of: roomID),
                  store.memberCount(of: roomID) == nil else { return false }
            let ids = Set(members.map { users.current($0.userID) })
            return ids == [you.userID, id]
        }
    }

    /// Starting a private conversation: an account (not a guest), signed in and allowed to write,
    /// on a server that creates rooms (capability `rooms`).
    public var mayStartPrivate: Bool {
        status == .signedIn && server?.has("rooms") == true && mayWrite && you != nil && !isGuest
    }

    /// Whether the room's loaded history reaches back to its creation, where the intro goes: all
    /// of it is loaded, and the least position still retrievable is at or before the room's first
    /// record seen, or nothing is retrievable at all.
    public func reachesStart(_ roomID: String) -> Bool {
        guard let history = histories[roomID], !history.isLoading, !canLoadOlder(roomID) else { return false }
        guard let floor = store.floor(of: roomID) else { return true }
        guard let start = store.firstRecordLogID(of: roomID) ?? store.room(roomID)?.logID else { return false }
        return floor <= start
    }

    /// The intro card at the head of an open top-level private room whose history reaches its start.
    public func privateIntro(_ roomID: String) -> PrivateIntro? {
        guard let room = store.room(roomID), room.isPrivate == true, room.parentRoomID == nil, reachesStart(roomID) else { return nil }
        let others = others(in: roomID)
        let detail: String?
        if isNamedForMembers(roomID), others.count == 1 {
            let one = others[0]
            let bio = keepsBio ? Bio.of(users.user(one.userID) ?? one.json)?.split(separator: "\n").first.map(String.init) : nil
            detail = "@\(users.current(one.userID))" + (bio.map { " · \($0)" } ?? "")
        } else {
            let count = store.members(of: roomID)?.count ?? 0
            detail = count == 0 ? nil : count == 1 ? "1 member" : "\(count) members"
        }
        return PrivateIntro(name: title(of: roomID), faces: faces(of: roomID), detail: detail)
    }

    /// The room someone else added you to shows its banner, until dismissed.
    public func wasAdded(to roomID: String) -> Bool {
        isPrivateRoom(roomID) && addedRooms.contains(DraftKey(server: record.id, roomID: roomID))
    }

    public func dismissAdded(_ roomID: String) {
        addedRooms.dismiss(DraftKey(server: record.id, roomID: roomID))
    }

    // MARK: Starting

    /// Starts a private room with `people`: `room_set` with `private: true` (and the title, if
    /// any) and no `parent_room_id` (§4.2.4), which joins you; then, once its record says it is
    /// private, adds each person in turn. A room that came back public adds no one and throws.
    /// One add that fails doesn't stop the rest: the room is kept, and the result says who and why.
    public func startPrivateRoom(with people: [String], title: String? = nil) async throws -> StartedRoom {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var params: [String: JSONValue] = ["private": true]
        if let title { params["title"] = .string(title) }
        let roomID: String
        do {
            roomID = try await createRoom(params)
        } catch let error as RPCError where error.code == RPCError.Code.unsupported {
            throw PrivateRoomError.noPrivateRooms
        }
        guard let room = await record(of: roomID) else { throw PrivateRoomError.neverArrived }
        guard room.isPrivate == true else { throw PrivateRoomError.notPrivate(title: title) }
        return StartedRoom(roomID: roomID, refused: await addMembers(people, to: roomID))
    }

    /// Where a message to someone goes, as a profile card's Message and a member's Direct Message
    /// send it: the private conversation you already have with them, else one started with them.
    public func message(_ userID: String) async throws -> StartedRoom {
        if let existing = directRoom(with: userID) { return StartedRoom(roomID: existing, refused: []) }
        return try await startPrivateRoom(with: [users.current(userID)])
    }

    /// Adds each person to the room in turn (`room_join` with their `user_id`, §4.2.2). Who may
    /// add whom is server policy: one it refuses doesn't stop the rest, and comes back with why.
    public func addMembers(_ userIDs: [String], to roomID: String) async -> [Refusal] {
        var refused: [Refusal] = []
        for userID in userIDs {
            do { try await addMember(userID, to: roomID) } catch {
                refused.append(Refusal(userID: userID, message: (error as? RPCError)?.message ?? "Unable to add them"))
            }
        }
        return refused
    }

    /// Adds a private room's other members to a thread just started in it, as apron-web's
    /// `includeMembers`: the thread is private too, so without this the people you talk to in the
    /// room never see it. Says who couldn't be added, if anyone.
    public func includeMembers(of roomID: String, in threadID: String) async -> String? {
        guard isPrivate(roomID) else { return nil }
        let refused = await addMembers(others(in: roomID).map { users.current($0.userID) }, to: threadID)
        return refused.isEmpty ? nil : Refusal.words(refused) { users.plainName(for: UserObject(["user_id": .string($0)])!) }
    }

    /// Sends `room_set` without a `room_id`, as a room this device asked for, and returns the new `room_id`.
    func createRoom(_ params: [String: JSONValue]) async throws -> String {
        try require("rooms")
        arrivals.creating += 1
        defer { arrivals.creating -= 1 }
        let result = try await request("room_set", .object(params))
        guard let roomID = OpaqueID.validated(result["room_id"]) else { throw RPCError(code: RPCError.Code.internalError, message: "Invalid room response") }
        arrivals.mine(roomID)
        return roomID
    }

    /// The room's record, once it arrives: results can resume before the notifications sent ahead of them.
    func record(of roomID: String) async -> RoomRecord? {
        let deadline = ContinuousClock.now + Self.recordWait
        while store.room(roomID) == nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return store.room(roomID)
    }

    /// After a listing or a `room_update`: the top-level private rooms someone else added you to get their banner.
    func noteArrivals() {
        guard let you, server?.has("rooms") == true, arrivals.listed else { return }
        for roomID in arrivals.next(you: you.userID, joined: joinedRoomIDs) where isPrivateRoom(roomID) {
            addedRooms.add(DraftKey(server: record.id, roomID: roomID))
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
