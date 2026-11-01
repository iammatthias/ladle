import ApronKit
import SwiftUI

/// Read receipts at the end of a message's first line, as apron-web's ReadReceipts (#187): the
/// faces of those who have read up to it and no further, the first three overlapping a little,
/// each ringed in the timeline's ground, then "+N". The row reads them to VoiceOver as "Seen by
/// …", and a pointer hovering over them shows the same words.
struct ReadReceipts: View {
    let session: ServerSession
    let readers: [Reader]

    var body: some View {
        let shown = readers.prefix(3)
        HStack(spacing: -3) {
            ForEach(shown, id: \.user.userID) { reader in
                Avatar(name: reader.name, userID: reader.user.userID, size: .xs, image: session.avatarURL(of: reader.user.userID))
                    .padding(1.5)
                    .background(Palette.timeline, in: Circle())
            }
            if readers.count > 3 {
                Text("+\(readers.count - 3)").apText(.xs).foregroundStyle(Palette.inkMuted)
                    .padding(.leading, Tokens.Space.s1 + 3)
            }
        }
        .help(SeenBy.words(readers.map(\.name)))
        .accessibilityHidden(true)
    }
}
