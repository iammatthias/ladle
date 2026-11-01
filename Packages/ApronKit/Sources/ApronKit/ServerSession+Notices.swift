extension ServerSession {
    /// The first room of the rooms list, where a notice without `room_id` shows, such as the
    /// welcome a server sends before `auth` (Appendix B.1), as apron-web shows one in its first
    /// joined room.
    public var firstRoom: String? { (publicRoomTree.first ?? privateRoomTree.first)?.roomID }

    /// The notices a room's timeline shows, oldest first: its own, and in the first room those
    /// that came without one.
    public func notices(in roomID: String) -> [Notice] {
        let first = firstRoom
        return notices.filter { $0.roomID == roomID || ($0.roomID == nil && roomID == first) }
    }
}
