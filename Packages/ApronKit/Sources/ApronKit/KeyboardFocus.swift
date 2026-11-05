import Foundation

/// Where a key moves the keyboard among a timeline's rows, as apron-web's `MESSAGE_STEPS`.
public enum MessageStep: Hashable, Sendable {
    case previous, next, first, last, pageUp, pageDown

    /// Toward older messages.
    public var isUp: Bool { self == .previous || self == .first || self == .pageUp }
}

/// The keyboard among the messages (apron-web #218, #219, `message-focus.ts`): ↑ from an empty
/// composer lands on the newest stop, then ↑ ↓ (Home End, Page Up Page Down) go from stop to stop
/// as drawn. Stops are people's messages and what between them takes the keyboard on its own: a
/// thread's card and a gap row. Day pills, the New line and join, leave and rename lines have
/// nothing to act on.
public enum TimelineKeys {
    /// Where a step lands: on a row, or past an end, where ↑ asks for older messages and ↓ goes
    /// back to the composer.
    public enum Target: Hashable, Sendable {
        case row(String)
        case older
        case composer
    }

    /// The ids of `items` the keys stop at, oldest first.
    public static func stops(_ items: [TimelineItem]) -> [String] {
        items.compactMap { item in
            switch item {
            case .message, .thread, .gap: item.id
            case .day, .unreadLine, .members, .renamed: nil
            }
        }
    }

    /// The stop `step` goes to from `from` (the newest when `from` isn't one), `perPage` stops to a page.
    public static func step(_ step: MessageStep, from: String?, in stops: [String], perPage: Int = 1) -> Target {
        guard let from, let at = stops.firstIndex(of: from) else { return stops.last.map(Target.row) ?? .composer }
        let page = max(1, perPage)
        let to: Int? = switch step {
        case .previous: at - 1
        case .next: at + 1
        case .first: at == 0 ? nil : 0
        case .last: at == stops.count - 1 ? nil : stops.count - 1
        case .pageUp: at == 0 ? nil : max(0, at - page)
        case .pageDown: at == stops.count - 1 ? nil : min(stops.count - 1, at + page)
        }
        guard let to, stops.indices.contains(to) else { return step.isUp ? .older : .composer }
        return .row(stops[to])
    }

    /// Shift+↑ ↓ (#219): the message the run goes on to from `from`, past thread cards and gaps,
    /// among `messages` (the ids select mode may pick, oldest first); nil at an end.
    public static func extending(from: LogID, up: Bool, among messages: [LogID]) -> LogID? {
        guard let at = messages.firstIndex(of: from) else { return nil }
        let to = up ? at - 1 : at + 1
        return messages.indices.contains(to) ? messages[to] : nil
    }
}

/// Alt+↑ ↓ through the rooms list (apron-web #212, `room-steps.ts`): its rows as drawn, threads
/// under their room, folded sections' hidden rooms left out.
public enum RoomSteps {
    public struct Row: Hashable, Sendable {
        public var id: String
        /// A room's row, joined or read before joining, not a thread's.
        public var isRoom: Bool

        public init(_ id: String, isRoom: Bool) {
            self.id = id
            self.isRoom = isRoom
        }
    }

    /// The row `step` (1 or -1) places after the open one, or with `pastThreads` the nearest room
    /// that way (from a thread going up, the room it's under). With no row open, the first (or
    /// last). Nil at the end of the list.
    public static func next(_ rows: [Row], open: String?, step: Int, pastThreads: Bool = false) -> String? {
        let at = open.flatMap { id in rows.firstIndex { $0.id == id } }
        var index = at.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
        while rows.indices.contains(index) {
            if !pastThreads || rows[index].isRoom { return rows[index].id }
            index += step
        }
        return nil
    }
}
