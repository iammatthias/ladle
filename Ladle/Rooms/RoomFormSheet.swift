import ApronKit
import SwiftUI

/// The web's RoomForm, as a sheet: a title and a Markdown description, to start a room or a
/// thread (empty, or suggested from a message by Start Thread) or to edit one. The server's
/// refusal shows in the form, which stays open to try again; once `submit` returns, it closes.
struct RoomFormSheet: View {
    enum Kind { case room, thread }
    enum Mode { case create, edit }

    let kind: Kind
    let mode: Mode
    /// "In general", under a new thread's heading.
    var subtitle: String?
    /// A thread of a private room is private too.
    var isPrivate = false
    @State var title: String
    @State var description: String
    let submit: (String, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    private var noun: String { kind == .thread ? "thread" : "room" }
    private var heading: String {
        switch (mode, kind) {
        case (.create, .thread): "Start Thread"
        case (.create, .room): "New Room"
        case (.edit, _): "Edit \(noun.capitalized)"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .focused($titleFocused)
                        .submitLabel(.next)
                } header: {
                    if let subtitle { Text(subtitle) }
                } footer: {
                    if isPrivate { Text("Private, like its room: only the room’s members see it.") }
                }
                Section {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(4 ... 12)
                } header: {
                    Text("Description")
                } footer: {
                    Text(mode == .edit ? "Markdown" : "Markdown, optional")
                }
                if let error {
                    Section { Text(error).apText(.ui).foregroundStyle(Palette.danger) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? (mode == .edit ? "Saving…" : "Starting…") : (mode == .edit ? "Save" : kind == .thread ? "Start" : "Create")) { save() }
                        .disabled(saving)
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty, mode == .create, kind == .thread {
            error = "Enter a thread title."
            return
        }
        saving = true
        error = nil
        Task {
            do {
                try await submit(name, description.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } catch {
                saving = false
                self.error = errorText(error)
            }
        }
    }
}
