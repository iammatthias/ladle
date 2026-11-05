import ApronKit
import SwiftUI

/// Search Local History, as apron-web's SearchDialog (#137, #166): what this device keeps of the
/// server and what is loaded, as the query is typed, narrowed by `user:` and `room:`, which
/// suggest people and rooms at the caret as the composer does. It starts narrowed to the open
/// room. A result opens where it is: its room, revealed and highlighted.
struct SearchView: View {
    let session: ServerSession
    @State private var query: String
    @State private var selection: TextSelection?
    @State private var found = SearchFound.none
    @State private var searching = false
    /// Load More from Server (apron-web #220): a press under way, its failure, and how many have
    /// loaded, which searches again.
    @State private var loadingOlder = false
    @State private var loadError: String?
    @State private var loads = 0
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.openPreferences) private var openPreferences

    /// The field takes the keyboard as the sheet opens. The renderer turns it off: on Mac
    /// Catalyst a focused field selects all of itself, which would hide the suggestions.
    var focusesField = true

    init(session: ServerSession, initial: String, focusesField: Bool = true) {
        self.session = session
        self.focusesField = focusesField
        _query = State(initialValue: initial)
        _selection = State(initialValue: TextSelection(insertionPoint: initial.endIndex))
    }

    /// How long typing pauses before a search starts (apron-web's `SEARCH_DELAY_MS`).
    private static let delay: Duration = .milliseconds(150)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Words, user:@name, room:#name", text: $query, selection: $selection)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($focused)
                        .accessibilityLabel("Search for")
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
                    Text(session.searchNote).formFooter()
                }
                .listRowBackground(Palette.raised)
                Section {
                    if found.messages.isEmpty {
                        Text(emptyWords).apText(.ui).foregroundStyle(Palette.inkMuted)
                    }
                    ForEach(found.messages, id: \.messageID) { message in
                        Button { open(message) } label: { SearchHitRow(hit: session.hit(message, in: found)) }
                    }
                    if found.more {
                        Text("Only the newest are listed. Add words to narrow it down.").apText(.sm).foregroundStyle(Palette.inkMuted)
                    }
                }
                .listRowBackground(Palette.raised)
                if let offer = session.searchLoadOffer(for: query, loading: loadingOlder, error: loadError) {
                    Section {
                        if !offer.done {
                            Button { loadMore() } label: {
                                HStack {
                                    Text("Load More from Server").apText(.ui, .medium).foregroundStyle(Palette.accent)
                                    Spacer()
                                    if offer.busy { ProgressView() }
                                }
                            }
                            .disabled(offer.busy)
                        }
                    } footer: {
                        Text(offer.note).formFooter()
                    }
                    .listRowBackground(Palette.raised)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Search Local History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
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
            .task(id: SearchRun(query: query, loads: loads)) {
                searching = true
                try? await Task.sleep(for: Self.delay)
                guard !Task.isCancelled else { return }
                let result = await session.search(query)
                guard !Task.isCancelled else { return }
                found = result
                searching = false
            }
            .onAppear { focused = focusesField }
        }
    }

    private var emptyWords: String {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if LocalSearch.parse(query).isEmpty { return "Type to search." }
        return searching ? "Searching…" : "No messages match “\(typed)”."
    }

    /// The `user:` or `room:` value at the caret.
    private var filter: FilterAtCaret? {
        guard case .selection(let range)? = selection?.indices, range.isEmpty else { return nil }
        return LocalSearch.filterAtCaret(query, caret: query.utf16.distance(from: query.startIndex, to: range.lowerBound))
    }

    /// People or rooms for the filter at the caret: `@user_id` or `#room_id`, as apron-web's.
    private var suggestions: [(label: String, value: String)] {
        guard let filter else { return [] }
        switch filter.kind {
        case .users:
            let people = session.users.userIDs.filter { !$0.hasPrefix("~") }.compactMap { session.users.user($0).flatMap(UserObject.init) }
            return LocalSearch.searchPeople(people, typed: filter.typed, id: \.userID, name: { $0.json["name"]?.stringValue })
                .map { (session.displayName(for: $0), "@\($0.userID)") }
        case .rooms:
            return RoomMentions.search(session.roomSuggestions, filter.typed).map { ($0.title, "#\($0.id)") }
        }
    }

    private func take(_ value: String) {
        guard let filter else { return }
        let next = LocalSearch.withFilterValue(query, at: filter, value: value)
        query = next.query
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: next.caret, in: next.query))
    }

    private func loadMore() {
        loadingOlder = true
        loadError = nil
        Task {
            loadError = await session.loadMoreForSearch(query)
            loadingOlder = false
            loads += 1
        }
    }

    private func open(_ message: MessageSnapshot) {
        guard let url = ApronLink(server: session.record.url, room: message.roomID, message: message.messageID).webURL else { return }
        dismiss()
        openURL(url)
    }
}

/// What a search runs for: the query, again once more history has loaded.
private struct SearchRun: Hashable {
    var query: String
    var loads: Int
}

/// A result: where, who and when over a line of its text with the words found marked.
private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack(spacing: Tokens.Space.s2) {
                Text(hit.place).apText(.sm, .semibold).foregroundStyle(Palette.denim).lineLimit(1)
                Text(hit.who).apText(.sm).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 0)
                Text(hit.message.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .apText(.xs).foregroundStyle(Palette.inkMuted)
            }
            Text(snippet).apText(.ui).foregroundStyle(Palette.inkMuted).lineLimit(3)
        }
        .padding(.vertical, Tokens.Space.s1)
        .accessibilityElement(children: .combine)
    }

    private var snippet: AttributedString {
        hit.parts.reduce(into: AttributedString()) { text, part in
            var run = AttributedString(part.text)
            if part.match {
                run.foregroundColor = Palette.ink
                run.backgroundColor = Palette.accent.opacity(0.25)
            }
            text += run
        }
    }
}
