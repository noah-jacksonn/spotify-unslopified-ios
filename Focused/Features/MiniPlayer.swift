import SwiftUI

/// What's playing: a full-width bar docked at the bottom of every page, with
/// progress along its top edge. Tap to open the full player.
struct MiniPlayer: View {
    var state: NowPlaying
    var music: any MusicService
    var open: () -> Void
    @Environment(\.look) private var look

    var body: some View {
        VStack(spacing: 0) {
            progress.frame(height: 2)
            HStack(spacing: 12) {
                ArtworkView(artwork: state.artwork)
                    .frame(width: 44, height: 44)
                    .artClip(look, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(look.font(15, .semibold)).foregroundStyle(look.palette.text).lineLimit(1)
                    Text(state.artist).font(look.font(13)).foregroundStyle(look.palette.muted).lineLimit(1)
                }
                .id(state.trackURI)
                .transition(.opacity)
                Spacer(minLength: 8)
                button(state.isPaused ? "play.fill" : "pause.fill", state.isPaused ? "Play" : "Pause", size: 22, width: 40) {
                    music.togglePause()
                }
                button("forward.fill", "Next", size: 18, width: 36) { music.next() }
            }
            .padding(.horizontal, look.margin)
            .padding(.vertical, 10)
        }
        .background(look.palette.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(look.palette.line).frame(height: look.hairline) }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .animation(look.animation, value: state.trackURI)
    }

    private func button(_ systemName: String, _ label: String, size: CGFloat, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(look.palette.text)
                .frame(width: width, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }

    private var progress: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: state.isPaused)) { timeline in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(look.palette.text.opacity(0.1))
                    Rectangle().fill(look.palette.accent)
                        .frame(width: geo.size.width * state.progress(at: timeline.date))
                }
            }
        }
    }
}
