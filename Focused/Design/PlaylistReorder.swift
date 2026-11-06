import SwiftUI

extension View {
    func playlistReorder(id: String, among ids: [String]) -> some View {
        modifier(PlaylistReorder(id: id, ids: ids))
    }
}

private struct PlaylistReorder: ViewModifier {
    let id: String
    let ids: [String]
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    @State private var moved = false
    private let prefix = "focused-playlist:"

    func body(content: Content) -> some View {
        content
            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 20))
            .draggable(prefix + id)
            .dropDestination(for: String.self) { values, _ in
                guard values.count == 1, let value = values.first, value.hasPrefix(prefix) else { return false }
                return move(String(value.dropFirst(prefix.count)), to: id)
            } isTargeted: { targeted = $0 }
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(look.palette.accent.opacity(targeted ? 0.7 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .sensoryFeedback(.selection, trigger: moved)
            .accessibilityHint("Hold and drag to reorder")
            .accessibilityAction(named: "Move up") { moveBy(-1) }
            .accessibilityAction(named: "Move down") { moveBy(1) }
    }

    private func move(_ source: String, to target: String) -> Bool {
        withAnimation(reduceMotion ? nil : look.animation) {
            let changed = model.playlistOrder.move(source, to: target, among: ids)
            if changed { moved.toggle() }
            return changed
        }
    }

    private func moveBy(_ offset: Int) {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        _ = move(id, to: ids[index + offset])
    }
}
