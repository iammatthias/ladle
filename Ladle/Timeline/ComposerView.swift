import ApronKit
import GameController
import SwiftUI

struct ComposerView: View {
    let session: ServerSession
    @Binding var draft: Draft
    let onSend: (String) -> Void
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let palette = theme.palette
        VStack(alignment: .leading, spacing: 6) {
            if let target {
                HStack(spacing: 8) {
                    Image(systemName: isEdit ? "pencil" : "arrowshape.turn.up.left.fill")
                        .foregroundStyle(palette.accent.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isEdit ? "Editing your message" : "Replying to \(session.displayName(for: target.from))")
                            .font(theme.font(.caption, theme.metaFace, weight: .semibold))
                            .foregroundStyle(palette.text.color)
                        Text(target.plainText)
                            .font(theme.font(.caption))
                            .foregroundStyle(palette.secondary.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Cancel", systemImage: "xmark.circle.fill") { draft = Draft() }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(palette.secondary.color)
                        .frame(minWidth: 44, minHeight: 44)
                        .keyboardShortcut(.cancelAction)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft.text, axis: .vertical)
                    .font(theme.font(.body))
                    .foregroundStyle(palette.text.color)
                    .lineLimit(1 ... 6)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(palette.surface.color, in: RoundedRectangle(cornerRadius: theme.layout == .dense ? 8 : 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: theme.layout == .dense ? 8 : 22, style: .continuous).strokeBorder(focused ? palette.accent.color : palette.separator.color, lineWidth: focused ? 1.5 : 1))
                    .onSubmit(send)
                Button("Send", systemImage: "arrow.up") { send() }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.bold))
                    .foregroundStyle(palette.onAccent.color)
                    .frame(width: 44, height: 44)
                    .background(canSend ? palette.accent.color : palette.secondary.color.opacity(0.4), in: Circle())
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            if theme.direction == .pass, GCKeyboard.coalesced != nil {
                Text("⌘↩ send · ⌘R reply to last · esc cancel")
                    .font(theme.font(.caption2, .mono))
                    .foregroundStyle(palette.secondary.color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: draft.mode.isActive, initial: true) { if draft.mode.isActive { focused = true } }
    }

    private var target: MessageSnapshot? {
        switch draft.mode {
        case .new: nil
        case .reply(let message), .edit(let message): message
        }
    }

    private var isEdit: Bool {
        if case .edit = draft.mode { return true }
        return false
    }

    private var canSend: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.status == .signedIn
    }

    private func send() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
    }
}

private extension Draft.Mode {
    var isActive: Bool {
        if case .new = self { return false }
        return true
    }
}
