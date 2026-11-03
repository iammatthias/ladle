import Foundation

/// The catch-up of rooms a reconnect or a relaunch finds behind, together, as apron-web's
/// `catchUpJoined` (#200): one `history` without `room_id` (§4.3), which pages the log of every
/// joined room as one, threads included, from the oldest of their checkpoints, up to `pageLimit`
/// pages. A room the listing shows no further than its checkpoint has nothing new and is not
/// asked about at all.
public struct JoinedCatchUp: Equatable, Sendable {
    /// Rooms whose checkpoint is more than this before the newest of them catch up by themselves,
    /// so the others' records from back then aren't asked for again (`JOINED_SPREAD_MS`).
    public static let spread: TimeInterval = 60 * 60
    /// The oldest position the rooms catch up together from (`JOINED_CATCH_UP_MS`); older, most
    /// of the other rooms' records since would be ones this device has.
    public static let maxAge: TimeInterval = 24 * 60 * 60
    /// `JOINED_CATCH_UP_PAGES`; past it, each room goes on by itself from where this got to.
    public static let pageLimit = 5

    /// Where every room in `rooms` is complete up to; the log is asked for from just after it.
    public var position: LogID
    public var rooms: Set<String>

    /// Which of the rooms behind (each with its checkpoint) catch up together, or nil for each
    /// by itself: fewer than two, or the oldest position more than `maxAge` before `now` on a
    /// server whose positions are times.
    public static func plan(_ behind: [String: LogID], now: Date) -> JoinedCatchUp? {
        guard let newest = behind.values.max() else { return nil }
        let together = behind.filter { _, checkpoint in
            !(newest.isTimeLike && checkpoint.isTimeLike) || newest.date.timeIntervalSince(checkpoint.date) <= spread
        }
        guard together.count >= 2, let position = together.values.min() else { return nil }
        if position.isTimeLike, now.timeIntervalSince(position.date) > maxAge { return nil }
        return JoinedCatchUp(position: position, rooms: Set(together.keys))
    }
}
