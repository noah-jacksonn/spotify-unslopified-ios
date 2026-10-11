import SwiftUI

/// The full player: the cover bleeds off the top and fades into the page,
/// with large type beneath it.
struct NowPlayingSheet: View {
    var music: any MusicService
    @State private var showsFullLyrics = false
    @AppStorage("player.showsLiveLyrics") private var showsLiveLyrics = false
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    #if DEBUG
    @State private var openedDebugLyrics = false
    #endif
    @Environment(\.look) private var look

    private var lyrics: LyricsState { model.lyrics }

    /// A navigation stack of its own, so the artist name can open the
    /// artist page inside the player, with Back returning to the song.
    var body: some View {
        NavigationStack(path: $path) {
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
        .songAlbumNavigation(path: $path)
        .playerBar(isCovered: path.isEmpty, onOpen: { path = NavigationPath() })
        .presentationDragIndicator(.hidden)
        .presentationBackground(look.palette.background)
        .fullScreenCover(isPresented: $showsFullLyrics) {
            LyricsSheet(music: music, lyrics: lyrics)
                .environment(\.look, look)
        }
        .onAppear {
            #if DEBUG
            guard !openedDebugLyrics else { return }
            openedDebugLyrics = true
            if ProcessInfo.processInfo.arguments.contains("-openLyrics") { showsFullLyrics = true }
            if ProcessInfo.processInfo.arguments.contains("-liveLyrics") { showsLiveLyrics = true }
            if ProcessInfo.processInfo.arguments.contains("-openPlayerArtist"), let artist = music.nowPlaying?.artistItem {
                path.append(artist)
            }
            if ProcessInfo.processInfo.arguments.contains("-openPlayerAlbum"), var album = music.nowPlaying?.albumItem {
                // Exercise the metadata-only route supplied by App Remote.
                if ProcessInfo.processInfo.arguments.contains("-sparseAlbum") {
                    album.imageURL = nil
                    album.demoSeed = nil
                    album.name = ""
                }
                path.append(album)
            }
            #endif
        }
        .onChange(of: showsLiveLyrics) { _, enabled in
            if enabled { lyrics.loadCurrent(music.nowPlaying, retry: lyrics.error != nil) }
        }
        .onChange(of: music.nowPlaying, initial: true) { _, state in
            if showsLiveLyrics { lyrics.loadCurrent(state) }
        }
    }

    private func poster(_ state: NowPlaying) -> some View {
        GeometryReader { geo in
            let liveLyrics = showsLiveLyrics && !state.isEpisode
            VStack(alignment: .leading, spacing: 0) {
                if liveLyrics {
                    // Let the artwork absorb spare height, not a gap between
                    // lyrics and playback. Long titles simply get a shorter cover.
                    GeometryReader { art in
                        posterArtwork(state, size: art.size)
                    }
                } else {
                    posterArtwork(state, size: CGSize(width: geo.size.width,
                        height: min(geo.size.width, geo.size.height * 0.5)))
                }
                details(state)
                    .fixedSize(horizontal: false, vertical: liveLyrics)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    private func posterArtwork(_ state: NowPlaying, size: CGSize) -> some View {
        ArtworkView(artwork: state.artwork)
            .frame(width: size.width, height: max(0, size.height))
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea(edges: .top)
    }

    private func details(_ state: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    let title = Text(state.title)
                        .font(look.display(46))
                        .tracking(look.titleTracking - 0.6)
                        .foregroundStyle(look.palette.text)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                    if let album = state.albumItem, !state.isEpisode {
                        NavigationLink(value: album) { title.multilineTextAlignment(.leading) }
                            .buttonStyle(.plain)
                            .songContextMenu(state.asTrack)
                            .accessibilityHint("Opens the album")
                            .accessibilityIdentifier("player.albumLink")
                    } else {
                        title
                    }
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
            if showsLiveLyrics && !state.isEpisode {
                LiveLyrics(state: state, lyrics: lyrics)
            }
            if !showsLiveLyrics || state.isEpisode { Spacer(minLength: 0) }
            Scrubber(state: state, onSeek: music.seek)
            HStack {
                Spacer(minLength: 0)
                TransportControls(state: state, music: music)
                Spacer(minLength: 0)
            }
            HStack {
                if !state.isEpisode {
                    Button {
                        withAnimation(look.animation) { showsLiveLyrics.toggle() }
                    } label: {
                        Image(systemName: "text.quote")
                            .font(look.font(21, .medium))
                            .foregroundStyle(showsLiveLyrics ? look.palette.accent : look.palette.muted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel(showsLiveLyrics ? "Hide current lyric" : "Show current lyric")
                    .accessibilityHint("Touch and hold for full lyrics")
                    .accessibilityIdentifier("player.lyrics")
                    .contextMenu {
                        Button("Open full lyrics", systemImage: "arrow.up.left.and.arrow.down.right") { showsFullLyrics = true }
                        if lyrics.trackURI == state.trackURI && !lyrics.isLoading && (lyrics.error != nil || lyrics.document == nil) {
                            Button("Retry lyrics", systemImage: "arrow.clockwise") {
                                showsLiveLyrics = true
                                lyrics.loadCurrent(music.nowPlaying, retry: true)
                            }
                        }
                    }
                    .accessibilityAction(named: "Open full lyrics") { showsFullLyrics = true }
                }
                Spacer()
                QueueButton()
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, -60)
        .padding(.bottom, 26)
    }
}

private extension NowPlaying {
    var asTrack: Track {
        Track(id: trackURI, name: title, artists: artist, album: album, imageURL: nil,
              durationMs: durationMs, uri: trackURI, albumItem: albumItem)
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
