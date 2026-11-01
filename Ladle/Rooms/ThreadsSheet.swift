import ApronKit
import SwiftUI

/// A room's threads on iPhone, from Threads in its header's ⋯ menu, since the rooms list is
/// out of sight while a room is open: what the iPad sidebar shows under the open room (joined
/// threads, Inactive, Other Threads with "N more…") from the same `ThreadList`, and New Thread.
/// In a thread it lists its room's threads. Picking one hands it to `open` once the sheet is gone.
struct ThreadsSheet: View {
    let session: ServerSession
    let roomID: String
    let open: (String) -> Void
    let newThread: () -> Void
    @AppStorage("otherThreadsOpen") private var othersOpen = true
    @AppStorage("inactiveThreadsOpen") private var inactiveOpen = false
    @State private var allOthers = false
    @Environment(\.fixedNow) private var fixedNow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let node = session.threadNode(of: roomID), !node.threadIDs.isEmpty {
                    threads(of: node)
                } else {
                    EmptyState(title: "No threads yet", detail: "Start one to talk about something on the side.") { EmptyView() }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Tokens.Size.touchTarget)
            .background(Palette.chrome)
            .navigationTitle("Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if session.status == .signedIn, session.server?.has("rooms") == true,
                   session.joinedRoomIDs.contains(session.topLevelRoom(of: roomID)) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Thread", systemImage: "plus") {
                            newThread()
                            dismiss()
                        }
                        .disabled(!session.mayWrite)
                        .accessibilityHint(session.mayWrite ? "" : ReadOnlyPrompt.reason(session))
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.chrome)
    }

    @ViewBuilder
    private func threads(of node: RoomNode) -> some View {
        let list = session.threadList(of: node, open: roomID, othersFolded: !othersOpen, allOthers: allOthers,
                                      now: fixedNow ?? .now, inactiveFolded: !inactiveOpen)
        ForEach(list.joined, id: \.self, content: row)
        if list.inactiveCount > 0 {
            FoldHeading(label: "Inactive", count: list.inactiveCount, open: $inactiveOpen)
            ForEach(list.inactive, id: \.self, content: row)
        }
        if list.othersCount > 0 {
            FoldHeading(label: "Other Threads", count: list.othersCount, open: $othersOpen)
            ForEach(list.others, id: \.self, content: row)
            if list.moreOthers > 0 {
                Button { allOthers = true } label: {
                    Text("\(list.moreOthers) more…").apText(.sm, .medium).foregroundStyle(Palette.denim)
                        .padding(.leading, RoomRow.threadInset)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: Tokens.Space.s2, bottom: 0, trailing: Tokens.Space.s2))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityHint("Shows every other thread of \(session.title(of: node.roomID))")
            }
        }
    }

    private func row(_ threadID: String) -> some View {
        Button {
            if threadID != roomID { open(threadID) }
            dismiss()
        } label: {
            RoomRow(session: session, roomID: threadID, isThread: true, isSelected: threadID == roomID, now: fixedNow ?? .now)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: Tokens.Space.s2, bottom: 1, trailing: Tokens.Space.s2))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(threadID == roomID ? .isSelected : [])
    }
}
