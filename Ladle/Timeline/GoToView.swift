import ApronKit
import SwiftUI

/// apron-web's search dialog with its two modes (#220): Go to a Room or Thread (⌘K) and Search
/// Local History (⌘F), switched at the sheet's foot, in reach, or with either key inside it. (Above
/// the field, as the web has it, it would sit over each mode's own navigation bar.)
struct FindSheet: View {
    enum Mode: String, Identifiable, CaseIterable {
        case rooms = "Rooms and Threads", messages = "Messages"
        var id: String { rawValue }
    }

    let session: ServerSession
    let roomID: String?
    @State var mode: Mode
    /// A room or thread picked: opened once the sheet has gone.
    let open: (String) -> Void
    /// The renderer's typed words, which it cannot type.
    var startingText = ""
    var focusesField = true

    var body: some View {
        Group {
            switch mode {
            case .rooms:
                GoToView(session: session, open: open, startingText: startingText, focusesField: focusesField)
            case .messages:
                SearchView(session: session, initial: ServerSession.searchStart(in: roomID), focusesField: focusesField)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Picker("Search", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s2)
            .background(Palette.chrome)
        }
        .background {
            HiddenShortcuts(actions: [.goTo, .searchHistory]) { mode = $0 == .goTo ? .rooms : .messages }
        }
    }
}

/// Go to a Room or Thread (#220): the rooms and threads this device knows of by name
/// (`RoomFinder`), joined ones under Joined, the rest under Not joined. `room:` narrows it to a
/// room's threads, as → at the end of the field does on a highlighted room; Backspace there takes
/// the filter away. ↑ ↓ move the highlight and Return opens it: a joined room as a mention does,
/// any other to read without joining, as its link does (`openRoom`).
struct GoToView: View {
    let session: ServerSession
    let open: (String) -> Void
    @State private var query: String
    @State private var selection: TextSelection?
    /// The highlighted result, by id, so it stays on its room while results change.
    @State private var highlighted: String?
    @FocusState private var focused: Bool
    /// Search the Server: under way, then what it came to.
    @State private var listing = false
    @State private var listed: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fixedNow) private var fixedNow
    var focusesField = true

    init(session: ServerSession, open: @escaping (String) -> Void, startingText: String = "", focusesField: Bool = true) {
        self.session = session
        self.open = open
        self.focusesField = focusesField
        _query = State(initialValue: startingText)
        _selection = State(initialValue: TextSelection(insertionPoint: startingText.endIndex))
    }

    private var parsed: SearchQuery { LocalSearch.parse(query) }
    private var results: RoomFinder.Results { RoomFinder.rank(session.knownRooms, text: parsed.text, rooms: parsed.rooms) }

    var body: some View {
        let results = results
        let shown = results.rooms.map(\.room)
        let current = highlighted.flatMap { id in shown.first { $0.id == id } } ?? shown.first
        NavigationStack {
            List {
                Section {
                    TextField("Room or thread, room:#name", text: $query, selection: $selection)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused)
                        .accessibilityLabel("Go to")
                        .onSubmit { if let current { pick(current.id) } }
                        .onKeyPress(phases: [.down, .repeat]) { press in key(press, shown: shown, current: current) }
                    ForEach(suggestions, id: \.value) { suggestion in
                        Button { take(suggestion.value) } label: {
                            HStack {
                                Text(suggestion.label).apText(.ui).foregroundStyle(Palette.ink)
                                Spacer()
                                Text(suggestion.value).apText(.sm).foregroundStyle(Palette.inkMuted)
                            }
                        }
                    }
                } footer: {
                    Text(note(results)).formFooter()
                }
                .listRowBackground(Palette.raised)
                ForEach([true, false], id: \.self) { joined in
                    let rows = results.rooms.filter { $0.room.joined == joined }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows, id: \.room.id) { found in
                                Button { pick(found.room.id) } label: { row(found.room, on: found.room.id == current?.id) }
                                    .buttonStyle(.plain)
                                    .listRowBackground(found.room.id == current?.id ? Palette.hover : Palette.raised)
                            }
                        } header: {
                            Text(joined ? "Joined" : "Not joined").formHeader()
                        }
                    }
                }
                if session.status == .signedIn, session.server?.has("rooms") == true {
                    Section {
                        Button(listing ? "Searching the Server…" : "Search the Server") { searchServer() }
                            .disabled(listing)
                    } footer: {
                        Text(listed ?? "Lists the rooms to join afresh. A server lists only its most recently active ones, so others aren’t found.").formFooter()
                    }
                    .listRowBackground(Palette.raised)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Go to a Room or Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .onAppear { if focusesField { focused = true } }
        }
    }

    /// Under the field: how much was found, and where from.
    private func note(_ results: RoomFinder.Results) -> String {
        let scope = results.scope.first.map { " in \(session.title(of: $0.id))" } ?? ""
        let count = results.total == 1 ? "1 match" : "\(results.total) matches"
        let shown = results.total > results.rooms.count ? ", the first \(results.rooms.count) shown" : ""
        return parsed.text.isEmpty && parsed.rooms.isEmpty
            ? "Rooms and threads this device knows of, joined first."
            : "\(count)\(scope)\(shown). Rooms and threads this device knows of."
    }

    private func row(_ room: RoomFinder.KnownRoom, on: Bool) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            Image(systemName: room.isThread ? "arrow.turn.down.right" : "number")
                .foregroundStyle(Palette.inkMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Tokens.Space.s1) {
                    Text(marked(room.title)).apText(.ui).foregroundStyle(Palette.ink).lineLimit(1)
                    if room.isPrivate { Lock(tint: Palette.private) }
                }
                if let detail = room.parentRoomID.map(session.title(of:)) ?? room.description.flatMap({ $0.split(separator: "\n").first.map(String.init) }) {
                    Text(detail).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
                }
            }
            Spacer(minLength: Tokens.Space.s2)
            if let active = session.lastActive(of: room.id) {
                Text(LastActive.words(active, now: fixedNow ?? .now)).apText(.sm).monospacedDigit().foregroundStyle(Palette.inkMuted)
            }
            if !room.joined {
                Text("Not joined").apText(.xs, .medium).foregroundStyle(Palette.inkMuted)
            } else if session.mentionCount(in: room.id) > 0 {
                UnreadCount(count: session.mentionCount(in: room.id), mentions: true)
            } else if session.unreadCount(in: room.id) > 0 {
                UnreadCount(count: session.unreadCount(in: room.id))
            }
        }
        .frame(minHeight: Tokens.Size.touchTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The title with what was typed marked, as the web's `<mark>`.
    private func marked(_ title: String) -> AttributedString {
        var text = AttributedString(title)
        let typed = parsed.text.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, let range = text.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].inlinePresentationIntent = .stronglyEmphasized
            text[range].backgroundColor = Palette.accentSoft
        }
        return text
    }

    /// ↑ ↓ through the results, → on a room at the end of the field to its threads, Backspace at
    /// the end of `room:#id ` to take the filter away.
    private func key(_ press: KeyPress, shown: [RoomFinder.KnownRoom], current: RoomFinder.KnownRoom?) -> KeyPress.Result {
        let atEnd = selection.map { if case .selection(let range) = $0.indices { range.isEmpty && range.lowerBound == query.endIndex } else { false } } ?? true
        switch press.key {
        case .downArrow, .upArrow:
            guard !shown.isEmpty, press.modifiers.isEmpty, suggestions.isEmpty else { return .ignored }
            let at = current.flatMap { room in shown.firstIndex { $0.id == room.id } } ?? 0
            highlighted = shown[(at + (press.key == .downArrow ? 1 : shown.count - 1)) % shown.count].id
            return .handled
        case .rightArrow:
            guard atEnd, let chord = Shortcuts.Chord(press), Shortcuts.action(for: chord, in: .goTo) == .threadsOfRoom,
                  let current, !current.isThread else { return .ignored }
            setQuery("room:#\(current.id) ")
            highlighted = nil
            return .handled
        case .delete:
            guard atEnd, parsed.text.isEmpty, !parsed.rooms.isEmpty else { return .ignored }
            setQuery("")
            return .handled
        default:
            return .ignored
        }
    }

    private func setQuery(_ text: String) {
        query = text
        selection = TextSelection(insertionPoint: text.endIndex)
    }

    /// The `room:` value at the caret.
    private var filter: FilterAtCaret? {
        guard case .selection(let range)? = selection?.indices, range.isEmpty else { return nil }
        let found = LocalSearch.filterAtCaret(query, caret: query.utf16.distance(from: query.startIndex, to: range.lowerBound))
        return found?.kind == .rooms ? found : nil
    }

    /// Rooms for `room:` at the caret, as Search Local History suggests them; never threads.
    private var suggestions: [(label: String, value: String)] {
        guard let filter else { return [] }
        return RoomMentions.search(session.roomSuggestions.filter { !$0.isThread }, filter.typed).map { ($0.title, "#\($0.id)") }
    }

    private func take(_ value: String) {
        guard let filter else { return }
        let next = LocalSearch.withFilterValue(query, at: filter, value: value)
        query = next.query
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: next.caret, in: next.query))
    }

    /// The rooms to join, listed afresh (`room_list`, `not_joined`): the listing installs their
    /// records, which `knownRooms` then holds.
    private func searchServer() {
        listing = true
        Task {
            do {
                let ids = try await session.listUnjoinedRooms()
                listed = ids.count == 1 ? "The server listed 1 room to join." : "The server listed \(ids.count) rooms to join."
            } catch {
                listed = errorText(error)
            }
            listing = false
        }
    }

    private func pick(_ id: String) {
        open(id)
        dismiss()
    }
}
