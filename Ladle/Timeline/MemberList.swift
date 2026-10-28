import ApronKit
import SwiftUI

/// The web's MemberList: "Members n", then Online and Offline sections, each person with their
/// face and StatusDot, "(you)" beside you, offline people dimmed. On iPhone it is a sheet over
/// the room; on iPad a column of its own, as the web's at 960 px and wider.
struct MemberList: View {
    let session: ServerSession
    let roomID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let sections = session.memberSections(roomID)
        List {
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.people, id: \.userID) { person in row(person, offline: section.title == "Offline") }
                } header: {
                    SectionHead(title: section.title, count: section.people.count)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: Tokens.Space.s2) {
                    Text("Members").font(.headline).foregroundStyle(Palette.ink)
                    Text("\(sections.reduce(0) { $0 + $1.people.count })").apText(.sm, .medium).foregroundStyle(Palette.inkMuted)
                }
                .accessibilityElement(children: .combine)
            }
            if sizeClass == .compact {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ person: UserObject, offline: Bool) -> some View {
        let name = session.displayName(for: person)
        let presence = session.presence(of: person.userID) ?? .offline
        let you = person.userID == session.you?.userID
        return HStack(spacing: Tokens.Space.s2) {
            Avatar(name: name, userID: person.userID, presence: presence, size: .sm)
                .opacity(offline ? Tokens.Opacity.dim : 1)
            Text(name).apText(.ui).foregroundStyle(offline ? Palette.inkMuted : Palette.ink).lineLimit(1)
            if you { Text("(you)").apText(.xs).foregroundStyle(Palette.inkMuted) }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Tokens.Size.touchTarget)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.Space.s4, bottom: 0, trailing: Tokens.Space.s4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, you ? "you" : nil, presence.label].compactMap { $0 }.joined(separator: ", "))
    }
}
