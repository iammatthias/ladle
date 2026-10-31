import ApronKit
import SwiftUI

/// The web's AddMembersForm, from the member list's +: adds the people picked to the room or
/// thread (`room_join` with each `user_id`, §4.2.2), from those the session knows who aren't
/// members yet, or by a `@user_id` typed whole. One the server refuses doesn't stop the rest, and
/// stays picked, with why. Those added show in the timeline as their joins do.
struct AddMembersSheet: View {
    let session: ServerSession
    let roomID: String
    @State var picker = PeoplePicker()
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                PeoplePickerSections(session: session, picker: $picker, people: session.addablePeople(picker, to: roomID), label: "Add",
                                     empty: "No one else to add yet", disabled: saving) { picker.toggle($0.userID) }
                if let error {
                    Section { Text(error).apText(.ui).foregroundStyle(Palette.danger) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Add People to \(session.title(of: roomID))")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("Pick people by name, or type their @user_id.")
                    .apText(.sm).foregroundStyle(Palette.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Tokens.Space.s1)
                    .background(Palette.chrome)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add") { add() }
                        .disabled(saving || picker.chosen.isEmpty || !session.mayAddMembers(to: roomID))
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .presentationDetents([.large])
    }

    private func add() {
        saving = true
        error = nil
        Task {
            let refused = await session.addMembers(picker.chosen, to: roomID)
            saving = false
            picker.keep(refused.map(\.userID))
            if refused.isEmpty { dismiss() } else { error = Refusal.words(refused, name: session.pickedName) }
        }
    }
}
