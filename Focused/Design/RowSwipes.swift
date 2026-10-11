import SwiftUI
import UIKit

/// One full-swipe action on a row: drag past the mark and let go.
struct RowSwipe {
    var systemName: String
    var label: String
    var action: () -> Void
}

extension View {
    /// Swipe right for `leading`, left for `trailing` (Noah, 2026-10-03:
    /// play or shuffle a Home playlist without opening it). A full swipe
    /// runs the action on release; nothing stays open. Up-and-down drags
    /// still scroll.
    func rowSwipes(leading: RowSwipe, trailing: RowSwipe) -> some View {
        modifier(RowSwipes(leading: leading, trailing: trailing))
    }
}

private struct RowSwipes: ViewModifier {
    var leading: RowSwipe
    var trailing: RowSwipe
    @Environment(\.look) private var look
    @State private var offset: CGFloat = 0
    @State private var fired = 0

    private let threshold: CGFloat = 84
    private var armed: Bool { abs(offset) >= threshold }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background {
                HStack {
                    icon(leading).opacity(offset > 0 ? 1 : 0)
                    Spacer()
                    icon(trailing).opacity(offset < 0 ? 1 : 0)
                }
            }
            .gesture(HorizontalPan(changed: drag, ended: release))
            .sensoryFeedback(.selection, trigger: armed) { old, new in !old && new }
            .sensoryFeedback(.impact(weight: .medium), trigger: fired)
            .accessibilityAction(named: leading.label, leading.action)
            .accessibilityAction(named: trailing.label, trailing.action)
    }

    /// Grows in as the row slides, then fills with the accent once a
    /// release would run it.
    private func icon(_ swipe: RowSwipe) -> some View {
        let progress = min(1, abs(offset) / threshold)
        return Image(systemName: swipe.systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(armed ? look.palette.onAccent : look.palette.accent)
            .frame(width: 46, height: 46)
            .background(armed ? look.palette.accent : look.palette.surface, in: Circle())
            .scaleEffect(0.6 + 0.4 * progress)
            .opacity(progress)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: armed)
            .accessibilityHidden(true)
    }

    /// Follows the finger up to the mark, then drags with resistance.
    private func drag(_ x: CGFloat) {
        let distance = abs(x)
        let eased = distance <= threshold ? distance : threshold + (distance - threshold) * 0.3
        offset = x < 0 ? -eased : eased
    }

    private func release(commit: Bool) {
        let swipe = commit && armed ? (offset > 0 ? leading : trailing) : nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { offset = 0 }
        if let swipe {
            fired += 1
            swipe.action()
        }
    }
}

/// A UIKit pan that only starts on a mostly sideways drag, so it never
/// fights the scroll view (a SwiftUI DragGesture claims vertical drags too).
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    var changed: (CGFloat) -> Void
    var ended: (_ commit: Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed: changed(pan.translation(in: pan.view).x)
        case .ended: ended(true)
        case .cancelled, .failed: ended(false)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}
