import SwiftUI

/// The full player: the cover bleeds off the top and fades into the page,
/// with large type beneath it.
struct NowPlayingSheet: View {
    var music: any MusicService
    @Environment(\.look) private var look

    /// A navigation stack of its own, so the artist name can open the
    /// artist page inside the player, with Back returning to the song.
    var body: some View {
        NavigationStack {
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
            .toolbar(.hidden, for: .navigationBar)
            .appDestinations()
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
                    let artistName = Text(state.artist)
                        .font(look.font(20, .medium))
                        .foregroundStyle(look.palette.accent)
                    if let artist = state.artistItem {
                        NavigationLink(value: artist) { artistName.multilineTextAlignment(.leading) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the artist")
                    } else {
                        artistName
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    // Podcasts only: on 2026-10-03 the phone showed Spotify
                    // accepts a speed for songs but keeps playing at 1×.
                    if state.isEpisode, !music.podcastSpeeds.isEmpty {
                        SpeedMenu(speeds: music.podcastSpeeds, current: state.speed, choose: music.setPodcastSpeed)
                    }
                    AddToPlaylistMenu(track: state.asTrack, style: .quiet)
                }
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

/// The podcast speed as quiet text ("1×") beside the add button; tapping
/// lists the speeds (Noah, 2026-10-03: a row of chips was too noisy).
private struct SpeedMenu: View {
    var speeds: [Double]
    var current: Double
    var choose: (Double) -> Void
    @Environment(\.look) private var look

    var body: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { closest }, set: choose)) {
                ForEach(speeds, id: \.self) { Text(label($0)).tag($0) }
            }
        } label: {
            Text(label(current))
                .font(look.font(16, .medium).monospacedDigit())
                .foregroundStyle(look.palette.muted)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .sensoryFeedback(.selection, trigger: current)
        .accessibilityLabel("Playback speed \(label(current))")
    }

    /// The listed speed nearest the reported one, so the menu marks it.
    private var closest: Double {
        speeds.min { abs($0 - current) < abs($1 - current) } ?? current
    }

    private func label(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
