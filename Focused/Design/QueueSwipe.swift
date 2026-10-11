import SwiftUI
import UIKit

extension View {
    func queueOnSwipe(_ track: Track, enabled: Bool = true) -> some View {
        modifier(QueueSwipe(track: track, enabled: enabled))
    }
}

/// Only claims a gesture that begins horizontally to the right. Vertical
/// drags remain the surrounding ScrollView's, and ordinary taps still play.
private struct QueueSwipe: ViewModifier {
    var track: Track
    var enabled: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var armed = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(x: offset)
                .background(alignment: .leading) {
                    Label("Queue", systemImage: "text.badge.plus")
                        .font(look.font(14, .semibold))
                        .foregroundStyle(look.palette.accent)
                        .padding(.leading, 12)
                        .opacity(min(1, offset / 60))
                }
                .contentShape(Rectangle())
                .gesture(RightPan { distance, ended, cancelled in
                    if ended {
                        if !cancelled && armed { model.enqueue([track]) }
                        withAnimation(reduceMotion ? nil : look.animation) { offset = 0; armed = false }
                    } else {
                        offset = min(120, max(0, distance))
                        armed = distance >= 72
                    }
                })
                .sensoryFeedback(.selection, trigger: armed) { _, new in new }
                .accessibilityHint("Swipe right to queue")
                .accessibilityAction(named: "Add to queue") { model.enqueue([track]) }
        } else {
            content
        }
    }
}

private struct RightPan: UIGestureRecognizerRepresentable {
    var changed: (CGFloat, Bool, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let ended = recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
        changed(recognizer.translation(in: recognizer.view?.window).x, ended, recognizer.state != .ended && ended)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            // Leave the screen-edge swipe to the navigation controller's Back gesture.
            let window = pan.view?.window
            let startX = pan.location(in: window).x - pan.translation(in: window).x
            guard startX > 24 else { return false }
            let velocity = pan.velocity(in: window)
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}
