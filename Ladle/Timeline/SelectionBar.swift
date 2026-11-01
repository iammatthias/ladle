import ApronKit
import SwiftUI

/// Select mode's bar in the composer's place, as apron-web's SelectionBar (#54, #164, #175): how
/// many are picked and Select Between, why some couldn't move, then Cancel, Copy (the Markdown
/// log) and Move: back to the room, to one of its threads, or to a new thread.
struct SelectionBar: View {
    let session: ServerSession
    let selection: MessageSelection
    let moving: Bool
    let onSelectBetween: () -> Void
    let onCancel: () -> Void
    let onCopy: () -> Void
    let onMove: (String) -> Void
    let onNewThread: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s3) {
                Text(selection.countWords).apText(.ui, .semibold).foregroundStyle(Palette.ink)
                if selection.ids.count >= 2 {
                    Button("Select Between", action: onSelectBetween).apText(.sm).disabled(moving)
                }
                Spacer(minLength: 0)
            }
            if let denied = selection.denied {
                Text(denied.words).apText(.sm).foregroundStyle(Palette.danger).accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: Tokens.Space.s2) {
                if moving {
                    ProgressView()
                    Text(selection.ids.count == 1 ? "Moving 1…" : "Moving \(selection.ids.count)…").apText(.ui).foregroundStyle(Palette.inkMuted)
                    Spacer(minLength: 0)
                } else {
                    Button("Cancel", action: onCancel).buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                        .buttonStyle(.bordered)
                        .accessibilityHint("Copies them as a Markdown log")
                    if session.server?.has("edit") == true, session.mayWrite {
                        Menu {
                            let destinations = session.selectionDestinations(in: selection.roomID)
                            ForEach(destinations, id: \.self) { roomID in
                                Button(session.store.room(roomID)?.parentRoomID == nil ? "Move to Room" : session.title(of: roomID)) { onMove(roomID) }
                            }
                            if session.server?.has("rooms") == true {
                                Button("New Thread…", systemImage: "plus.bubble", action: onNewThread)
                            }
                        } label: {
                            Label("Move", systemImage: "arrow.right.square")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s3)
        .background(Palette.raised)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected messages")
    }
}

/// A message's check circle in select mode.
struct SelectMark: View {
    let on: Bool

    var body: some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .imageScale(.large)
            .foregroundStyle(on ? Palette.accent : Palette.inkMuted)
            .frame(width: Tokens.Size.touchTarget * 0.6)
            .accessibilityHidden(true)
    }
}

/// Why a new thread for the selection was not made, shown in its form.
struct SelectionProblem: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
