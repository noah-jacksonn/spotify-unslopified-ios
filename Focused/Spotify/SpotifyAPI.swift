import Foundation

/// Web API calls this app uses, written against the February 2026
/// development-mode API: playlist contents come from `/playlists/{id}/items`
/// (`items[].item`, formerly `tracks[].track`), only for playlists the user
/// owns or collaborates on; search returns at most 10 per type.
struct SpotifyAPI {
    let auth: SpotifyAuth

    enum APIError: LocalizedError {
        case http(status: Int, reason: String?, message: String?)

        var status: Int { if case .http(let status, _, _) = self { status } else { 0 } }

        /// Spotify's 404 for "nothing to play on" (reason NO_ACTIVE_DEVICE).
        /// Other 404s carry their own reason and shouldn't send the app to
        /// wake Spotify; a 404 with no reason is treated as no device, since
        /// the player endpoints don't always include one.
        var isNoActiveDevice: Bool {
            guard case let .http(404, reason, _) = self else { return false }
            return reason == nil || reason == "NO_ACTIVE_DEVICE"
        }

        var errorDescription: String? {
            switch self {
            case let .http(status, reason, message):
                if reason == "NO_ACTIVE_DEVICE" { return "Open Spotify on your phone once, then try again." }
                if status == 429 { return "Spotify is rate limiting requests. Try again in a minute." }
                if status == 403 { return message ?? "Spotify doesn't allow that for this account." }
                return message ?? "Spotify returned an error (\(status))."
            }
        }
    }

    // MARK: Library

    func myPlaylists() async throws -> [Playlist] {
        // Who "me" is matters only for marking ownership, so it loads
        // alongside the pages rather than before them.
        async let me: MeDTO = get("me")
        let pages: [PlaylistDTO?] = try await allPages(from: url("me/playlists", [.init(name: "limit", value: "50")]))
        let myID = try await me.id
        return pages.compactMap { $0?.model(myID: myID) }
    }

    /// Throws 403 for playlists owned by someone else: in development mode
    /// Spotify returns their metadata but not their contents.
    func tracks(inPlaylist id: String) async throws -> [Track] {
        let items: [PlaylistItemDTO?] = try await allPages(from: url("playlists/\(id)/items", [
            .init(name: "limit", value: "50"),
            .init(name: "additional_types", value: "track,episode"),
        ]))
        // Position = index among all entries, including local files and
        // unavailable (null) ones the app hides, as Spotify counts them.
        return items.enumerated().compactMap { index, item in
            item?.entry?.model.map { var track = $0; track.position = index; return track }
        }
    }

    /// Removes items (here, playlists) from the user's library. For a
    /// playlist the user owns this is Spotify's "Delete"; Spotify keeps it
    /// restorable from the account page for 90 days.
    func removeFromLibrary(_ uris: [String]) async throws {
        try await send("DELETE", "me/library", [.init(name: "uris", value: uris.joined(separator: ","))])
    }

    /// Appends to the end of a playlist the user owns or collaborates on.
    func addItems(_ uris: [String], toPlaylist id: String) async throws {
        try await send("POST", "playlists/\(id)/items", json: ["uris": uris])
    }

    /// Removes every occurrence of each URI (at most 100 per call).
    func removeItems(_ uris: [String], fromPlaylist id: String) async throws {
        try await send("DELETE", "playlists/\(id)/items", json: ["items": uris.map { ["uri": $0] }])
    }

    func search(_ query: String) async throws -> SearchResults {
        let response: SearchDTO = try await get("search", [
            .init(name: "q", value: query),
            .init(name: "type", value: "track,artist,album,playlist"),
            .init(name: "limit", value: "10"),
        ])
        return SearchResults(
            tracks: response.tracks?.items.compactMap { $0?.model } ?? [],
            artists: response.artists?.items.compactMap { $0?.model } ?? [],
            albums: response.albums?.items.compactMap { $0?.model } ?? [],
            playlists: response.playlists?.items.compactMap { $0?.catalogModel } ?? []
        )
    }

    // MARK: Artists and albums

    func artist(_ id: String) async throws -> CatalogItem {
        let artist: ArtistDTO = try await get("artists/\(id)")
        return artist.model
    }

    /// Up to 10 of the artist's songs, most popular first: a track search
    /// filtered to songs actually credited to this artist.
    func popularTracks(for artist: CatalogItem) async throws -> [Track] {
        let response: SearchDTO = try await get("search", [
            // Quotes would end the phrase early, so they're dropped.
            .init(name: "q", value: "artist:\"\(artist.name.replacingOccurrences(of: "\"", with: ""))\""),
            .init(name: "type", value: "track"),
            .init(name: "limit", value: "10"),
        ])
        let tracks = response.tracks?.items.compactMap { $0?.model } ?? []
        return tracks.filter { $0.artistIDs.contains(artist.id) }
    }

    /// `group` is "album" or "single"; newest first, duplicates (the same
    /// release in several markets) dropped. Development mode caps this
    /// endpoint at 10 per page (larger limits fail with "Invalid limit"),
    /// so it reads up to `pages` pages.
    func albums(ofArtist id: String, group: String, pages: Int = 2) async throws -> [CatalogItem] {
        let albums: [AlbumDTO?] = try await allPages(from: url("artists/\(id)/albums", [
            .init(name: "include_groups", value: group),
            .init(name: "market", value: "from_token"),
            .init(name: "limit", value: "10"),
        ]), maxPages: pages)
        var seen = Set<String>()
        return albums.compactMap { $0 }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .map(\.shelfModel)
    }

    func album(_ id: String) async throws -> AlbumPage {
        let album: AlbumFullDTO = try await get("albums/\(id)", [.init(name: "market", value: "from_token")])
        var entries = album.tracks.items
        if let next = album.tracks.next.flatMap(URL.init(string:)) {
            let rest: [TrackDTO?] = try await allPages(from: next)
            entries += rest
        }
        var tracks = entries.enumerated().compactMap { index, entry in
            entry?.model.map { var track = $0; track.position = index; return track }
        }
        // Album tracks come without album info; fill it from the album.
        let image = album.images?.bestURL
        tracks = tracks.map { var track = $0; track.imageURL = image; track.album = album.name; return track }
        let artists = (album.artists ?? []).compactMap { artist in artist.id.map { CatalogItem.spotifyArtist(id: $0, name: artist.name) } }
        return AlbumPage(
            album: CatalogItem(id: album.id, kind: .album, name: album.name,
                               subtitle: artists.map(\.name).joined(separator: ", "), imageURL: image, uri: album.uri),
            artists: artists,
            year: album.release_date.map { String($0.prefix(4)) },
            tracks: tracks
        )
    }

    // MARK: Player

    struct Device: Decodable {
        var id: String?
        var type: String
        var is_active: Bool?
    }

    func devices() async throws -> [Device] {
        struct Response: Decodable { var devices: [Device] }
        let response: Response = try await get("me/player/devices")
        return response.devices
    }

    /// Starts `contextURI` (at `offsetURI` if given) or a list of track URIs.
    /// Starts `contextURI` or `uris`. The start track is an exact `offsetPosition`
    /// when known, else `offsetURI`.
    func play(contextURI: String?, offsetURI: String? = nil, offsetPosition: Int? = nil,
              uris: [String]? = nil, positionMs: Int? = nil, deviceID: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let positionMs { body["position_ms"] = positionMs }
        if let contextURI { body["context_uri"] = contextURI }
        if let offsetPosition {
            body["offset"] = ["position": offsetPosition]
        } else if let offsetURI {
            body["offset"] = ["uri": offsetURI]
        }
        if let uris { body["uris"] = uris }
        let query = deviceID.map { [URLQueryItem(name: "device_id", value: $0)] } ?? []
        try await send("PUT", "me/player/play", query, json: body)
    }

    func resume() async throws { try await send("PUT", "me/player/play") }
    func pause() async throws { try await send("PUT", "me/player/pause") }
    func setShuffle(_ on: Bool) async throws {
        try await send("PUT", "me/player/shuffle", [.init(name: "state", value: on ? "true" : "false")])
    }
    func next() async throws { try await send("POST", "me/player/next") }
    func previous() async throws { try await send("POST", "me/player/previous") }
    func seek(toMs position: Int) async throws {
        try await send("PUT", "me/player/seek", [.init(name: "position_ms", value: String(position))])
    }

    /// nil when nothing is playing anywhere (Spotify answers 204).
    func playbackState() async throws -> NowPlaying? {
        let (data, response) = try await perform("GET", url("me/player", [.init(name: "additional_types", value: "track,episode")]))
        guard response.statusCode != 204, !data.isEmpty else { return nil }
        let state = try JSONDecoder().decode(PlaybackDTO.self, from: data)
        guard let item = state.item else { return nil }
        return NowPlaying(
            title: item.name,
            artist: item.artistLine,
            album: item.album?.name ?? item.show?.name ?? "",
            artwork: Artwork(url: item.imageURL, seed: nil),
            trackURI: item.uri,
            contextURI: state.context?.uri,
            isPaused: !state.is_playing,
            positionMs: state.progress_ms ?? 0,
            durationMs: item.duration_ms ?? 0,
            updatedAt: Date(),
            artistItem: item.artists?.first.flatMap { artist in artist.id.map { .spotifyArtist(id: $0, name: artist.name) } }
        )
    }

    // MARK: Transport

    /// Every item of a paged list, following `next` links (up to `maxPages`).
    private func allPages<Item: Decodable>(from first: URL, maxPages: Int = .max) async throws -> [Item] {
        var items: [Item] = []
        var next: URL? = first
        var read = 0
        while let page = next, read < maxPages {
            let response: PagingDTO<Item> = try await get(page)
            items += response.items
            next = response.next.flatMap(URL.init(string:))
            read += 1
        }
        return items
    }

    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: "https://api.spotify.com/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        try await get(url(path, query))
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, _) = try await perform("GET", url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, _ query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        _ = try await perform(method, url(path, query), body: body)
    }

    /// Retries once after refreshing on 401, and once after Retry-After on 429.
    private func perform(_ method: String, _ url: URL, body: Data? = nil, attempt: Int = 0) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method != "GET" {
            request.httpBody = Data()
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        if (200..<300).contains(http.statusCode) { return (data, http) }

        if attempt == 0, http.statusCode == 401 {
            try await auth.refresh()
            return try await perform(method, url, body: body, attempt: 1)
        }
        if attempt == 0, http.statusCode == 429,
           let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init), wait <= 5 {
            try await Task.sleep(for: .seconds(wait))
            return try await perform(method, url, body: body, attempt: 1)
        }
        struct ErrorBody: Decodable {
            struct Inner: Decodable { var message: String?; var reason: String? }
            var error: Inner?
        }
        let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        throw APIError.http(status: http.statusCode, reason: detail?.reason, message: detail?.message)
    }
}

// MARK: - Response shapes

/// nonisolated: decoded inside `myPlaylists`' concurrent `async let`.
private nonisolated struct MeDTO: Decodable { var id: String }

private struct PagingDTO<Item: Decodable>: Decodable {
    var items: [Item]
    var next: String?
}

private struct ImageDTO: Decodable {
    var url: String
    var width: Int?
}

private extension Array where Element == ImageDTO {
    /// Spotify lists the largest image first; prefer one around 640 px.
    var bestURL: URL? {
        let sorted = self.sorted { ($0.width ?? 0) > ($1.width ?? 0) }
        let pick = sorted.first { ($0.width ?? 640) <= 700 } ?? sorted.first
        return pick.flatMap { URL(string: $0.url) }
    }
}

private struct NamedDTO: Decodable {
    var id: String?
    var name: String
}

private struct PlaylistDTO: Decodable {
    struct Owner: Decodable { var id: String; var display_name: String? }
    struct Count: Decodable { var total: Int? }
    var id: String
    var name: String
    var uri: String
    var owner: Owner
    var collaborative: Bool?
    var images: [ImageDTO]?
    /// Renamed from `tracks` in February 2026; read both.
    var items: Count?
    var tracks: Count?

    func model(myID: String) -> Playlist {
        Playlist(
            id: id,
            name: name,
            ownerName: owner.display_name ?? owner.id,
            isMine: owner.id == myID || collaborative == true,
            imageURL: images?.bestURL,
            trackCount: items?.total ?? tracks?.total,
            uri: uri,
            isCollaborativeGuest: owner.id != myID && collaborative == true
        )
    }

    var catalogModel: CatalogItem {
        CatalogItem(id: id, kind: .playlist, name: name, subtitle: owner.display_name ?? "",
                    imageURL: images?.bestURL, uri: uri)
    }
}

private struct PlaylistItemDTO: Decodable {
    var item: TrackDTO?
    var track: TrackDTO?
    var entry: TrackDTO? { item ?? track }
}

/// Tracks and podcast episodes share this shape loosely.
private struct TrackDTO: Decodable {
    struct Album: Decodable { var name: String; var images: [ImageDTO]? }
    var id: String?
    var name: String
    var uri: String
    var duration_ms: Int?
    var artists: [NamedDTO]?
    var album: Album?
    var show: NamedDTO?
    var images: [ImageDTO]?
    var is_local: Bool?
    var track_number: Int?

    var artistLine: String { artists?.map(\.name).joined(separator: ", ") ?? show?.name ?? "" }
    var imageURL: URL? { album?.images?.bestURL ?? images?.bestURL }

    var model: Track? {
        guard is_local != true else { return nil }
        return Track(
            id: id ?? uri,
            name: name,
            artists: artistLine,
            album: album?.name ?? show?.name ?? "",
            imageURL: imageURL,
            durationMs: duration_ms ?? 0,
            uri: uri,
            artistIDs: artists?.compactMap(\.id) ?? [],
            number: track_number
        )
    }
}

private struct AlbumDTO: Decodable {
    var id: String
    var name: String
    var uri: String
    var artists: [NamedDTO]?
    var images: [ImageDTO]?
    var release_date: String?

    var year: String? { release_date.map { String($0.prefix(4)) } }

    /// For an artist's album shelf, where the year is the useful subtitle.
    var shelfModel: CatalogItem {
        CatalogItem(id: id, kind: .album, name: name, subtitle: year ?? "", imageURL: images?.bestURL, uri: uri)
    }

    var model: CatalogItem {
        CatalogItem(id: id, kind: .album, name: name,
                    subtitle: artists?.map(\.name).joined(separator: ", ") ?? "",
                    imageURL: images?.bestURL, uri: uri)
    }
}

private struct ArtistDTO: Decodable {
    var id: String
    var name: String
    var uri: String
    var images: [ImageDTO]?

    var model: CatalogItem {
        .spotifyArtist(id: id, name: name, imageURL: images?.bestURL)
    }
}

/// Spotify sometimes returns `null` entries inside search pages.
private struct SearchDTO: Decodable {
    var tracks: PagingDTO<TrackDTO?>?
    var artists: PagingDTO<ArtistDTO?>?
    var albums: PagingDTO<AlbumDTO?>?
    var playlists: PagingDTO<PlaylistDTO?>?
}

private struct AlbumFullDTO: Decodable {
    var id: String
    var name: String
    var uri: String
    var artists: [NamedDTO]?
    var images: [ImageDTO]?
    var release_date: String?
    var tracks: PagingDTO<TrackDTO?>
}

private struct PlaybackDTO: Decodable {
    struct Context: Decodable { var uri: String? }
    var is_playing: Bool
    var progress_ms: Int?
    var item: TrackDTO?
    var context: Context?
}
