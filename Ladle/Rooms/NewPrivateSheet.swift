import ApronKit
import SwiftUI

/// The web's PrivateRoomForm, from the + beside Private: starts a private room (§4.2.4) with the
/// people picked, with a Name once two or more are, and how many private rooms you're in of the
/// most the server allows. One person you already talk to opens that conversation instead. At
/// the limit it offers your private rooms to leave, the quietest first.
struct NewPrivateSheet: View {
    let session: ServerSession
    /// Opens the room, with what couldn't be done in it (who wasn't added).
    @State var picker = PeoplePicker()
    let open: (String, String?) -> Void
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @State private var leaving: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fixedNow) private var fixedNow

    /// The most of your private rooms offered to leave at the limit; "and N more" for the rest.
    static let fullShown = 5

    var body: some View {
        let full = session.atPrivateRoomLimit
        NavigationStack {
            Form {
                PeoplePickerSections(session: session, picker: $picker, people: full ? [] : session.privatePeople(picker), label: "To",
                                     empty: "No one to talk to yet", tagsExisting: true, listed: !full, disabled: full || saving, choose: choose)
                if full {
                    fullSection
                } else if picker.chosen.count >= 2 {
                    Section {
                        TextField("Named for its people without one", text: $name)
                            .onChange(of: name) { if name.count > RoomFormSheet.titleLimit { name = String(name.prefix(RoomFormSheet.titleLimit)) } }
                            .disabled(saving)
                    } header: {
                        Text("Name").formHeader()
                    } footer: {
                        Text("Optional").formFooter()
                    }
                }
                if let error {
                    Section { Text(error).apText(.ui).foregroundStyle(Palette.danger) }
                }
                if let quota = session.privateRoomQuota {
                    Section {
                        QuotaLine(used: quota.used, max: quota.max)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("A private room that only the people you pick can see.")
                    .apText(.sm).foregroundStyle(Palette.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Tokens.Space.s1)
                    .background(Palette.chrome)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ServerSession.startWords(chosen: picker.chosen, saving: saving)) { start() }
                        .disabled(saving || full || picker.chosen.isEmpty || !session.mayStartPrivate)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var fullSection: some View {
        let mine = session.privateRoomsQuietestFirst
        Section {
            Callout(title: "You’re in \(mine.count) private \(mine.count == 1 ? "room" : "rooms"), the most this server allows at once.") {
                Text("Leave one to start another.")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        Section {
            ForEach(mine.prefix(Self.fullShown), id: \.self) { roomID in
                HStack(spacing: Tokens.Space.s2) {
                    Faces(session: session, people: session.faces(of: roomID), size: .md)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.title(of: roomID)).apText(.ui, .medium).foregroundStyle(Palette.ink).lineLimit(1)
                        if let detail = session.lastActiveDetail(of: roomID, now: fixedNow ?? .now) {
                            Text(detail).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(leaving.contains(roomID) ? "Leaving…" : "Leave") { leave(roomID) }
                        .buttonStyle(GhostButtonStyle(tone: Palette.danger))
                        .disabled(leaving.contains(roomID))
                        .accessibilityLabel("Leave \(session.title(of: roomID))")
                }
                .frame(minHeight: Tokens.Size.touchTarget)
            }
            if mine.count > Self.fullShown {
                Text("and \(mine.count - Self.fullShown) more").apText(.sm).foregroundStyle(Palette.inkMuted)
            }
        } header: {
            Text("Your private rooms, quietest first").formHeader()
        }
    }

    /// Picked alone, a person you already talk to opens that conversation instead.
    private func choose(_ person: PickPerson) {
        error = nil
        if person.existing, picker.chosen.isEmpty, let room = session.directRoom(with: person.userID) {
            dismiss()
            open(room, nil)
        } else {
            picker.toggle(person.userID)
        }
    }

    private func leave(_ roomID: String) {
        leaving.insert(roomID)
        error = nil
        Task {
            do { try await session.leave(roomID) } catch { self.error = errorText(error) }
            leaving.remove(roomID)
        }
    }

    private func start() {
        let chosen = picker.chosen
        if chosen.count == 1, let existing = session.directRoom(with: chosen[0]) {
            dismiss()
            open(existing, nil)
            return
        }
        saving = true
        error = nil
        Task {
            do {
                let started = try await session.startPrivateRoom(with: chosen, title: chosen.count > 1 ? name : nil)
                dismiss()
                open(started.roomID, started.refused.isEmpty ? nil : Refusal.words(started.refused, name: session.pickedName))
            } catch {
                saving = false
                self.error = errorText(error)
            }
        }
    }
}

/// The web's quota: "2 of 5" private rooms, with a bar of pips up to ten, in the warning color at the limit.
struct QuotaLine: View {
    let used: Int
    let max: Int

    var body: some View {
        let full = used >= max
        HStack(spacing: Tokens.Space.s2) {
            if max <= 10 {
                HStack(spacing: 3) {
                    ForEach(0 ..< max, id: \.self) { index in
                        Capsule().fill(index < used ? (full ? Palette.warn : Palette.private) : Palette.line)
                            .frame(width: 10, height: 4)
                    }
                }
                .accessibilityHidden(true)
            }
            Text("\(used) of \(max)").apText(.sm, .medium).monospacedDigit().foregroundStyle(full ? Palette.warn : Palette.inkMuted)
            Spacer(minLength: 0)
            Text("Private rooms you’re in").apText(.sm).foregroundStyle(Palette.inkMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Private rooms you’re in: \(used) of \(max), the most this server allows at once")
    }
}
