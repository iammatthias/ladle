import SwiftUI
import UIKit

/// Calls `onInput` on every touch in the window it sits in, without taking part in any gesture:
/// what `Attention` counts as someone using the app (§4.5 `idle`), as apron-web counts pointer and
/// key events on the page.
struct InputWatcher: UIViewRepresentable {
    let onInput: () -> Void

    func makeUIView(context: Context) -> WatchingView {
        let view = WatchingView()
        view.isUserInteractionEnabled = false
        view.onInput = onInput
        return view
    }

    func updateUIView(_ view: WatchingView, context: Context) {
        view.onInput = onInput
    }

    final class WatchingView: UIView {
        var onInput: () -> Void = {}
        private let recognizer = TouchObserver()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            guard let window else { return }
            recognizer.onTouch = { [weak self] in self?.onInput() }
            window.addGestureRecognizer(recognizer)
        }
    }

    /// Sees each touch begin and then fails, so every other recognizer and control works as before.
    final class TouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var onTouch: () -> Void = {}

        override init(target: Any? = nil, action: Selector? = nil) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .failed
            onTouch()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
