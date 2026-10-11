import SwiftUI

/// An album: cover, title, artist (tap to open them), year, Play and
/// Shuffle, then its songs by track number.
struct AlbumView: View {
    var album: CatalogItem
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var page: AlbumPage?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: look.gap * 1.4) {
                header
                if let page {
                    VStack(spacing: 0) {
                        ForEach(page.tracks) { track in
                            TrackRow(track: track, showsNumber: true, showsAddMenu: true) {
                                model.music?.play(.context(uri: album.uri, startAt: track.uri, position: track.position))
                            }
                        }
                    }
                } else if let error {
                    Text(error).font(look.font(15)).foregroundStyle(look.palette.muted)
                } else {
                    BarsLoader().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.horizontal, look.margin)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .pageBackground()
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderCover(artwork: headerArtwork)
            VStack(alignment: .leading, spacing: 6) {
                Text((page?.album ?? album).name)
                    .font(look.display(32))
                    .tracking(look.titleTracking)
                    .foregroundStyle(look.palette.text)
                HStack(spacing: 6) {
                    if let artist = page?.artists.first {
                        NavigationLink(value: artist) {
                            Text(page?.artists.map(\.name).joined(separator: ", ") ?? artist.name)
                                .font(look.font(15, .semibold))
                                .foregroundStyle(look.palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(details)
                        .font(look.font(14))
                        .foregroundStyle(look.palette.muted)
                }
            }
            ContextPlayControls(contextURI: album.uri, tracks: page?.tracks ?? [])
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private var headerArtwork: Artwork {
        let loaded = page?.album ?? album
        if let image = loaded.imageURL ?? album.imageURL { return .url(image) }
        if let seed = loaded.demoSeed ?? album.demoSeed { return .seed(seed) }
        // App Remote supplies album identity separately from its cached cover.
        if let playing = model.music?.nowPlaying, playing.albumItem?.uri == album.uri {
            return playing.artwork
        }
        return .none
    }

    private var details: String {
        guard let page else { return "" }
        let songs = page.tracks.count == 1 ? "1 song" : "\(page.tracks.count) songs"
        return ([page.year, songs].compactMap { $0 }).map { "· \($0)" }.joined(separator: " ")
    }

    private func load() async {
        guard page == nil, let music = model.music else { return }
        do {
            page = try await music.albumPage(album)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Routes a search or shelf item to its page.
struct CatalogPage: View {
    var item: CatalogItem
    @Environment(AppModel.self) private var model

    var body: some View {
        switch item.kind {
        case .artist: ArtistView(artist: item)
        case .album: AlbumView(album: item)
        case .playlist:
            PlaylistView(playlist: model.playlists.first { $0.id == item.id }
                ?? Playlist(id: item.id, name: item.name, ownerName: item.subtitle, isMine: false,
                            imageURL: item.imageURL, uri: item.uri, demoSeed: item.demoSeed))
        }
    }
}
