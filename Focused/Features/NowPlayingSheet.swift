import SwiftUI

/// The full player: the cover bleeds off the top and fades into the page,
/// with large type beneath it.
struct NowPlayingSheet: View {
    var music: any MusicService
    @Environment(\.look) private var look

    var body: some View {
        ZStack {
            AmbientBackground()
            if let state = music.nowPlaying {
                poster(state)
                    .animation(look.animation, value: state.trackURI)
            } else {
                Text("Nothing playing").font(look.font(17)).foregroundStyle(look.palette.muted)
            }
        }
        .overlay(alignment: .top) {
            Capsule().fill(look.palette.text.opacity(0.25)).frame(width: 38, height: 5).padding(.top, 8)
        }
        .presentationDragIndicator(.hidden)
        .presentationBackground(look.palette.background)
    }

    private func poster(_ state: NowPlaying) -> some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                // Sized from the sheet's width: an aspect-ratio fit came up
                // short of the right edge once it ignored the top safe area.
                ArtworkView(artwork: state.artwork)
                    .frame(width: geo.size.width, height: geo.size.width)
                    .clipped()
                    // A mask, not a color overlay, so it fades into the
                    // glow behind it.
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .ignoresSafeArea(edges: .top)
                details(state)
            }
        }
    }

    private func details(_ state: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.title)
                        .font(look.display(46))
                        .tracking(look.titleTracking - 0.6)
                        .foregroundStyle(look.palette.text)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                    Text(state.artist)
                        .font(look.font(20, .medium))
                        .foregroundStyle(look.palette.accent)
                }
                Spacer(minLength: 0)
                AddToPlaylistMenu(track: state.asTrack, style: .quiet)
                    .padding(.top, 6)
            }
            .id(state.trackURI)
            .transition(.opacity)
            Spacer(minLength: 0)
            Scrubber(state: state, onSeek: music.seek)
            TransportControls(state: state, music: music)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 26)
        .padding(.top, -60)
        .padding(.bottom, 26)
    }
}

private extension NowPlaying {
    var asTrack: Track {
        Track(id: trackURI, name: title, artists: artist, album: album, imageURL: nil,
              durationMs: durationMs, uri: trackURI)
    }
}
