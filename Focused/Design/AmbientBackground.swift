import SwiftUI

/// The page behind everything: Ink with a soft accent glow from the top
/// left and a fainter one lower right.
struct AmbientBackground: View {
    @Environment(\.look) private var look

    var body: some View {
        ZStack {
            look.palette.background
            RadialGradient(colors: [look.palette.accent.opacity(look.isDark ? 0.22 : 0.16), .clear],
                           center: .init(x: 0.2, y: 0), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [look.palette.accent.opacity(look.isDark ? 0.1 : 0.08), .clear],
                           center: .init(x: 1, y: 0.75), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// The themed page background, behind a navigation page.
    func pageBackground() -> some View {
        containerBackground(for: .navigation) { AmbientBackground() }
    }
}
