import Foundation

/// Managing a room's members, as apron-web's MemberList (#129, #152, #153, #161): adding people
/// with the picker, removing someone after a confirmation, and each member's menu.

/// What a member's row menu offers beside Profile: Direct Message and Remove from Room. Your own
/// row offers neither, so a long press there opens no menu and a tap opens your card.
public struct MemberMenu: Hashable, Sendable {
    public let directMessage: Bool
    public let remove: Bool

    public var isEmpty: Bool { !directMessage && !remove }
}

extension ServerSession {
    /// Adding and removing other members (`room_join` and `room_leave` with `user_id`, §4.2.2):
    /// signed in with `rooms`, allowed to write, in the room, until the server says it doesn't
    /// support it. Who may is the server's policy, and its refusal shows.
    public func mayChangeMembers(of roomID: String) -> Bool {
        status == .signedIn && server?.has("rooms") == true && mayWrite && joinedRoomIDs.contains(roomID) && !memberChangesUnsupported
    }

    /// Adding others: with `add_members` (`ext:permissions`, or without that extension), or to a
    /// private room you are a member of, whose members add people to it (§4.2.4).
    public func mayAddMembers(to roomID: String) -> Bool {
        mayChangeMembers(of: roomID) && (permissions.addMembers || isPrivate(roomID))
    }

    /// A member's menu: Direct Message to anyone but you and the system identities where you may
    /// start a private room; Remove on anyone but you where members may change.
    public func memberMenu(for userID: String, in roomID: String) -> MemberMenu {
        let yours = isYou(userID), system = userID.hasPrefix("~")
        return MemberMenu(directMessage: mayStartPrivate && !yours && !system, remove: mayChangeMembers(of: roomID) && !yours)
    }

    /// The member list's note once the server said it doesn't support adding or removing others,
    /// where they would otherwise be offered.
    public func memberChangesRemark(in roomID: String) -> String? {
        guard memberChangesUnsupported, status == .signedIn, server?.has("rooms") == true, mayWrite, joinedRoomIDs.contains(roomID) else { return nil }
        return "This server doesn’t let members add or remove others."
    }

    /// Removes someone from a room (§4.2.2): `room_leave` with their `user_id`.
    public func removeMember(_ userID: String, from roomID: String) async throws {
        try await changeMember("room_leave", userID, roomID)
    }

    /// "Remove Ada from general?", as the web asks before removing.
    public func removeQuestion(_ userID: String, from roomID: String) -> String {
        "Remove \(pickedName(userID)) from \(title(of: roomID))?"
    }

    func changeMember(_ method: String, _ userID: String, _ roomID: String) async throws {
        try require("rooms")
        do {
            _ = try await request(method, ["room_id": .string(roomID), "user_id": .string(userID)])
        } catch let error as RPCError where error.code == RPCError.Code.unsupported {
            memberChangesUnsupported = true
            throw error
        }
    }
}
