import Foundation

/// Sample music for trying the design without Spotify: invented playlists
/// and songs with generated covers, and a pretend player that advances in
/// real time. Nothing here touches the network.
@Observable
final class DemoMusic: MusicService {
    private(set) var nowPlaying: NowPlaying?
    var onNotice: ((Notice) -> Void)?

    private var playlists: [Playlist]
    private var tracksByPlaylist: [String: [Track]] = [:]
    /// Album id → artist name, so an album page credits the right artist.
    private var albumArtists: [String: String] = [:]
    private var queue: [Track] = []
    private var index = 0
    private var clock: Task<Void, Never>?

    init() {
        let names: [(String, String, Bool)] = [
            ("End of 2026", "You", true),
            ("Slow Mornings", "You", true),
            ("Deep Work", "You", true),
            ("Night Drive", "Mara", false),
            ("Rain on Tin", "You", true),
            ("Kitchen Dancing", "Theo", false),
            ("Low Light", "You", true),
            ("Field Recordings", "Ines", false),
            ("Sunday Reset", "You", true),
            ("Long Walks", "You", true),
            ("Paper Planes", "June", false),
            ("Afterglow", "You", true),
        ]
        playlists = names.enumerated().map { index, entry in
            Playlist(id: "demo-\(index)", name: entry.0, ownerName: entry.1, isMine: entry.2,
                     imageURL: nil, trackCount: 14 + (index * 7) % 23, uri: "demo:playlist:\(index)", demoSeed: index * 7 + 3)
        }
        for playlist in playlists {
            tracksByPlaylist[playlist.id] = Self.tracks(for: playlist)
        }
    }

    func loadPlaylists() async throws -> [Playlist] {
        var delay = Duration.milliseconds(250)
        #if DEBUG
        // `run-on-iphone.sh --loader`: hold the loader on screen to look at it.
        if ProcessInfo.processInfo.arguments.contains("-slowLoad") { delay = .seconds(6) }
        #endif
        try await Task.sleep(for: delay)
        return playlists
    }

    func tracks(in playlist: Playlist) async throws -> [Track] {
        try await Task.sleep(for: .milliseconds(200))
        return tracksByPlaylist[playlist.id] ?? []
    }

    func search(_ query: String) async throws -> SearchResults {
        try await Task.sleep(for: .milliseconds(150))
        let needle = query.lowercased()
        let tracks = tracksByPlaylist.values.joined().filter {
            $0.name.lowercased().contains(needle) || $0.artists.lowercased().contains(needle)
        }
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert($0.name).inserted }
        let artists = Set(unique.map(\.artists)).sorted().prefix(4).enumerated().map { index, name in
            Self.artist(named: name)
        }
        let lists = playlists.filter { $0.name.lowercased().contains(needle) }.map {
            CatalogItem(id: $0.id, kind: .playlist, name: $0.name, subtitle: $0.ownerName, uri: $0.uri, demoSeed: $0.demoSeed)
        }
        return SearchResults(tracks: Array(unique.prefix(10)), artists: Array(artists), playlists: lists)
    }

    func add(_ trackURIs: [String], to playlist: Playlist) async throws {
        try await Task.sleep(for: .milliseconds(200))
        let all = Array(tracksByPlaylist.values.joined())
        let added = trackURIs.compactMap { uri in all.first { $0.uri == uri } }
        tracksByPlaylist[playlist.id, default: []] += added
    }

    func deletePlaylist(_ playlist: Playlist) async throws {
        try await Task.sleep(for: .milliseconds(200))
        playlists.removeAll { $0.id == playlist.id }
    }

    func remove(_ trackURIs: [String], from playlist: Playlist) async throws {
        try await Task.sleep(for: .milliseconds(200))
        tracksByPlaylist[playlist.id]?.removeAll { trackURIs.contains($0.uri) }
    }

    func artistPage(_ artist: CatalogItem) async throws -> ArtistPage {
        try await Task.sleep(for: .milliseconds(200))
        var seen = Set<String>()
        let popular = tracksByPlaylist.values.joined()
            .filter { $0.artists == artist.name && seen.insert($0.name).inserted }
        let seed = artist.demoSeed ?? 1
        func releases(_ names: [String], offset: Int) -> [CatalogItem] {
            names.enumerated().map { index, name in
                CatalogItem(id: "album-\(artist.name)-\(name)", kind: .album, name: name, subtitle: String(2026 - index - offset),
                            uri: "demo:album:\(artist.name):\(name)", demoSeed: seed + index * 5 + offset)
            }
        }
        let page = ArtistPage(
            artist: artist,
            popular: Array(popular.prefix(10)),
            albums: releases(["Long Weather", "Rooms", "Paper Coast", "First Light"], offset: 0),
            singles: releases(["Orchard", "Static Bloom", "Linen"], offset: 11)
        )
        for release in page.albums + page.singles { albumArtists[release.id] = artist.name }
        return page
    }

    func albumPage(_ album: CatalogItem) async throws -> AlbumPage {
        try await Task.sleep(for: .milliseconds(200))
        let artistName = albumArtists[album.id] ?? (album.subtitle.isEmpty ? "Ostrander" : album.subtitle)
        let tracks = (0..<10).map { i in
            let n = (album.demoSeed ?? 0) * 13 + i * 7
            return Track(id: "\(album.id)-\(i)", name: "\(Self.words[n % Self.words.count]) \(Self.nouns[(n / 3) % Self.nouns.count])",
                         artists: artistName, album: album.name, imageURL: nil, durationMs: 150_000 + (n * 7919) % 120_000,
                         uri: "demo:track:\(album.id):\(i)", demoSeed: album.demoSeed, number: i + 1)
        }
        let artist = Self.artist(named: artistName)
        tracksByPlaylist[album.uri] = tracks
        return AlbumPage(album: album, artists: [artist], year: "2025", tracks: tracks)
    }

    func play(_ request: PlayRequest) {
        switch request {
        case let .context(uri, startAt, position):
            let playlist = playlists.first { $0.uri == uri }
            queue = playlist.flatMap { tracksByPlaylist[$0.id] } ?? tracksByPlaylist[uri]
                ?? Array(tracksByPlaylist.values.joined().shuffled().prefix(12))
            index = position.flatMap { queue.indices.contains($0) ? $0 : nil }
                ?? startAt.flatMap { start in queue.firstIndex { $0.uri == start } } ?? 0
            start(context: uri)
        case let .tracks(uris):
            let all = Array(tracksByPlaylist.values.joined())
            queue = uris.compactMap { uri in all.first { $0.uri == uri } }
            index = 0
            start(context: nil)
        }
    }

    func shuffle(_ request: PlayRequest) {
        play(request)
        queue.shuffle()
        if let current = nowPlaying?.trackURI, let at = queue.firstIndex(where: { $0.uri == current }) {
            queue.swapAt(0, at)
        }
        index = 0
    }

    func openSpotify() {}

    func togglePause() {
        guard var state = nowPlaying else {
            if let first = playlists.first { play(.context(uri: first.uri)) }
            return
        }
        state.rebase()
        state.isPaused.toggle()
        nowPlaying = state
    }

    func next() { step(1) }

    func previous() {
        if let state = nowPlaying, state.position(at: Date()) > 3000 { seek(toMs: 0) } else { step(-1) }
    }

    func seek(toMs position: Int) {
        nowPlaying?.positionMs = position
        nowPlaying?.updatedAt = Date()
    }

    func appBecameActive() {}
    func appWillResignActive() {}
    func handle(url: URL) {}

    private func step(_ delta: Int) {
        guard !queue.isEmpty else { return }
        index = (index + delta + queue.count) % queue.count
        start(context: nowPlaying?.contextURI)
    }

    private func start(context: String?) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        nowPlaying = NowPlaying(
            title: track.name, artist: track.artists, album: track.album,
            artwork: Artwork(url: nil, seed: track.demoSeed), trackURI: track.uri, contextURI: context,
            isPaused: false, positionMs: 0, durationMs: track.durationMs, updatedAt: Date(),
            artistItem: Self.artist(named: track.artists)
        )
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let state = self.nowPlaying else { return }
                if !state.isPaused, state.position(at: Date()) >= state.durationMs { self.step(1) }
            }
        }
    }

    /// One preview artist per name, with a stable generated photo.
    static func artist(named name: String) -> CatalogItem {
        let seed = name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 40
        return CatalogItem(id: "artist-\(name)", kind: .artist, name: name, subtitle: "Artist",
                           uri: "demo:artist:\(name)", demoSeed: seed)
    }

    private static let words = ["Glass", "Harbor", "Velvet", "Static", "Morning", "Copper", "Lantern", "Willow",
                                "Echo", "Saltwater", "Northern", "Paper", "Ember", "Satellite", "Linen", "Orchard",
                                "Quiet", "Silver", "Tidal", "Hollow", "Golden", "Window", "Signal", "Meadow"]
    private static let nouns = ["Hours", "Light", "Rooms", "Weather", "Lines", "Hearts", "Season", "Tape",
                                "Garden", "Machine", "Letters", "Tides", "Static", "Bloom", "Distance", "Coast"]
    private static let artists = ["Alder & Vale", "June Okafor", "The Quiet Hours", "Mira Sol", "Coastline",
                                  "Paper Kites Club", "Ostrander", "Lumen Choir", "Fennel", "Hollis Gray",
                                  "Night Office", "Sable"]

    private static func tracks(for playlist: Playlist) -> [Track] {
        let seed = playlist.demoSeed ?? 0
        return (0..<(playlist.trackCount ?? 12)).map { i in
            let n = seed * 31 + i * 17
            let name = "\(words[n % words.count]) \(nouns[(n / 3) % nouns.count])"
            let artist = artists[(n / 5) % artists.count]
            return Track(
                id: "\(playlist.id)-\(i)", name: name, artists: artist, album: "\(nouns[(n / 7) % nouns.count]) EP",
                imageURL: nil, durationMs: 150_000 + (n * 7919) % 120_000, uri: "demo:track:\(playlist.id):\(i)",
                demoSeed: (n / 2) % 40
            )
        }
    }
}
