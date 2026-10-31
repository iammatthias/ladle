import ApronKit
import SwiftUI

/// The web's MemberList: "Members n", then Online and Offline sections, each person with their
/// face and StatusDot, "(you)" beside you, offline people dimmed. A tap opens their profile
/// card; a long press their menu (Profile, Direct Message, Remove from Room), as apron-web
/// #152 and #161. The + adds people. On iPhone it is a sheet over the room; on iPad a column of
/// its own, as the web's at 960 px and wider.
struct MemberList: View {
    let session: ServerSession
    let roomID: String
    var onMention: (String, String) -> Void = { _, _ in }
    @State private var profile: ProfileRequest?
    @State private var adding = false
    @State private var removing: String?
    @State private var busy = false
    @State private var note: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openRoom) private var openRoom

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
            if let line = note ?? session.memberChangesRemark(in: roomID) {
                Text(line).apText(.sm).foregroundStyle(note != nil ? Palette.danger : Palette.inkMuted)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .sheet(item: $profile) { request in
            ProfileCardView(session: session, request: request, onMention: onMention)
        }
        .sheet(isPresented: $adding) { AddMembersSheet(session: session, roomID: roomID) }
        .confirmationDialog(removing.map { session.removeQuestion($0, from: roomID) } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { userID in
            Button("Remove", role: .destructive) { remove(userID) }
        }
        .onChange(of: roomID) { note = nil }
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
            if session.mayAddMembers(to: roomID) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add People", systemImage: "person.badge.plus") {
                        note = nil
                        adding = true
                    }
                }
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
        return Button { profile = ProfileRequest(user: person, roomID: roomID) } label: {
            HStack(spacing: Tokens.Space.s2) {
                Avatar(name: name, userID: person.userID, presence: presence, size: .sm, image: session.avatarURL(of: person.userID))
                    .opacity(offline ? Tokens.Opacity.dim : 1)
                Text(name).apText(.ui).foregroundStyle(offline ? Palette.inkMuted : Palette.ink).lineLimit(1)
                    .layoutPriority(1)
                if you { Text("(you)").apText(.xs).foregroundStyle(Palette.inkMuted) }
                RoleBadges(roles: session.roles(of: person)).opacity(offline ? Tokens.Opacity.dim : 1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Tokens.Size.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.Space.s4, bottom: 0, trailing: Tokens.Space.s4))
        .contextMenu {
            let menu = session.memberMenu(for: person.userID, in: roomID)
            if !menu.isEmpty { menuItems(person, menu) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([name, you ? "you" : nil] + session.roles(of: person) + [presence.label]).compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows their profile")
        .accessibilityActions {
            let menu = session.memberMenu(for: person.userID, in: roomID)
            if !menu.isEmpty { menuItems(person, menu) }
        }
    }

    /// The web's member menu: Profile, Direct Message, and Remove from Room in the danger color.
    @ViewBuilder
    private func menuItems(_ person: UserObject, _ menu: MemberMenu) -> some View {
        Button("Profile", systemImage: "person") { profile = ProfileRequest(user: person, roomID: roomID) }
        if menu.directMessage {
            Button("Direct Message", systemImage: "bubble.left") { message(person.userID) }.disabled(busy)
        }
        if menu.remove {
            Button("Remove from Room", systemImage: "person.badge.minus", role: .destructive) { removing = person.userID }.disabled(busy)
        }
    }

    /// The conversation you have with them, else one started, opened. One started that couldn't
    /// add them is kept under Private, and the list says so.
    private func message(_ userID: String) {
        busy = true
        note = nil
        Task {
            do {
                let started = try await session.message(userID)
                if started.refused.isEmpty {
                    if sizeClass == .compact { dismiss() }
                    openRoom(started.roomID)
                } else {
                    note = Refusal.words(started.refused, name: session.pickedName) + " The room is kept under Private."
                }
            } catch {
                note = errorText(error)
            }
            busy = false
        }
    }

    private func remove(_ userID: String) {
        busy = true
        note = nil
        Task {
            do { try await session.removeMember(userID, from: roomID) } catch { note = errorText(error) }
            busy = false
        }
    }
}
