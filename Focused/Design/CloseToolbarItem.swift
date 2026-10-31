import SwiftUI

struct CloseToolbarItem: ToolbarContent {
    var isEnabled = true
    var accessibilityLabel = "Close"
    var action: () -> Void
    @Environment(\.look) private var look

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(look.font(16, .medium))
                    .foregroundStyle(look.palette.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(accessibilityLabel)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}
