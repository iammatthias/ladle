import ApronKit
import SwiftUI

/// The bell-off a muted room or thread carries, as the web's `ap-muted`.
struct MutedBell: View {
    var body: some View {
        Image(systemName: "bell.slash")
            .imageScale(.small)
            .foregroundStyle(Palette.inkMuted)
            .accessibilityLabel("Muted")
    }
}

/// Mute or Unmute for a room or thread, as the web's RoomHeader ⋯ menu offers them: Mute is a
/// submenu of how long, each with when it would end, worked out as the menu opens; Unmute names
/// the room whose mute silences a thread, and says when it would end anyway.
struct MuteActions: View {
    let session: ServerSession
    let roomID: String
    let perform: (@escaping () async throws -> Void) -> Void

    var body: some View {
        if session.mayMute {
            let noun = session.store.room(roomID)?.parentRoomID == nil ? "Room" : "Thread"
            if let mute = session.mute(of: roomID) {
                Button {
                    let target = if case .withRoom(let parent, _) = mute { parent } else { roomID }
                    perform { try await session.setMute(target, nil) }
                } label: {
                    Label {
                        Text(mute.isWithRoom ? "Unmute Room" : "Unmute \(noun)")
                        Text(session.muteWords(mute))
                    } icon: {
                        Image(systemName: "bell")
                    }
                }
            } else {
                Menu {
                    ForEach(MuteChoice.room(now: Date())) { choice in
                        Button {
                            perform { try await session.setMute(roomID, choice.end) }
                        } label: {
                            Text(choice.title)
                            if let hint = choice.hint { Text(hint) }
                        }
                    }
                } label: {
                    Label("Mute \(noun)", systemImage: "bell.slash")
                }
            }
        }
    }
}
