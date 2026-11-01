import Foundation
import Observation

/// apron-web's `room-order.svelte.ts` (#151, #160): the order of the rooms list's top-level
/// rooms, as `room_id`s. Rooms and Private share the one order, each section listing its own
/// rooms in it.
public enum RoomOrder {
    /// Past this many kept places, the rooms no longer listed are let go.
    public static let keptMax = 300

    /// `rooms` in `order`: those it places by their place, then the rest as given, so a room it
    /// has not seen goes last and nothing arranged moves.
    public static func inOrder(_ rooms: [String], _ order: [String]) -> [String] {
        let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = rooms.filter { place[$0] != nil }.sorted { place[$0]! < place[$1]! }
        return placed + rooms.filter { place[$0] == nil }
    }

    public enum Side: Sendable { case before, after }

    /// `order` with `id` moved to just before or after `target`, which stays put; unchanged if
    /// either is not in it.
    public static func moveNext(_ order: [String], _ id: String, _ target: String, _ side: Side) -> [String] {
        guard id != target, order.contains(id), order.contains(target) else { return order }
        var rest = order.filter { $0 != id }
        let at = rest.firstIndex(of: target)! + (side == .after ? 1 : 0)
        rest.insert(id, at: at)
        return rest
    }

    /// `order` with the `listed` rooms it has not placed yet after the others. Over `keptMax`,
    /// only the listed ones stay.
    public static func adopting(_ listed: [String], into order: [String]) -> [String] {
        let known = Set(order)
        let added = listed.filter { !known.contains($0) }
        guard !added.isEmpty else { return order }
        let next = order + added
        guard next.count > keptMax else { return next }
        let shown = Set(listed)
        return next.filter(shown.contains)
    }

    /// Alt+↑/↓: `id` one place up (`by` -1) or down among `shown`, the rooms listed with it, past
    /// the next one shown, so rooms a folded section hides keep their places. Nil if it cannot.
    public static func stepping(_ order: [String], _ id: String, among shown: [String], by: Int) -> [String]? {
        guard let at = shown.firstIndex(of: id), shown.indices.contains(at + by) else { return nil }
        return moveNext(order, id, shown[at + by], by < 0 ? .before : .after)
    }

    /// A drop: `shown` as the list showed them, `id` now at `index` among them. It goes after the
    /// room shown before it, or before the one after it at the top, as apron-web's `finalize`.
    public static func dropping(_ order: [String], _ id: String, at index: Int, among shown: [String]) -> [String] {
        var landed = shown.filter { $0 != id }
        landed.insert(id, at: min(max(index, 0), landed.count))
        let at = landed.firstIndex(of: id)!
        if at > 0 { return moveNext(order, id, landed[at - 1], .after) }
        if landed.count > 1 { return moveNext(order, id, landed[1], .before) }
        return order
    }
}

/// Which account on which server an arrangement is: Ladle holds one account per server, and a
/// sign-in as another starts its own.
public struct ArrangementKey: Hashable, Sendable {
    public var server: UUID
    public var account: String

    public init(server: UUID, account: String) {
        self.server = server
        self.account = account
    }
}

/// How each account arranged its rooms list on this device: the top-level rooms' order
/// (`RoomOrder`) and the rooms whose threads it folded to those with news (apron-web's
/// `roomOrder` and `threadFolds`), in `room-order.json` beside `servers.json`. Owned by
/// `SessionStore`, passed to every session, and dropped with the server; a file that cannot be
/// read keeps none.
@MainActor
@Observable
public final class RoomArrangement {
    /// The most rooms kept folded per account; the ones folded longest ago unfold first.
    public static let foldsMax = 200

    struct Kept: Equatable {
        var order: [String] = []
        /// Folded longest ago first.
        var folded: [String] = []
    }

    private var kept: [ArrangementKey: Kept] = [:]
    @ObservationIgnored private let fileURL: URL?

    /// `directory` nil keeps it in memory only.
    public init(directory: URL? = nil) {
        fileURL = directory?.appending(path: "room-order.json")
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let json = try? JSONValue(parsing: data) else { return }
        for entry in json.arrayValue ?? [] {
            guard let server = entry["server"]?.stringValue.flatMap(UUID.init(uuidString:)), let account = entry["account"]?.stringValue else { continue }
            let ids = { (key: String) in (entry[key]?.arrayValue ?? []).compactMap(\.stringValue) }
            kept[ArrangementKey(server: server, account: account)] = Kept(order: ids("order"), folded: ids("folded"))
        }
    }

    public func order(_ key: ArrangementKey) -> [String] { kept[key]?.order ?? [] }

    /// Places the `listed` rooms not yet placed, after the others.
    public func adopt(_ listed: [String], _ key: ArrangementKey) {
        setOrder(RoomOrder.adopting(listed, into: order(key)), key)
    }

    public func setOrder(_ order: [String], _ key: ArrangementKey) {
        guard order != self.order(key) else { return }
        kept[key, default: Kept()].order = order
        save()
    }

    public func threadsFolded(_ roomID: String, _ key: ArrangementKey) -> Bool {
        kept[key]?.folded.contains(roomID) ?? false
    }

    public func foldThreads(_ roomID: String, _ folded: Bool, _ key: ArrangementKey) {
        var list = kept[key]?.folded.filter { $0 != roomID } ?? []
        if folded { list.append(roomID) }
        if list.count > Self.foldsMax { list.removeFirst(list.count - Self.foldsMax) }
        guard list != kept[key]?.folded ?? [] else { return }
        kept[key, default: Kept()].folded = list
        save()
    }

    /// The account took another `user_id` (§3.3.3): its arrangement goes with it.
    public func rename(server: UUID, from old: String, to new: String) {
        guard let moving = kept.removeValue(forKey: ArrangementKey(server: server, account: old)) else { return }
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
             "order": .array(value.order.map(JSONValue.string)), "folded": .array(value.folded.map(JSONValue.string))]
        })
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.serializedData().write(to: fileURL, options: .atomic)
    }
}
