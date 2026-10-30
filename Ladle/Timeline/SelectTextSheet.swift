import SwiftUI
import UIKit

/// A message's or notice's text in a sheet where any part of it can be selected, with the
/// system's Copy, Look Up, Translate and Share. A SwiftUI `Text` on iOS selects only all of
/// itself, and its long press would compete with the row's context menu, so the menu's Select
/// Text opens this instead.
struct SelectTextSheet: View {
    let text: String
    let done: () -> Void

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .padding(.horizontal, Tokens.Space.s4 - 5)
                .background(Palette.timeline)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.timeline)
    }
}

/// A read-only `UITextView`: selectable in part, in the body text role, scaled with Dynamic Type.
struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: TextRole.body.size))
        view.textColor = UIColor(Palette.ink)
        view.textContainerInset = UIEdgeInsets(top: Tokens.Space.s4, left: 0, bottom: Tokens.Space.s4, right: 0)
        view.alwaysBounceVertical = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
