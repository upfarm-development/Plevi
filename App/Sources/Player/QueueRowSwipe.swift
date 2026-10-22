import SwiftUI
import UIKit

/// A sideways drag on one queue row, in UIKit.
struct QueueRowSwipe: UIViewRepresentable {
    /// How far across the finger has come, negative to the left.
    let onChanged: (CGFloat) -> Void
    /// Where it got to, and where it was still heading when it was let go.
    let onEnded: (_ translation: CGFloat, _ predictedEnd: CGFloat) -> Void
    /// The touch was taken away rather than let go.
    let onCancelled: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = Host()
        view.recognizer = context.coordinator.recognizer
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded, onCancelled: onCancelled)
    }

    final class Host: UIView {
        var recognizer: UIPanGestureRecognizer?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        /// Rows are reused as the queue scrolls, so the recognizer is taken off whatever it was on
        /// before it is put anywhere new.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let recognizer else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            guard window != nil, let row = enclosingRow() else { return }
            row.addGestureRecognizer(recognizer)
        }

        /// The cell this row is drawn in — the largest thing that is still
        /// only this row. Anything above it spans the whole queue, and a
        /// recognizer up there would answer for every song at once.
        private func enclosingRow() -> UIView? {
            var view: UIView? = superview
            while let current = view {
                if current is UICollectionViewCell || current is UITableViewCell {
                    return current
                }
                view = current.superview
            }
            return superview
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let recognizer = UIPanGestureRecognizer()
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        var onCancelled: () -> Void

        init(
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void,
            onCancelled: @escaping () -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
            super.init()
            recognizer.addTarget(self, action: #selector(pan(_:)))
            recognizer.delegate = self
        }

        /// The list this row is in, held still while a row is being swiped.
        private weak var heldStill: UIScrollView?

        /// Stops the queue scrolling under a finger that is going sideways.
        private func holdListStill(from view: UIView?) {
            var next = view?.superview
            while let current = next {
                if let scroll = current as? UIScrollView {
                    heldStill = scroll
                    scroll.isScrollEnabled = false
                    return
                }
                next = current.superview
            }
        }

        private func letListGo() {
            heldStill?.isScrollEnabled = true
            heldStill = nil
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let view = recognizer.view
            let translation = recognizer.translation(in: view).x
            switch recognizer.state {
            case .began:
                holdListStill(from: view)
                onChanged(translation)
            case .changed:
                onChanged(translation)
            case .ended:
                letListGo()
                // Where it would have come to rest, worked out the way
                // SwiftUI's own `predictedEndTranslation` is: the velocity
                // carried on and allowed to decay.
                let velocity = recognizer.velocity(in: view).x
                onEnded(translation, translation + velocity * Self.deceleration)
            case .cancelled, .failed:
                letListGo()
                // Settled back, never committed.
                onCancelled()
            default:
                break
            }
        }

        /// Seconds of coasting after the finger leaves, which is the constant
        /// UIKit's own scroll views settle by.
        private static let deceleration: CGFloat = 0.25

        /// Whether this is a sideways drag.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// Alongside the list's own scrolling rather than instead of it. A
        /// sideways drag is nothing a vertical list wants anyway.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
