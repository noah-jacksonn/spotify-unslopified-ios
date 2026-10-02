import Foundation

enum PlayRequest: Equatable {
    /// A playlist, album or artist, optionally starting at one of its
    /// tracks. Give the track's `position` when known: Spotify matches a
    /// position exactly, while a URI can miss (relinked or local tracks)
    /// and silently start somewhere else.
    case context(uri: String, startAt: String? = nil, position: Int? = nil)
    case tracks([String])

    /// What App Remote or a wake can start: the context, or the first track.
    var startURI: String {
        switch self {
        case let .context(uri, _, _): uri
        case let .tracks(uris): uris.first ?? ""
        }
    }

    /// The one URI App Remote can play directly: a context from its start,
    /// or a single track.
    var singleURI: String? {
        switch self {
        case let .context(uri, startAt, position): startAt == nil && position == nil ? uri : nil
        case let .tracks(uris): uris.count == 1 ? uris[0] : nil
        }
    }
}

/// A short message for the notice capsule. `opensSpotify` makes it a tap
/// target that wakes the Spotify app (for "no active device" problems).
struct Notice: Equatable {
    var text: String
    var opensSpotify = false
}

/// What the screens need from a music source. `SpotifyMusic` is the real
/// thing; `DemoMusic` is the sample-music preview used for design testing.
protocol MusicService: AnyObject {
    var nowPlaying: NowPlaying? { get }
    /// Set by AppModel; the service reports user-facing problems here.
    var onNotice: ((Notice) -> Void)? { get set }

    func loadPlaylists() async throws -> [Playlist]
    func tracks(in playlist: Playlist) async throws -> [Track]
    func search(_ query: String) async throws -> SearchResults
    func artistPage(_ artist: CatalogItem) async throws -> ArtistPage
    func albumPage(_ album: CatalogItem) async throws -> AlbumPage
    func add(_ trackURIs: [String], to playlist: Playlist) async throws
    /// Removes every copy of each song.
    func remove(_ trackURIs: [String], from playlist: Playlist) async throws

    func play(_ request: PlayRequest)
    /// Plays the context from a random song with shuffle turned on.
    func shuffle(_ request: PlayRequest)
    /// Brings the Spotify app up to resume playback, then returns here.
    func openSpotify()
    func togglePause()
    func next()
    func previous()
    func seek(toMs position: Int)

    func appBecameActive()
    func appWillResignActive()
    /// Handles a callback URL; ignores ones that aren't for this service.
    func handle(url: URL)
}
