import Foundation

struct Playlist: Identifiable, Hashable {
    var id: String
    var name: String
    var ownerName: String
    /// Editable by the user: owned, or collaborative.
    var isMine: Bool
    /// Owned by the user, so removing it from the library deletes it.
    var isOwned: Bool { isMine && !isCollaborativeGuest }
    var imageURL: URL?
    var trackCount: Int?
    var uri: String
    /// Sample-music preview only: seeds the generated cover.
    var demoSeed: Int?
    /// Someone else's collaborative playlist the user can edit.
    var isCollaborativeGuest = false
}

struct Track: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var artists: String
    var album: String
    var imageURL: URL?
    var durationMs: Int
    var uri: String
    var demoSeed: Int?
    var artistIDs: [String] = []
    var artistNames: [String] = []
    var recordingID: String? = nil
    /// Position on its album; shown on album pages.
    var number: Int? = nil
    /// Index in the playlist or album it was loaded from (see
    /// `PlayRequest.context`).
    var position: Int? = nil
    var albumItem: CatalogItem? = nil
    /// Keep unavailable tracks visible in their source lists, but don't recommend them.
    var isPlayable: Bool? = nil
}

/// A search hit that isn't a track: an album, artist, or playlist.
struct CatalogItem: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case album, artist, playlist }
    var id: String
    var kind: Kind
    var name: String
    var subtitle: String
    var imageURL: URL?
    var uri: String
    var demoSeed: Int?
}

struct ArtistPage {
    var artist: CatalogItem
    /// Spotify removed "artist's top tracks" in February 2026; this is a
    /// search for the artist's songs, which ranks the popular ones first.
    var popular: [Track]
    var albums: [CatalogItem]
    var singles: [CatalogItem]
}

struct AlbumPage {
    var album: CatalogItem
    var artists: [CatalogItem]
    var year: String?
    var tracks: [Track]
}

struct PlaybackQueue {
    var current: Track?
    /// Keep duplicate occurrences in their reported order.
    var upcoming: [Track]
}

struct SearchResults {
    var tracks: [Track] = []
    var artists: [CatalogItem] = []
    var albums: [CatalogItem] = []
    var playlists: [CatalogItem] = []

    var isEmpty: Bool { tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty }
}

/// Artwork from whichever source has it: a Web API image URL, an image the
/// Spotify app handed over through App Remote (held in `ImageCache` under
/// its id), or a generated preview cover.
enum Artwork: Equatable {
    case none
    case url(URL)
    case image(id: String)
    case seed(Int)

    init(url: URL?, seed: Int?) {
        if let url { self = .url(url) } else if let seed { self = .seed(seed) } else { self = .none }
    }
}

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var artwork: Artwork
    var trackURI: String
    var contextURI: String?
    var isPaused: Bool
    var positionMs: Int
    var durationMs: Int
    /// When `positionMs` was true; progress is extrapolated from here.
    var updatedAt: Date
    var speed: Double = 1
    /// The (first) artist, so the full player can open their page.
    var artistItem: CatalogItem? = nil
    /// The recording's album, independent of its current playlist/context.
    var albumItem: CatalogItem? = nil

    /// Spoken content (a podcast episode or audiobook chapter), which unlike
    /// music has a playback speed.
    var isEpisode: Bool { Self.isSpoken(uri: trackURI) }

    /// Pins the extrapolated position to `date`, before changing pause or
    /// speed (which change how it extrapolates from here on).
    mutating func rebase(at date: Date = Date()) {
        positionMs = position(at: date)
        updatedAt = date
    }

    func position(at date: Date) -> Int {
        guard !isPaused else { return positionMs }
        let elapsed = Int(date.timeIntervalSince(updatedAt) * 1000 * speed)
        return min(durationMs, positionMs + max(0, elapsed))
    }

    func progress(at date: Date) -> Double {
        durationMs > 0 ? Double(position(at: date)) / Double(durationMs) : 0
    }
}

extension CatalogItem {
    static func spotifyAlbum(uri: String, name: String, artist: String, imageURL: URL? = nil) -> CatalogItem? {
        let prefix = "spotify:album:"
        guard uri.hasPrefix(prefix), uri.count > prefix.count else { return nil }
        return CatalogItem(id: String(uri.dropFirst(prefix.count)), kind: .album, name: name,
                           subtitle: artist, imageURL: imageURL, uri: uri)
    }

    /// A Spotify artist, from their id or `spotify:artist:` URI.
    static func spotifyArtist(id: String, name: String, imageURL: URL? = nil) -> CatalogItem {
        CatalogItem(id: id, kind: .artist, name: name, subtitle: "Artist", imageURL: imageURL, uri: "spotify:artist:\(id)")
    }

    static func spotifyArtist(uri: String, name: String) -> CatalogItem? {
        let prefix = "spotify:artist:"
        guard uri.hasPrefix(prefix) else { return nil }
        return spotifyArtist(id: String(uri.dropFirst(prefix.count)), name: name)
    }
}

extension NowPlaying {
    /// Spotify URI kinds that are spoken content, whatever the SDK flags say.
    static func isSpoken(uri: String) -> Bool {
        uri.hasPrefix("spotify:episode:") || uri.hasPrefix("spotify:chapter:")
    }
}
