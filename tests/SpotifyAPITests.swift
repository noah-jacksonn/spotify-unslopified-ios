import Foundation

// Token source for the standalone decoder test; no Keychain or real requests.
final class SpotifyAuth {
    func accessToken() async throws -> String { "test-token" }
    func refresh() async throws {}
}

private final class SpotifyStub: URLProtocol {
    static var body = Data()
    static var statuses: [Int] = []
    static var lastURL: URL?
    static var requests: [(method: String?, path: String, contentType: String?, body: Data)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.requests.append((request.httpMethod, request.url!.path,
                              request.value(forHTTPHeaderField: "Content-Type"), data))
        let status = Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Retry-After": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct SpotifyAPITests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpotifyStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = SpotifyAPI(auth: SpotifyAuth(), session: session)
        let restricted: [String: Any] = [
            "id": "restricted", "uri": "spotify:track:restricted", "name": "Source song",
            "is_playable": false, "restrictions": ["reason": "market"],
            "artists": [["id": "artist", "name": "Artist"]],
            "external_ids": ["isrc": "RECORDING"],
        ]
        SpotifyStub.body = try JSONSerialization.data(withJSONObject: ["tracks": ["items": [restricted, NSNull()]]])
        let lyricTracks = try await api.searchTracks("track:\"Source song\" artist:\"Artist\"")
        precondition(lyricTracks.count == 1 && lyricTracks[0].artistNames == ["Artist"])
        let searchQuery = URLComponents(url: SpotifyStub.lastURL!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(searchQuery.first { $0.name == "type" }?.value == "track")
        precondition(searchQuery.first { $0.name == "limit" }?.value == "10")
        precondition(searchQuery.first { $0.name == "q" }?.value == "track:\"Source song\" artist:\"Artist\"")
        var local = restricted
        local["is_local"] = true
        SpotifyStub.body = try JSONSerialization.data(withJSONObject: ["items": [["item": local], ["item": restricted]]])
        let tracks = try await api.tracks(inPlaylist: "source")
        precondition(tracks.count == 1 && tracks[0].isPlayable == false)
        precondition(tracks[0].position == 1 && tracks[0].recordingID == "RECORDING",
                     "Preserve restricted source metadata and Spotify positions while hiding local files")
        SpotifyStub.body = try JSONSerialization.data(withJSONObject: ["currently_playing": restricted, "queue": [restricted]])
        let queue = try await api.playbackQueue()
        precondition(queue.current?.uri == tracks[0].uri && queue.upcoming.count == 1,
                     "Restricted items must not vanish from the queue")
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        for status in [202, 401, 429] {
            SpotifyStub.body = Data()
            SpotifyStub.requests = []
            SpotifyStub.statuses = status == 202 ? [202] : [status, 202]
            try await api.uploadPlaylistCover(jpeg, playlistID: "owned-playlist")
            precondition(SpotifyStub.requests.count == (status == 202 ? 1 : 2))
            for request in SpotifyStub.requests {
                precondition(request.method == "PUT" && request.path == "/v1/playlists/owned-playlist/images")
                precondition(request.contentType == "image/jpeg", "Retries must preserve the JPEG content type")
                precondition(request.body == jpeg.base64EncodedData(), "Body must be raw base64, not JSON")
            }
        }
        SpotifyStub.statuses = [403]
        do {
            try await api.uploadPlaylistCover(jpeg, playlistID: "forbidden")
            preconditionFailure("Forbidden cover updates must fail")
        } catch let error as SpotifyAPI.APIError { precondition(error.status == 403) }
        let requestCount = SpotifyStub.requests.count
        for invalid in [Data(), Data(repeating: 0, count: 192_001)] {
            do {
                try await api.uploadPlaylistCover(invalid, playlistID: "owned-playlist")
                preconditionFailure("Invalid payload must be rejected before upload")
            } catch let error as SpotifyAPI.APIError { precondition(error.status == 400) }
        }
        precondition(SpotifyStub.requests.count == requestCount)
        print("Playlist cover upload checks passed: raw base64, JPEG content type, 202 success, 401/429 retries, forbidden response, payload limits")
        print("Spotify API checks passed: restricted playlist tracks, recording identity, source positions, local files, and queue decoding")
    }
}
