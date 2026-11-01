import Foundation

/// The highlighted row of the list above the composer, and what a hardware keyboard does to it,
/// as apron-web's `DraftField.keydown` over its AutocompletePicker: ↓ and ↑ move it, wrapping
/// round; Tab and Return pick it; Escape puts the list away until the text changes. Every list
/// (people and roles, rooms, emoji, commands) shares it. Ladle's lists read the end of the text,
/// so a dismissal is kept by text alone where apron-web keeps it by text and caret.
public struct SuggestionCursor: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case up, down, tab
        /// Return without Shift: Shift-Return is always a new line.
        case enter
        case escape
    }

    public enum Outcome: Hashable, Sendable {
        /// No list: the key does what it does without one.
        case ignored
        case moved
        /// Pick the row at this index.
        case pick(Int)
        case dismissed
    }

    private enum Kind: Hashable, Sendable {
        case command, mention, emoji, room

        init(_ query: DraftField.Query) {
            switch query {
            case .command: self = .command
            case .mention: self = .mention
            case .emoji: self = .emoji
            case .room: self = .room
            }
        }
    }

    private var active = 0
    private var kind: Kind?
    private var dismissed: String?

    public init() {}

    /// Whether the list for `text` shows: not once Escape put it away at this text.
    public func shows(_ text: String) -> Bool { dismissed != text }

    /// The highlighted row of a list of `count` rows, which may have shrunk since it moved.
    public func highlighted(count: Int) -> Int { min(active, max(0, count - 1)) }

    /// Follows the draft as it changes: a list of another kind, or none, starts again at its top,
    /// as apron-web's does when a new query opens; typing on in the same one keeps the row. A
    /// changed text brings back a list Escape put away.
    public mutating func follow(_ query: DraftField.Query?, text: String) {
        let next = query.map(Kind.init)
        if next != kind {
            kind = next
            active = 0
        }
        if dismissed != text { dismissed = nil }
    }

    /// The pointer over a row makes it the highlighted one.
    public mutating func hover(_ index: Int) { active = index }

    /// A key pressed in the field while a list of `count` rows is for `text`.
    public mutating func press(_ key: Key, count: Int, text: String) -> Outcome {
        guard count > 0, shows(text) else { return .ignored }
        let current = highlighted(count: count)
        switch key {
        case .down:
            active = (current + 1) % count
            return .moved
        case .up:
            active = (current + count - 1) % count
            return .moved
        case .tab, .enter:
            active = 0
            return .pick(current)
        case .escape:
            dismissed = text
            return .dismissed
        }
    }
}

extension DraftSuggestions {
    /// How many rows the list has.
    public var count: Int {
        switch self {
        case .commands(let rows): rows.count
        case .mentions(let rows): rows.count
        case .emoji(let rows): rows.count
        case .rooms(let rows): rows.count
        }
    }
}
