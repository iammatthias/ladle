import ApronKit
import SwiftUI

/// The web's PeoplePicker, as form sections: the people picked as chips with ×, a field that
/// narrows the list by name or `@user_id`, and the people, a picked one with a check. New private
/// conversation and Add people both use it.
struct PeoplePickerSections: View {
    let session: ServerSession
    @Binding var picker: PeoplePicker
    let people: [PickPerson]
    /// "To", or "Add".
    let label: String
    /// What an empty list says: "No one to talk to yet".
    let empty: String
    /// Someone you already talk to, while no one is picked, says so and opens it on a tap.
    var tagsExisting = false
    /// At the private room limit the people give way to the rooms to leave.
    var listed = true
    var disabled = false
    let choose: (PickPerson) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Section {
            if !picker.chosen.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Tokens.Space.s1) {
                        ForEach(picker.chosen, id: \.self) { chip($0) }
                    }
                }
                .scrollClipDisabled()
            }
            TextField("Name or @user_id", text: $picker.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .disabled(disabled)
        } header: {
            Text(label)
        }
        .onAppear { focused = !disabled }
        if listed {
            Section {
            if people.isEmpty {
                Text(picker.query.isEmpty ? empty : "No one matches “\(picker.query)”").apText(.ui).foregroundStyle(Palette.inkMuted)
            }
            ForEach(people) { person in row(person) }
            }
        }
    }

    private func chip(_ userID: String) -> some View {
        let name = session.pickedName(userID)
        return Button { picker.toggle(userID) } label: {
            HStack(spacing: Tokens.Space.s1) {
                Avatar(name: name, userID: userID, size: .xs, image: session.avatarURL(of: userID))
                Text(name).apText(.sm, .medium).foregroundStyle(Palette.ink).lineLimit(1)
                Image(systemName: "xmark").imageScale(.small).foregroundStyle(Palette.inkMuted)
            }
            .padding(.horizontal, Tokens.Space.s2)
            .padding(.vertical, Tokens.Space.s1)
            .background(Palette.privateSoft, in: Capsule())
            .frame(minHeight: Tokens.Size.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(name)")
    }

    private func row(_ person: PickPerson) -> some View {
        let picked = picker.chosen.contains(person.userID)
        let tag = tagsExisting && person.existing && picker.chosen.isEmpty ? "Already talking · Open" : nil
        return Button { choose(person) } label: {
            HStack(spacing: Tokens.Space.s2) {
                Avatar(name: person.name, userID: person.userID, presence: person.typed ? nil : session.presence(of: person.userID),
                       size: .sm, image: person.typed ? nil : session.avatarURL(of: person.userID))
                VStack(alignment: .leading, spacing: 0) {
                    Text(person.name).apText(.ui, .medium).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(person.typed ? "Add by @user_id: @\(person.userID)" : tag ?? "@\(person.userID)")
                        .apText(.sm).foregroundStyle(tag != nil ? Palette.denim : Palette.inkMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if picked { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
            .frame(minHeight: Tokens.Size.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
