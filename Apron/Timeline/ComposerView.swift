import ApronKit
import SwiftUI

struct ComposerView: View {
    let session: ServerSession
    @Binding var draft: Draft
    let onSend: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let banner {
                HStack {
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel", systemImage: "xmark.circle.fill") { draft = Draft() }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom) {
                TextField("Message", text: $draft.text, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                Button("Send", systemImage: "arrow.up.circle.fill") {
                    let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    onSend(text)
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.status != .signedIn)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: draft.mode.isActive) { if draft.mode.isActive { focused = true } }
    }

    private var banner: String? {
        switch draft.mode {
        case .new: nil
        case .reply(let message): "Replying to \(session.displayName(for: message.from))"
        case .edit: "Editing message"
        }
    }
}

private extension Draft.Mode {
    var isActive: Bool {
        if case .new = self { return false }
        return true
    }
}
