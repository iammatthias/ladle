import ApronKit
import SwiftUI
import UIKit

/// Picks a reaction: the server's custom emoji (`ext:emoji`) by category, the frequent ones as
/// one row, then any emoji from the system emoji keyboard. The web opens emoji-mart in a bottom
/// sheet on phones; iOS has its own emoji keyboard with search and recents, so Ladle uses that
/// rather than drawing a grid of standard emoji.
struct ReactionPicker: View {
    static let quick = ["👍", "❤️", "😂", "🎉", "👀", "🙏"]
    var session: ServerSession?
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    if let catalog = session?.emojiCatalog {
                        ForEach(Array(Self.groups(catalog).enumerated()), id: \.offset) { _, group in
                            Text(group.title).apText(.sm, .semibold).foregroundStyle(Palette.inkMuted)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Size.touchTarget), spacing: Tokens.Space.s2)],
                                      spacing: Tokens.Space.s2) {
                                ForEach(group.emoji, id: \.key) { emoji in
                                    Button { pick(emoji.key) } label: {
                                        EmojiTile(emoji: emoji, side: 28)
                                            .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchTarget)
                                            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(emoji.label)
                                }
                            }
                        }
                    }
                    HStack(spacing: Tokens.Space.s2) {
                        ForEach(Self.quick, id: \.self) { emoji in
                            Button(emoji) { pick(emoji) }
                                .font(.system(size: 28))
                                .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchTarget)
                                .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                                .buttonStyle(.plain)
                        }
                    }
                    Text("Any emoji").apText(.sm, .semibold).foregroundStyle(Palette.inkMuted)
                    EmojiField(pick: pick)
                        .frame(height: Tokens.Size.touchTarget)
                        .padding(.horizontal, Tokens.Space.s3)
                        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.lineStrong))
                }
                .padding(Tokens.Space.s4)
            }
            .background(Palette.chrome)
            .task { await session?.loadEmojiCatalog() }
            .navigationTitle("Add Reaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

extension ReactionPicker {
    /// The offered custom emoji by category, those without one first under "Custom".
    static func groups(_ catalog: EmojiCatalog) -> [(title: String, emoji: [CustomEmoji])] {
        var groups: [(title: String, emoji: [CustomEmoji])] = []
        for emoji in catalog.offered {
            let title = emoji.category ?? "Custom"
            if groups.last?.title == title { groups[groups.count - 1].emoji.append(emoji) } else { groups.append((title, [emoji])) }
        }
        return groups
    }
}

/// A field that opens on the emoji keyboard and reports the first emoji typed.
private struct EmojiField: UIViewRepresentable {
    let pick: (String) -> Void

    func makeUIView(context: Context) -> EmojiTextField {
        let field = EmojiTextField()
        field.placeholder = "Type or search for an emoji"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = UIColor(Palette.ink)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: EmojiTextField, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(pick: pick) }

    final class Coordinator: NSObject {
        let pick: (String) -> Void
        init(pick: @escaping (String) -> Void) { self.pick = pick }

        @MainActor @objc func changed(_ field: UITextField) {
            guard let emoji = field.text?.first(where: { $0.unicodeScalars.first?.properties.isEmojiPresentation == true || $0.unicodeScalars.count > 1 }) else { return }
            field.text = ""
            pick(String(emoji))
        }
    }
}

final class EmojiTextField: UITextField {
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}
