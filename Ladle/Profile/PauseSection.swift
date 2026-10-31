import ApronKit
import SwiftUI

/// apron-web's Pause notifications (`PauseNotifications`), in Preferences > Notifications for one
/// server: a Pause… menu of how long, or Resume while paused, which only ask; the line changes
/// when the server's `status` says so, perhaps shorter.
struct PauseSection: View {
    let session: ServerSession
    /// The server's name, where Notifications lists several.
    var header: String?
    /// What the server refused of the last Pause or Resume (§4.5: nothing changed), until the next.
    @State private var refused: (title: String, message: String)?
    @State private var pausing = false

    private var connected: Bool { session.status == .signedIn }

    var body: some View {
        Section {
            if let paused = session.pausedLine {
                Label("\(paused) · no notifications on your devices.", systemImage: "bell.slash")
                    .apText(.ui).foregroundStyle(Palette.warn)
                Button("Resume") { ask(nil) }
                    .disabled(pausing || !connected)
            } else {
                Menu {
                    ForEach(MuteChoice.pause(now: Date())) { choice in
                        Button {
                            ask(choice.end)
                        } label: {
                            Text(choice.title)
                            if let hint = choice.hint { Text(hint) }
                        }
                    }
                } label: {
                    Label(pausing ? "Pausing…" : "Pause…", systemImage: "bell.slash")
                }
                .disabled(pausing || !connected)
            }
            if let refused {
                Callout(title: refused.title) { Text(refused.message) }
                    .listRowInsets(EdgeInsets(top: Tokens.Space.s2, leading: Tokens.Space.s4, bottom: Tokens.Space.s2, trailing: Tokens.Space.s4))
            }
        } header: {
            Text(header.map { "Pause Notifications on \($0)" } ?? "Pause Notifications")
        } footer: {
            if session.pause == nil {
                Text("Silence notifications on all your devices for a while. Only you see it.")
            }
        }
        .listRowBackground(Palette.raised)
    }

    private func ask(_ end: MuteEnd?) {
        pausing = true
        refused = nil
        Task {
            do {
                try await session.setPause(end)
            } catch {
                refused = (end == nil ? "Notifications are still paused" : "Notifications weren’t paused", errorText(error))
                AccessibilityNotification.Announcement(refused?.title ?? "").post()
            }
            pausing = false
        }
    }
}
