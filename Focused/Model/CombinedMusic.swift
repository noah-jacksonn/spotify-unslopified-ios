import Foundation

/// Keeps one player surface while routing imported audio to the device.
@Observable
final class CombinedMusic: MusicService {
    let remote: any MusicService
    let library: LocalLibrary
    let local = LocalPlayback()
    private(set) var usesLocalPlayback = false
    var onSourceChanged: (() -> Void)?
    var onNotice: ((Notice) -> Void)? {
        didSet {
            remote.onNotice = onNotice
            local.onNotice = onNotice
        }
    }
    var nowPlaying: NowPlaying? { usesLocalPlayback ? local.nowPlaying : remote.nowPlaying }
    var podcastSpeeds: [Double] { usesLocalPlayback ? [] : remote.podcastSpeeds }

    init(remote: any MusicService, library: LocalLibrary) {
        self.remote = remote
        self.library = library
    }

    func play(_ request: PlayRequest) { start(request, shuffled: false) }
    func shuffle(_ request: PlayRequest) { start(request, shuffled: true) }

    private func start(_ request: PlayRequest, shuffled: Bool) {
        guard request.startURI.hasPrefix("suno:") else {
            if usesLocalPlayback {
                local.stop()
                usesLocalPlayback = false
                onSourceChanged?()
            }
            remote.appBecameActive()
            if shuffled { remote.shuffle(request) } else { remote.play(request) }
            return
        }
        let songs: [LocalSong]
        var position = 0
        switch request {
        case .tracks(let uris): songs = uris.compactMap { library.song(uri: $0) }
        case let .context(_, startAt, offset):
            songs = library.songs
            position = offset ?? songs.firstIndex(where: { $0.uri == startAt }) ?? 0
        }
        guard !songs.isEmpty, shuffled || songs.indices.contains(position) else { return }
        do {
            try local.play(shuffled ? songs.shuffled() : songs, startAt: shuffled ? 0 : position)
            remote.suspendPlayback()
            let changed = !usesLocalPlayback
            usesLocalPlayback = true
            if changed { onSourceChanged?() }
        } catch { onNotice?(Notice(text: "Couldn't play this song. \(error.localizedDescription)")) }
    }

    func suspendPlayback() {
        local.stop()
        remote.suspendPlayback()
    }

    func endSession() {
        local.stop()
        remote.endSession()
    }

    func stopLocalPlayback() {
        local.stop()
        guard usesLocalPlayback else { return }
        usesLocalPlayback = false
        remote.appBecameActive()
        onSourceChanged?()
    }

    func togglePause() { usesLocalPlayback ? local.togglePause() : remote.togglePause() }
    func next() { usesLocalPlayback ? local.next() : remote.next() }
    func previous() { usesLocalPlayback ? local.previous() : remote.previous() }
    func seek(toMs position: Int) { usesLocalPlayback ? local.seek(toMs: position) : remote.seek(toMs: position) }
    func setPodcastSpeed(_ value: Double) { if !usesLocalPlayback { remote.setPodcastSpeed(value) } }
    func openSpotify() { remote.openSpotify() }
    func handle(url: URL) { remote.handle(url: url) }
    func appBecameActive() {
        library.reload()
        if usesLocalPlayback { local.refresh(songs: library.songs) } else { remote.appBecameActive() }
    }
    func appWillResignActive() { remote.appWillResignActive() }

    func playbackQueue() async throws -> PlaybackQueue {
        if usesLocalPlayback {
            return PlaybackQueue(current: local.queue.indices.contains(local.index) ? local.queue[local.index].track : nil,
                upcoming: local.queue.dropFirst(local.index + 1).map(\.track))
        }
        return try await remote.playbackQueue()
    }

    /// Local queue occurrences are authoritative, including repeated songs.
    /// Selecting one keeps the entries after it and the previous-song history.
    func playQueuedSong(at position: Int, uri: String) {
        guard usesLocalPlayback, local.queue.indices.contains(position),
              local.queue[position].uri == uri else { return }
        do { try local.play(local.queue, startAt: position) }
        catch { onNotice?(Notice(text: "Couldn't play this song. \(error.localizedDescription)")) }
    }

    func enqueue(_ track: Track) async throws {
        if let song = library.song(uri: track.uri) {
            guard usesLocalPlayback, local.nowPlaying != nil else { throw LocalPlaybackError.startSunoFirst }
            try local.enqueue(song)
        } else {
            guard !usesLocalPlayback else { throw LocalPlaybackError.startSpotifyFirst }
            try await remote.enqueue(track)
        }
    }

    func prepareForPlayback(_ tracks: [Track]) { remote.prepareForPlayback(tracks.filter { !$0.uri.hasPrefix("suno:") }) }
    func accountID() async throws -> String { try await remote.accountID() }
    func loadPlaylists() async throws -> [Playlist] { try await remote.loadPlaylists() }
    func tracks(in playlist: Playlist) async throws -> [Track] { try await remote.tracks(in: playlist) }
    func discoveryTracks(for artist: CatalogItem, rotation: Int) async throws -> [Track] { try await remote.discoveryTracks(for: artist, rotation: rotation) }
    func search(_ query: String) async throws -> SearchResults { try await remote.search(query) }
    func searchLyrics(_ query: String, page: Int) async throws -> LyricsSearchPage { try await remote.searchLyrics(query, page: page) }
    func artistPage(_ artist: CatalogItem) async throws -> ArtistPage { try await remote.artistPage(artist) }
    func albumPage(_ album: CatalogItem) async throws -> AlbumPage { try await remote.albumPage(album) }
    func add(_ trackURIs: [String], to playlist: Playlist) async throws {
        guard !trackURIs.contains(where: { $0.hasPrefix("suno:") }) else { throw LocalPlaybackError.spotifyImportRequired }
        try await remote.add(trackURIs, to: playlist)
    }
    func updateCover(_ jpeg: Data, for playlist: Playlist) async throws { try await remote.updateCover(jpeg, for: playlist) }
    func deletePlaylist(_ playlist: Playlist) async throws { try await remote.deletePlaylist(playlist) }
    func remove(_ trackURIs: [String], from playlist: Playlist) async throws { try await remote.remove(trackURIs, from: playlist) }
}

private enum LocalPlaybackError: LocalizedError {
    case startSunoFirst, startSpotifyFirst, spotifyImportRequired
    var errorDescription: String? {
        switch self {
        case .startSunoFirst: "Play an imported song first to add to its queue."
        case .startSpotifyFirst: "Play a Spotify song first to add to its queue."
        case .spotifyImportRequired: "Import this file in Spotify to add it to a Spotify playlist."
        }
    }
}
