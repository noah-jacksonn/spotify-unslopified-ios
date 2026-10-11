import Foundation

// Token source for the standalone decoder test; no Keychain or real requests.
final class SpotifyAuth {
    func accessToken() async throws -> String { "test-token" }
    func refresh() async throws {}
}

private final class SpotifyStub: URLProtocol {
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
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
        print("Spotify API checks passed: restricted playlist tracks, recording identity, source positions, local files, and queue decoding")
    }
}
