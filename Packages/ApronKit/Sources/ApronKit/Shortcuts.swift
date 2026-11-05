import Foundation

/// Every key Ladle takes from a hardware keyboard, as apron-web's `shortcuts.ts` lists them for
/// its `?` overlay (#212, #218, #219, #220). The one table serves both sides: the views ask
/// `action(for:in:)` what a key does where it was pressed, and the Keyboard Shortcuts sheet lists
/// the entries that are `listed`. A new key goes here, or it neither works nor shows.
public enum Shortcuts {
    public enum Key: Hashable, Sendable {
        /// A key that types a character: `r`, `?`, `/`, `k`. Lowercase for a letter.
        case character(Character)
        case up, down, left, right, home, end, pageUp, pageDown, escape, enter
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public struct Chord: Hashable, Sendable {
        public var key: Key
        public var modifiers: Modifiers

        public init(_ key: Key, _ modifiers: Modifiers = []) {
            self.key = key
            self.modifiers = modifiers
        }

        /// The chord as an iPad's keyboard marks it, modifiers in Apple's order: ["⌥", "⇧", "↑"].
        public var written: [String] {
            let marks: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            let name = switch key {
            case .character(let character): String(character).uppercased()
            case .up: "↑"
            case .down: "↓"
            case .left: "←"
            case .right: "→"
            case .home: "Home"
            case .end: "End"
            case .pageUp: "Page Up"
            case .pageDown: "Page Down"
            case .escape: "Esc"
            case .enter: "Return"
            }
            return marks.compactMap { modifiers.contains($0.0) ? $0.1 : nil } + [name]
        }

        /// The chord in words, for VoiceOver: "Option Shift Up Arrow".
        public var spoken: String {
            let words: [(Modifiers, String)] = [(.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
            let name = switch key {
            case .character("?"): "Question Mark"
            case .character("/"): "Slash"
            case .character(let character): String(character).uppercased()
            case .up: "Up Arrow"
            case .down: "Down Arrow"
            case .left: "Left Arrow"
            case .right: "Right Arrow"
            case .home: "Home"
            case .end: "End"
            case .pageUp: "Page Up"
            case .pageDown: "Page Down"
            case .escape: "Escape"
            case .enter: "Return"
            }
            return (words.compactMap { modifiers.contains($0.0) ? $0.1 : nil } + [name]).joined(separator: " ")
        }
    }

    /// What a key does.
    public enum Action: Hashable, Sendable {
        case showShortcuts, goTo, searchHistory, members, newReactions
        case send, newLine, cancelReply
        case toMessages, backToComposer, reply, edit, select
        case message(MessageStep)
        case extendSelection(up: Bool)
        case room(step: Int, pastThreads: Bool)
        case moveRoom(step: Int)
        case threadsOfRoom
    }

    /// Where a key is taken, as each entry names it for the sheet.
    public enum Scope: Hashable, Sendable {
        /// From anywhere in the app: a key command, so the system's ⌘-hold list shows it too.
        case anywhere
        /// In the composer's field.
        case composer
        /// On a message the keyboard is on.
        case message
        /// On a room's row in the rooms list.
        case roomRow
        /// In Go to a Room or Thread's field.
        case goTo
    }

    public enum Group: String, CaseIterable, Sendable {
        case general = "General", composer = "Composer", messages = "Messages", rooms = "Rooms"
    }

    public struct Entry: Hashable, Sendable {
        public var label: String
        /// Where it works, under the label: nil where it works anywhere.
        public var place: String?
        public var group: Group
        public var scope: Scope
        public var keys: [Binding]
        /// Shown in the sheet. Keys every app has (Home and End on a message) work but aren't listed, as the web's.
        public var listed: Bool

        public var chords: [Chord] { keys.map(\.chord) }
    }

    public struct Binding: Hashable, Sendable {
        public var chord: Chord
        public var action: Action
    }

    private static func entry(_ label: String, _ place: String? = nil, _ group: Group, _ scope: Scope, listed: Bool = true,
                              _ keys: [(Chord, Action)]) -> Entry {
        Entry(label: label, place: place, group: group, scope: scope, keys: keys.map { Binding(chord: $0.0, action: $0.1) }, listed: listed)
    }

    private static let onMessage = "On a message"

    /// The table, in the sheet's order. Each scope's keys are taken where its comment says.
    public static let all: [Entry] = [
        // TimelineView's key commands (`ShortcutKeys`), and `?` on a message (`TimelineView.messageKey`).
        entry("Show keyboard shortcuts", nil, .general, .anywhere, [(Chord(.character("/"), .command), .showShortcuts)]),
        entry("Show keyboard shortcuts", "On a message", .general, .message, listed: false, [(Chord(.character("?")), .showShortcuts),
                                                                                             (Chord(.character("?"), .shift), .showShortcuts)]),
        entry("Go to a room or thread", nil, .general, .anywhere, [(Chord(.character("k"), .command), .goTo)]),
        entry("Search local history", nil, .general, .anywhere, [(Chord(.character("f"), .command), .searchHistory)]),
        entry("Show or hide members", nil, .general, .anywhere, [(Chord(.character("m"), [.command, .shift]), .members)]),
        entry("Go to new reactions", nil, .general, .anywhere, [(Chord(.character("r"), [.command, .shift]), .newReactions)]),
        // ComposerView's field (`onKeyPress`) and its Send and Cancel buttons.
        entry("Send", nil, .composer, .composer, [(Chord(.enter, .command), .send)]),
        entry("New line", nil, .composer, .composer, [(Chord(.enter, .shift), .newLine)]),
        entry("Cancel the reply", "While replying", .composer, .composer, [(Chord(.escape), .cancelReply)]),
        // The composer's ↑, then TimelineView's `messageKey` on the row.
        entry("Go to the messages", "In an empty composer", .messages, .composer, [(Chord(.up), .toMessages)]),
        entry("Previous or next message", onMessage, .messages, .message, [(Chord(.up), .message(.previous)), (Chord(.down), .message(.next))]),
        entry("Oldest or newest message", onMessage, .messages, .message, listed: false,
              [(Chord(.home), .message(.first)), (Chord(.end), .message(.last)), (Chord(.up, .command), .message(.first)), (Chord(.down, .command), .message(.last))]),
        entry("A page of messages up or down", onMessage, .messages, .message, listed: false,
              [(Chord(.pageUp), .message(.pageUp)), (Chord(.pageDown), .message(.pageDown))]),
        entry("Back to the composer", onMessage, .messages, .message, [(Chord(.escape), .backToComposer)]),
        entry("Reply", onMessage, .messages, .message, [(Chord(.character("r")), .reply)]),
        entry("Edit your message", onMessage, .messages, .message, [(Chord(.character("e")), .edit)]),
        entry("Select it, to move it", onMessage, .messages, .message, [(Chord(.character("x")), .select)]),
        entry("Select up or down from it", onMessage, .messages, .message,
              [(Chord(.up, .shift), .extendSelection(up: true)), (Chord(.down, .shift), .extendSelection(up: false))]),
        // RoomListView's key commands (`roomKeys`): on a focused row they move it instead.
        entry("Previous or next room or thread", nil, .rooms, .anywhere,
              [(Chord(.up, .option), .room(step: -1, pastThreads: false)), (Chord(.down, .option), .room(step: 1, pastThreads: false))]),
        entry("Previous or next room, past threads", nil, .rooms, .anywhere,
              [(Chord(.up, [.option, .shift]), .room(step: -1, pastThreads: true)), (Chord(.down, [.option, .shift]), .room(step: 1, pastThreads: true))]),
        entry("Move a room up or down", "On a room in the list", .rooms, .roomRow,
              [(Chord(.up, .option), .moveRoom(step: -1)), (Chord(.down, .option), .moveRoom(step: 1))]),
        // GoToView's field.
        entry("Search a room’s threads", "On a room, in Go to a room or thread", .rooms, .goTo, [(Chord(.right), .threadsOfRoom)]),
    ]

    /// What `chord` does in `scope`, if anything.
    public static func action(for chord: Chord, in scope: Scope) -> Action? {
        all.lazy.filter { $0.scope == scope }.flatMap(\.keys).first { $0.chord == chord }?.action
    }

    /// The entries in `scope`, for the views that turn them into key commands.
    public static func entries(in scope: Scope) -> [Entry] { all.filter { $0.scope == scope } }

    /// What the sheet lists: each group in order with its listed entries.
    public static var groups: [(group: Group, entries: [Entry])] {
        Group.allCases.map { group in (group, all.filter { $0.group == group && $0.listed }) }
    }
}
