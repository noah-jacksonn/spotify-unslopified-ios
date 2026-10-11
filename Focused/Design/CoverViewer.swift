import SwiftUI

/// A page's header cover. Tapping it zooms the art out to full screen on
/// black (Noah, 2026-10-03). Close by swiping down (the zoom transition's
/// own interactive dismiss), tapping anywhere, or the ✕; pinch to look
/// closer, and it springs back on release.
struct HeaderCover: View {
    var artwork: Artwork
    var size: CGFloat = 220
    @Environment(\.look) private var look
    @State private var showsFull = false
    @Namespace private var zoom

    var body: some View {
        let coverShape = RoundedRectangle(cornerRadius: look.artRadius(size), style: .continuous)
        Button { showsFull = true } label: {
            ArtworkView(artwork: artwork)
                .frame(width: size, height: size)
                .clipShape(coverShape)
        }
        .buttonStyle(PressScale())
        .matchedTransitionSource(id: "cover", in: zoom) { source in
            // The returning snapshot must use the same silhouette as the
            // cover, including while an interactive dismissal is cancelled.
            source.background(.clear).clipShape(coverShape)
        }
        .shadow(color: .black.opacity(look.isDark ? 0.45 : 0.18), radius: 26, y: 14)
        .accessibilityLabel("View cover")
        #if DEBUG
        // `run-on-iphone.sh --cover` (with --playlist): open it straight away.
        .task {
            if ProcessInfo.processInfo.arguments.contains("-openCover") {
                try? await Task.sleep(for: .milliseconds(600))
                showsFull = true
            }
        }
        #endif
        .fullScreenCover(isPresented: $showsFull) {
            CoverViewer(artwork: artwork)
                .navigationTransition(.zoom(sourceID: "cover", in: zoom))
        }
    }
}

private struct CoverViewer: View {
    var artwork: Artwork
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            ArtworkView(artwork: artwork)
                .aspectRatio(1, contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { scale = min(4, max(1, $0.magnification)) }
                        .onEnded { _ in withAnimation(.spring(duration: 0.35)) { scale = 1 } }
                )
                .onTapGesture { dismiss() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .padding(.trailing, 20)
            .padding(.top, 8)
            .accessibilityLabel("Close")
        }
        .statusBarHidden()
    }
}
