import Foundation

struct Playlist: Identifiable, Hashable {
    var id: String
    var name: String
    var ownerName: String
    var isMine: Bool
    var imageURL: URL?
    var trackCount: Int?
    var uri: String
    /// Sample-music preview only: seeds the generated cover.
    var demoSeed: Int?
}

struct Track: Identifiable, Hashable {
    var id: String
    var name: String
    var artists: String
    var album: String
    var imageURL: URL?
    var durationMs: Int
    var uri: String
    var demoSeed: Int?
    var artistIDs: [String] = []
    /// Position on its album; shown on album pages.
    var number: Int? = nil
    /// Index in the playlist or album it was loaded from (see
    /// `PlayRequest.context`).
    var position: Int? = nil
}

/// A search hit that isn't a track: an album, artist, or playlist.
struct CatalogItem: Identifiable, Hashable {
    enum Kind { case album, artist, playlist }
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

    func position(at date: Date) -> Int {
        guard !isPaused else { return positionMs }
        let elapsed = Int(date.timeIntervalSince(updatedAt) * 1000)
        return min(durationMs, positionMs + max(0, elapsed))
    }

    func progress(at date: Date) -> Double {
        durationMs > 0 ? Double(position(at: date)) / Double(durationMs) : 0
    }
}
