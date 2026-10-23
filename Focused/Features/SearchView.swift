import SwiftUI

/// Search results, shown in place of Home's playlists while Home is in
/// search mode. Empty until you type: no recents, no browse categories.
struct SearchResultsView: View {
    var query: String
    var searchesLyrics: Bool
    @Binding var isLoading: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var results = SearchResults()
    @State private var lyricResults = LyricsSearchPage()
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var searchGeneration = 0
    @State private var resultsAreLyrics = false
    @State private var searchError: String?
    @State private var retry = 0
    /// The text `results` answers. Skeletons replace old results while typing;
    /// "Nothing found" waits for the current search, so it never flashes mid-word.
    @State private var resultsQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: look.gap * 1.6) {
            if !trimmed.isEmpty && isLoading {
                SearchResultsSkeleton(showsLyrics: searchesLyrics)
            } else if !trimmed.isEmpty && resultsAreLyrics == searchesLyrics {
                if searchesLyrics {
                    if !lyricMatches.isEmpty { lyricSongs }
                } else {
                    if !results.tracks.isEmpty { songs }
                    if !results.artists.isEmpty { ReleaseShelf(title: "Artists", releases: results.artists, size: 128, circle: true) }
                    if !results.albums.isEmpty { ReleaseShelf(title: "Albums", releases: results.albums, size: 128) }
                    if !results.playlists.isEmpty { playlists }
                }
                if resultsQuery == trimmed {
                    if let searchError {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(searchError).foregroundStyle(look.palette.muted)
                            Button("Try again") { retry += 1 }
                                .foregroundStyle(look.palette.accent)
                        }
                        .font(look.font(15))
                        .padding(.horizontal, look.margin)
                    } else if !isLoadingMore && results.isEmpty && lyricMatches.isEmpty {
                        Text(emptyMessage)
                            .font(look.font(15))
                            .foregroundStyle(look.palette.muted)
                            .padding(.horizontal, look.margin)
                    }
                    if searchesLyrics && searchError == nil { lyricsPagination }
                }
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: Request(query: trimmed, lyrics: searchesLyrics, retry: retry)) { await search() }
        .onDisappear { cancelLoadingMore() }
    }

    private var lyricMatches: [LyricsSearchMatch] { lyricResults.matches }

    private var emptyMessage: String {
        guard searchesLyrics else { return "Nothing found for “\(query)”" }
        return lyricResults.nextPage == nil
            ? "No songs found for those lyrics. Try a few different words."
            : "No matching songs yet. Try loading more."
    }

    @ViewBuilder private var lyricsPagination: some View {
        if isLoadingMore {
            SearchResultsSkeleton(showsLyrics: true, rowCount: 2, showsHeading: false)
        } else if lyricResults.nextPage != nil {
            VStack(alignment: .leading, spacing: 12) {
                if let loadMoreError {
                    Text(loadMoreError)
                        .font(look.font(14))
                        .foregroundStyle(look.palette.muted)
                }
                Button(action: loadMore) {
                    Text(loadMoreError == nil ? "Load more" : "Try again")
                        .font(look.font(15, .medium))
                        .foregroundStyle(look.palette.text)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(look.palette.raised, in: Capsule())
                }
                .buttonStyle(PressScale())
                .accessibilityIdentifier("search.loadMore")
            }
            .padding(.horizontal, look.margin)
        }
    }

    private struct Request: Equatable {
        var query: String
        var lyrics: Bool
        var retry: Int
    }

    private var lyricSongs: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(text: "Lyrics matches")
            ForEach(lyricMatches) { match in
                VStack(alignment: .leading, spacing: 2) {
                    TrackRow(track: match.track, showsAddMenu: true) {
                        model.music?.play(.tracks([match.track.uri]))
                    }
                    Button {
                        model.music?.play(.tracks([match.track.uri]))
                    } label: {
                        highlighted(match.excerpt)
                            .font(look.font(13))
                            .foregroundStyle(look.palette.muted)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 58)
                    .padding(.trailing, 44)
                    .accessibilityLabel("Play \(match.track.name). Lyrics: \(match.excerpt)")
                }
            }
        }
        .padding(.horizontal, look.margin)
    }

    /// Same treatment as Harmony's transcript search: muted surrounding words,
    /// with the matched phrase bolded in the full-strength foreground.
    private func highlighted(_ excerpt: String) -> Text {
        guard let range = excerpt.range(of: resultsQuery, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(excerpt)
        }
        let before = Text(String(excerpt[..<range.lowerBound]))
        let match = Text(String(excerpt[range])).font(look.font(13, .semibold)).foregroundStyle(look.palette.text)
        let after = Text(String(excerpt[range.upperBound...]))
        return Text("\(before)\(match)\(after)")
    }

    private var songs: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Songs")
            ForEach(results.tracks) { track in
                TrackRow(track: track, showsAddMenu: true) {
                    model.music?.play(.tracks([track.uri]))
                }
            }
        }
        .padding(.horizontal, look.margin)
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Playlists")
            ForEach(results.playlists) { item in
                // CatalogPage turns it into a Playlist, keeping library info.
                NavigationLink(value: item) {
                    HStack(spacing: 12) {
                        ArtworkView(artwork: Artwork(url: item.imageURL, seed: item.demoSeed))
                            .frame(width: 52, height: 52)
                            .artClip(look, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(look.font(16, .medium)).foregroundStyle(look.palette.text).lineLimit(1)
                            Text(item.subtitle).font(look.font(13)).foregroundStyle(look.palette.muted).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let playlist = model.playlists.first(where: { $0.uri == item.uri && $0.isMine }) {
                        Button("Add to queue", systemImage: "text.badge.plus") { model.enqueue(playlist) }
                    }
                }
            }
        }
        .padding(.horizontal, look.margin)
    }

    private var trimmed: String { query.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private func cancelLoadingMore() {
        searchGeneration += 1
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoadingMore = false
        loadMoreError = nil
    }

    private func loadMore() {
        guard !isLoading, !isLoadingMore, searchesLyrics, resultsQuery == trimmed,
              let page = lyricResults.nextPage, let music = model.music else { return }
        let generation = searchGeneration
        let text = resultsQuery
        isLoadingMore = true
        loadMoreError = nil
        loadMoreTask = Task {
            defer {
                if searchGeneration == generation {
                    isLoadingMore = false
                    loadMoreTask = nil
                }
            }
            do {
                let found = try await music.searchLyrics(text, page: page)
                guard !Task.isCancelled, searchGeneration == generation else { return }
                withAnimation(look.animation) { lyricResults.append(found) }
            } catch {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                // Keep both the visible songs and the failed page's retry cursor.
                loadMoreError = error.localizedDescription
            }
        }
    }

    private func search() async {
        guard !Task.isCancelled else { return }
        cancelLoadingMore()
        let text = trimmed
        searchError = nil
        guard !text.isEmpty, let music = model.music else {
            results = SearchResults()
            lyricResults = LyricsSearchPage()
            resultsQuery = ""
            isLoading = false
            return
        }
        if resultsAreLyrics != searchesLyrics {
            results = SearchResults()
            lyricResults = LyricsSearchPage()
            resultsQuery = ""
        }
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            try await Task.sleep(for: .milliseconds(searchesLyrics ? 500 : 320))
            let found: SearchResults
            let lyrics: LyricsSearchPage
            if searchesLyrics {
                lyrics = try await music.searchLyrics(text, page: 1)
                found = SearchResults()
            } else {
                found = try await music.search(text)
                lyrics = LyricsSearchPage()
            }
            guard !Task.isCancelled else { return }
            withAnimation(look.animation) {
                results = found
                lyricResults = lyrics
                resultsQuery = text
                resultsAreLyrics = searchesLyrics
            }
        } catch {
            guard !Task.isCancelled else { return }
            results = SearchResults()
            lyricResults = LyricsSearchPage()
            resultsQuery = text
            resultsAreLyrics = searchesLyrics
            searchError = error.localizedDescription
        }
    }
}

/// The search pill: transparent with a quiet outline, like the extension's.
/// Its outline shares a matched-geometry id with Home's search button, so
/// the button stretches into the field.
struct SearchField: View {
    @Binding var query: String
    @Binding var searchesLyrics: Bool
    var isLoading: Bool
    var focused: FocusState<Bool>.Binding
    var namespace: Namespace.ID
    @Environment(\.look) private var look

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(look.palette.muted)
                    .matchedGeometryEffect(id: "search.icon", in: namespace)
                    .opacity(isLoading ? 0 : 1)
                if isLoading { BarsLoader(size: 14, delay: .zero) }
            }
            .frame(width: 18)
            TextField(searchesLyrics ? "Words from a song" : "Songs, artists, albums", text: $query)
                .font(look.font(17))
                .foregroundStyle(look.palette.text)
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            HStack(spacing: 0) {
                Button { searchesLyrics.toggle() } label: {
                    Image(systemName: "text.quote")
                        .font(look.font(17, .medium))
                        .foregroundStyle(searchesLyrics ? look.palette.accent : look.palette.muted)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search by lyrics")
                .accessibilityValue(searchesLyrics ? "On" : "Off")
                .accessibilityAddTraits(searchesLyrics ? .isSelected : [])
                .accessibilityIdentifier("search.lyrics")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(look.palette.muted)
                            .frame(width: 28, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background {
            Capsule()
                .fill(look.palette.surface.opacity(0.5))
                .overlay(Capsule().stroke(look.palette.line, lineWidth: look.hairline))
                .matchedGeometryEffect(id: "search.shape", in: namespace)
        }
    }
}

/// Song options: queue it or add it to an editable playlist. Playlist adds
/// briefly show a checkmark; queue confirmations come from AppModel.
struct AddToPlaylistMenu: View {
    enum Style { case compact, quiet }

    var track: Track
    var style: Style = .compact
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var justAdded = false

    var body: some View {
        Menu {
            Button("Add to queue", systemImage: "text.badge.plus") { model.enqueue([track]) }
            SeeAlbumButton(track: track)
            Menu("Add to playlist", systemImage: "plus") {
                ForEach(model.playlists.filter(\.isMine)) { playlist in
                    Button(playlist.name) {
                        Task { await add(to: playlist) }
                    }
                }
            }
        } label: {
            switch style {
            case .compact:
                Image(systemName: justAdded ? "checkmark" : "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(look.palette.text)
                    .frame(width: 26, height: 26)
                    .background(look.palette.raised, in: Circle())
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            case .quiet:
                // Matches the playlist page's Home toggle beside its title.
                Image(systemName: justAdded ? "checkmark.circle.fill" : "ellipsis.circle")
                    .font(.system(size: 26, weight: .regular))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(look.palette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .sensoryFeedback(.success, trigger: justAdded) { _, new in new }
        .accessibilityLabel(justAdded ? "Added" : "Options for \(track.name)")
    }

    private func add(to playlist: Playlist) async {
        guard await model.add(track, to: playlist) else { return }
        withAnimation(look.animation) { justAdded = true }
        try? await Task.sleep(for: .seconds(2))
        withAnimation(look.animation) { justAdded = false }
    }
}

/// Each stack supplies the album action so song menus push within their
/// current surface, including sheets, and Back returns to the same place.
private struct OpenSongAlbumKey: EnvironmentKey {
    static let defaultValue: ((CatalogItem) -> Void)? = nil
}

extension EnvironmentValues {
    var openSongAlbum: ((CatalogItem) -> Void)? {
        get { self[OpenSongAlbumKey.self] }
        set { self[OpenSongAlbumKey.self] = newValue }
    }
}

struct SeeAlbumButton: View {
    var track: Track
    @Environment(\.openSongAlbum) private var openAlbum

    var body: some View {
        if let album = track.albumItem, let openAlbum {
            Button("See Album", systemImage: "square.stack") { openAlbum(album) }
        }
    }
}

private struct SongContextMenu: ViewModifier {
    var track: Track
    var play: (() -> Void)?
    var remove: (() -> Void)?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Add to queue", systemImage: "text.badge.plus") { model.enqueue([track]) }
            if let play { Button("Play", systemImage: "play.fill", action: play) }
            SeeAlbumButton(track: track)
            if let remove {
                Button("Remove from playlist", systemImage: "trash", role: .destructive, action: remove)
            }
        }
    }
}

extension View {
    func songContextMenu(_ track: Track, play: (() -> Void)? = nil, remove: (() -> Void)? = nil) -> some View {
        modifier(SongContextMenu(track: track, play: play, remove: remove))
    }
}
