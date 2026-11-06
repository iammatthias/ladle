import ApronKit
import SwiftUI

/// apron-web's search dialog, Search Local History, with its two modes (#220, #224): rooms and
/// threads (⌘K) and messages (⌘F), switched at the sheet's foot, in reach, or with either key
/// inside it. (Above the field, as the web has it, it would sit over each mode's own navigation bar.)
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

/// Search's rooms and threads (#220, #224): those this device knows of by name (`RoomFinder`),
/// joined ones under Joined, the rest under Not joined, each drawn as the rooms list draws it.
/// `room:` narrows it to a room's threads, as → at the end of the field does on a highlighted
/// room, and lists that room's threads you haven't joined from the server (`listThreads`), the
/// line after the results saying how many; Backspace there takes the filter away. ↑ ↓ move the
/// highlight and Return opens it: a joined room as a mention does, any other to read without
/// joining, as its link does (`openRoom`).
struct GoToView: View {
    let session: ServerSession
    let open: (String) -> Void
    @State private var query: String
    @State private var selection: TextSelection?
    /// The highlighted result, by id, so it stays on its room while results change.
    @State private var highlighted: String?
    @FocusState private var focused: Bool
    /// Each scoped room's listing of its threads, by `room_id`: once while the sheet is open.
    @State private var listings: [String: RoomFinder.ThreadsListing] = [:]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openPreferences) private var openPreferences
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
                                Button { pick(found.room.id) } label: { row(found.room, scoped: results.scope.count == 1, on: found.room.id == current?.id) }
                                    .buttonStyle(.plain)
                                    .listRowBackground(found.room.id == current?.id ? Palette.hover : Palette.raised)
                            }
                        } header: {
                            Text(joined ? "Joined" : "Not joined").formHeader()
                        }
                    }
                }
                if let scoped = listedRoom(results), let listing = listings[scoped.id] {
                    Section {
                        if listing.failed {
                            Button("Try Again") { list(scoped.id) }
                        }
                    } footer: {
                        Text(listing.note(title: scoped.title)).formFooter()
                    }
                    .listRowBackground(Palette.raised)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Search Local History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if let kept = session.searchKept {
                    ToolbarItem(placement: .primaryAction) {
                        Button(kept) {
                            dismiss()
                            openPreferences(.history)
                        }
                        .accessibilityLabel("\(kept) of history kept, in Preferences")
                    }
                }
            }
            .task(id: listedRoom(results)?.id) {
                if let id = listedRoom(results)?.id, listings[id] == nil { list(id) }
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

    /// A result as the rooms list draws it, with what matched marked and a thread's room under its
    /// title where the search isn't that room's threads.
    private func row(_ room: RoomFinder.KnownRoom, scoped: Bool, on: Bool) -> some View {
        let parent = scoped ? nil : room.parentRoomID.map(session.title(of:))
        let found = RoomRow.Found(room: room, parts: LocalSearch.snippet(room.title, found: RoomFinder.wanted(parsed.text), width: 200), parent: parent)
        return RoomRow(session: session, roomID: room.id, isThread: room.isThread, isSelected: false, now: fixedNow ?? .now, found: found)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The room `room:` names, whose threads you haven't joined the server lists: one, where the
    /// server lists rooms and you are signed in.
    private func listedRoom(_ results: RoomFinder.Results) -> RoomFinder.KnownRoom? {
        guard results.scope.count == 1, session.status == .signedIn, session.server?.has("rooms") == true else { return nil }
        return results.scope.first
    }

    /// Lists a room's threads you haven't joined, once, or again when Try Again asks after it failed.
    private func list(_ roomID: String) {
        listings[roomID] = .listing
        Task {
            do {
                listings[roomID] = .listed(try await session.listThreads(of: roomID))
            } catch {
                listings[roomID] = .failed(errorText(error))
            }
        }
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

    private func pick(_ id: String) {
        open(id)
        dismiss()
    }
}
