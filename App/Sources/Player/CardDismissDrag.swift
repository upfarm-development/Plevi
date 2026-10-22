import SwiftUI
import UIKit

/// Pulling a full-screen card down to close it, the way a sheet does.
struct CardDismissDrag: UIViewRepresentable {
    /// Whether a downward drag should close rather than scroll — true only
    /// when the list inside is already at its top.
    /// Given where the drag began, in the window's coordinates.
    let canBegin: (CGPoint) -> Bool
    /// Hides and shows the real card while the stand-in is the one moving.
    let setCardHidden: (Bool) -> Void
    /// Thrown or carried past the threshold: the screen closes.
    let onClose: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = Host()
        view.recognizer = context.coordinator.recognizer
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.canBegin = canBegin
        context.coordinator.setCardHidden = setCardHidden
        context.coordinator.onClose = onClose
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(canBegin: canBegin, setCardHidden: setCardHidden, onClose: onClose)
    }

    /// Carries the recognizer to an ancestor and takes it away again.
    final class Host: UIView {
        var recognizer: UIPanGestureRecognizer?
        weak var coordinator: Coordinator?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let recognizer else { return }
            if let window, recognizer.view !== window {
                recognizer.view?.removeGestureRecognizer(recognizer)
                window.addGestureRecognizer(recognizer)
            } else if window == nil {
                recognizer.view?.removeGestureRecognizer(recognizer)
                // The screen is going while a stand-in is still up — thrown away mid-settle by a
                // navigation, say.
                coordinator?.hostLeftWindow()
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let recognizer = UIPanGestureRecognizer()
        var canBegin: (CGPoint) -> Bool
        var setCardHidden: (Bool) -> Void
        var onClose: () -> Void

        /// The snapshot standing in for the card, while a drag or its
        /// settling-back is in flight.
        private var standIn: UIView?
        /// The spring carrying the stand-in home after an early release.
        private var settle: UIViewPropertyAnimator?
        /// Where the stand-in was when a new grab caught it mid-spring.
        private var grabbedAt: CGFloat = 0
        /// Lifting the settled copy off the card, a couple of frames after
        /// the spring finishes — held so a finger arriving in between can
        /// call it off and take the copy back over.
        private var pendingLift: DispatchWorkItem?
        /// Set once the card has been told to close.
        private var isDismissing = false

        init(
            canBegin: @escaping (CGPoint) -> Bool,
            setCardHidden: @escaping (Bool) -> Void,
            onClose: @escaping () -> Void
        ) {
            self.canBegin = canBegin
            self.setCardHidden = setCardHidden
            self.onClose = onClose
            super.init()
            recognizer.addTarget(self, action: #selector(handle(_:)))
            recognizer.delegate = self
            // Taps never move far enough to recognize, so buttons and rows keep their touches; a
            // drag that does recognize is a dismissal, and cancelling the list's own touches then
            // is what keeps it from rubber-banding invisibly under the frozen picture.
            recognizer.cancelsTouchesInView = true
        }

        @objc func handle(_ pan: UIPanGestureRecognizer) {
            let travelled = pan.translation(in: pan.view).y
            switch pan.state {
            case .began:
                begin(pan)
                move(travelled)
            case .changed:
                move(travelled)
            case .ended:
                finish(travelled: travelled, velocity: pan.velocity(in: pan.view).y)
            case .cancelled, .failed:
                // Taken away rather than let go — a call arriving, the app going to the background.
                settleBack(velocity: 0)
            default:
                break
            }
        }

        private func begin(_ pan: UIPanGestureRecognizer) {
            guard let window = pan.view as? UIWindow else { return }
            if let existing = standIn {
                // Caught before the last one was finished with: either mid-spring, or in the couple
                // of frames between the spring ending and the copy being lifted off.
                settle?.stopAnimation(true)
                settle = nil
                pendingLift?.cancel()
                pendingLift = nil
                grabbedAt = existing.transform.ty
                // It may have been shown again by a completed settle.
                setCardHidden(true)
                return
            }
            guard let copy = window.snapshotView(afterScreenUpdates: false) else { return }
            copy.frame = window.bounds
            copy.isUserInteractionEnabled = false
            copy.layer.cornerCurve = .continuous
            copy.layer.masksToBounds = true
            window.addSubview(copy)
            standIn = copy
            grabbedAt = 0
            // Under the copy, which is showing the same pixels — nothing
            // changes on screen until the finger moves.
            setCardHidden(true)
        }

        private func move(_ travelled: CGFloat) {
            guard let standIn else { return }
            let carried = max(0, grabbedAt + travelled)
            standIn.transform = CGAffineTransform(translationX: 0, y: carried)
            // Square at rest, fully rounded by twenty points of travel — the same ramp the card
            // itself used to draw, for the same reason: a radius that switches on cuts a visible
            // arc out of the artwork's corners in a single frame.
            standIn.layer.cornerRadius = min(38, carried * 1.9)
        }

        /// Let go: either it goes, or it settles back.
        private func finish(travelled: CGFloat, velocity: CGFloat) {
            guard let standIn else { return }
            let carried = max(0, grabbedAt + travelled)
            guard carried > 140 || velocity > 900 else {
                settleBack(velocity: velocity)
                return
            }
            isDismissing = true
            // The real card leaves invisibly behind the sliding copy.
            setCardHidden(false)
            onClose()
            let clear = (standIn.superview?.bounds.height ?? 900) + 60
            // The class animator rather than a property animator, and the copy captured strongly
            // with no reference to `self`, so the slide-out and its cleanup both survive this
            // coordinator being torn down with the screen it just closed.
            UIView.animate(
                withDuration: 0.26,
                delay: 0,
                options: [.curveEaseOut]
            ) {
                standIn.transform = CGAffineTransform(translationX: 0, y: clear)
            } completion: { _ in
                standIn.removeFromSuperview()
            }
            self.standIn = nil
        }

        /// Home again, on a spring, with the card shown underneath before
        /// the copy is lifted off it.
        private func settleBack(velocity: CGFloat) {
            guard let standIn else { return }
            settle?.stopAnimation(true)
            let distance = max(abs(standIn.transform.ty), 1)
            let spring = UISpringTimingParameters(
                dampingRatio: 0.85,
                initialVelocity: CGVector(dx: 0, dy: velocity / distance)
            )
            let animator = UIViewPropertyAnimator(duration: 0.4, timingParameters: spring)
            animator.addAnimations {
                standIn.transform = .identity
                standIn.layer.cornerRadius = 0
            }
            animator.addCompletion { [weak self] _ in
                // The card comes back under the copy — the same pixels — and only then is the copy
                // lifted off, a couple of frames later, so there is never a moment with neither on
                // screen.
                self?.setCardHidden(false)
                self?.settle = nil
                let lift = DispatchWorkItem { [weak self] in
                    standIn.removeFromSuperview()
                    if self?.standIn === standIn { self?.standIn = nil }
                    self?.pendingLift = nil
                }
                self?.pendingLift = lift
                // `standIn` is deliberately still held until this fires: a finger arriving inside
                // these two frames must be handed the copy that is still on screen, not photograph
                // the screen again with that copy in the picture.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: lift)
            }
            animator.startAnimation()
            settle = animator
        }

        /// The screen left while a stand-in was still up. A dismissal's own
        /// slide is already looking after itself; anything else is a copy
        /// about to be orphaned, and goes down with the screen.
        func hostLeftWindow() {
            guard !isDismissing else { return }
            settle?.stopAnimation(true)
            settle = nil
            pendingLift?.cancel()
            pendingLift = nil
            standIn?.removeFromSuperview()
            standIn = nil
            // The card is going with nothing having been dismissed — pushed aside by a navigation,
            // say.
            setCardHidden(false)
        }

        /// Downwards, mostly vertical, from the top of the list, on a screen that is still there —
        /// and with nothing of its own presented over it.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, !isDismissing else {
                return false
            }
            let velocity = pan.velocity(in: pan.view)
            // Where the finger came down, not where it is now: by the time
            // this is asked the touch has already moved, and it is the
            // start that says which region the drag belongs to.
            let start = pan.location(in: pan.view) - pan.translation(in: pan.view)
            guard velocity.y > 0, abs(velocity.y) > abs(velocity.x), canBegin(start) else {
                return false
            }
            // The recognizer lives on the window, which is above everything — including the sleep
            // timer and the lyrics, which the player presents over itself.
            return !isCoveredByAnotherScreen(pan.view as? UIWindow)
        }

        /// Whether something is presented over the screen this belongs to.
        private func isCoveredByAnotherScreen(_ window: UIWindow?) -> Bool {
            var top = window?.rootViewController
            var depth = 0
            while let presented = top?.presentedViewController, depth < 8 {
                // A popover or an alert sits *on* the screen rather than over
                // it, and the card is still the thing a drag from the top
                // belongs to.
                if presented.modalPresentationStyle != .popover { return true }
                top = presented
                depth += 1
            }
            return false
        }

        /// The list gives this first refusal on a downward drag.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer
        }

        /// Alongside the list rather than instead of it.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private extension CGPoint {
    static func - (point: CGPoint, offset: CGPoint) -> CGPoint {
        CGPoint(x: point.x - offset.x, y: point.y - offset.y)
    }
}
