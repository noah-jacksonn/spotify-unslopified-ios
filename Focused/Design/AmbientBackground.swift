import SwiftUI

/// The page behind everything: Ink with a soft glow from the top left and
/// a fainter one lower right. The glow takes the current song's color
/// (`look.glow`) and cross-fades slowly when the song changes.
struct AmbientBackground: View {
    @Environment(\.look) private var look

    var body: some View {
        ZStack {
            look.palette.background
            glow(look.glow)
                .id(look.glow)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 1.2), value: look.glow)
        .ignoresSafeArea()
    }

    private func glow(_ color: Color) -> some View {
        ZStack {
            RadialGradient(colors: [color.opacity(look.isDark ? 0.22 : 0.16), .clear],
                           center: .init(x: 0.2, y: 0), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [color.opacity(look.isDark ? 0.1 : 0.08), .clear],
                           center: .init(x: 1, y: 0.75), startRadius: 0, endRadius: 420)
        }
    }
}

extension View {
    /// The themed page background, behind a navigation page.
    func pageBackground() -> some View {
        containerBackground(for: .navigation) { AmbientBackground() }
    }
}
