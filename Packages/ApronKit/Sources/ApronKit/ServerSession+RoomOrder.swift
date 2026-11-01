import Foundation

/// The rooms list's order and folds, as apron-web's Sidebar (#145, #148, #151, #160).
extension ServerSession {
    /// This account's arrangement; nil before anyone has signed in here.
    var arrangementKey: ArrangementKey? {
        (you?.userID ?? record.account?.userID).map { ArrangementKey(server: record.id, account: $0) }
    }

    /// A room listed for the first time takes the next place, so the order holds from then on.
    func placeNewRooms() {
        guard let key = arrangementKey else { return }
        roomArrangement.adopt(roomTree.map(\.roomID), key)
    }

    /// Alt+↑/↓: moves a top-level room one place among `shown`, the rooms its section shows.
    /// Whether it moved.
    @discardableResult
    public func moveRoom(_ roomID: String, by step: Int, among shown: [String]) -> Bool {
        guard let key = arrangementKey,
              let next = RoomOrder.stepping(roomArrangement.order(key), roomID, among: shown, by: step) else { return false }
        roomArrangement.setOrder(next, key)
        return true
    }

    /// A drag, as `List.onMove` reports it over `shown`: the room lands after the one now shown
    /// before it, so rooms the section hides keep their places.
    public func moveRooms(_ shown: [String], fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let key = arrangementKey, source.count == 1, let from = source.first, shown.indices.contains(from) else { return }
        let index = destination > from ? destination - 1 : destination
        roomArrangement.setOrder(RoomOrder.dropping(roomArrangement.order(key), shown[from], at: index, among: shown), key)
    }

    /// The top-level room the rooms list shows a room or thread under.
    public func topLevelRoom(of roomID: String) -> String {
        store.room(roomID)?.parentRoomID.flatMap { joinedRoomIDs.contains($0) ? $0 : nil } ?? roomID
    }

    /// News in the room or in a thread of it you have joined, as apron-web's `hasNews`.
    public func hasNews(_ node: RoomNode) -> Bool {
        let news = { (id: String) in self.unreadCount(in: id) > 0 || self.mentionCount(in: id) > 0 }
        return news(node.roomID) || node.threadIDs.contains { joinedRoomIDs.contains($0) && news($0) }
    }

    /// A section's rooms; folded, only those with news and the one open (`open` is the room or
    /// thread open), which reading would otherwise take away.
    public func shownRooms(_ nodes: [RoomNode], folded: Bool, open: String?) -> [RoomNode] {
        guard folded else { return nodes }
        let openRoom = open.map(topLevelRoom(of:))
        return nodes.filter { $0.roomID == openRoom || hasNews($0) }
    }

    /// Whether the room's threads are folded to those with news, as under a room not open.
    public func threadsFolded(_ roomID: String) -> Bool {
        arrangementKey.map { roomArrangement.threadsFolded(roomID, $0) } ?? false
    }

    /// Picking the open room again folds its threads, and once more (or its …) unfolds them.
    public func foldThreads(_ roomID: String, _ folded: Bool) {
        guard let key = arrangementKey else { return }
        roomArrangement.foldThreads(roomID, folded, key)
    }
}
