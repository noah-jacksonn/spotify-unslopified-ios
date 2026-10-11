import Foundation

private final class LyricsStub: URLProtocol {
    static var status = 200
    static var body = Data()
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct LyricsTests {
    static func record(title: String = "Open Window", artist: String = "Example Artist", duration: Double = 120,
                       instrumental: Bool = false, plain: String? = nil, synced: String? = nil) throws -> Data {
        var value: [String: Any] = ["id": 1, "trackName": title, "artistName": artist,
                                    "duration": duration, "instrumental": instrumental]
        if let plain { value["plainLyrics"] = plain }
        if let synced { value["syncedLyrics"] = synced }
        return try JSONSerialization.data(withJSONObject: value)
    }

    @MainActor static func main() async throws {
        let parsed = LRCParser.parse("""
        [ar:Example Artist]
        [offset:+250]
        [00:12.50][00:02.5]Open window
        [00:02.500]Open window
        [00:05.025]
        [01:03]Morning light
        [00:99.00]Invalid
        Untimed words
        """)
        precondition(parsed.map(\.time) == [2.75, 5.275, 12.75, 63.25])
        precondition(parsed.map(\.text) == ["Open window", "", "Open window", "Morning light"])
        precondition(parsed.map(\.id) == [0, 1, 2, 3])
        precondition(LRCParser.parse("[offset:-2000]\n[00:01]Early")[0].time == 0)
        precondition(LRCParser.parse("[00:01:125]Decimal")[0].time == 1.125)
        let doc = LyricsDocument(lines: parsed, instrumental: false, sourceURL: nil)
        precondition(doc.activeLine(at: 0) == nil)
        precondition(doc.activeLine(at: 2.75) == 0)
        precondition(doc.activeLine(at: 10) == 1, "An instrumental gap must stop highlighting the previous words")
        precondition(doc.activeLine(at: 100) == 3)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = LyricsService(session: session)
        var state = NowPlaying(title: "Open Window", artist: "Example Artist, Guest", album: "Daylight", artwork: .none,
                               trackURI: "spotify:track:one", isPaused: false, positionMs: 0,
                               durationMs: 120_000, updatedAt: Date(),
                               artistItem: .spotifyArtist(id: "example", name: "Example Artist"))
        LyricsStub.body = try record(synced: "[00:00]First light\n[00:05]Open window\n[02:01]Past the end")
        let synced = try await service.lyrics(for: state)
        precondition(synced?.lines.count == 2, "Drop timing past the track duration")
        precondition(synced?.sourceURL?.host == "lrclib.net")
        let request = LyricsStub.requests.last!
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        precondition(query["artist_name"] == "Example Artist" && query["duration"] == "120.0")
        precondition(query["track_name"] == state.title && query["album_name"] == state.album)
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "User-Agent")?.contains("SpotifyUnslopified") == true)
        let requestCount = LyricsStub.requests.count
        _ = try await service.lyrics(for: state)
        precondition(LyricsStub.requests.count == requestCount, "Cache successful lookups")

        var serial = 0
        func next() { serial += 1; state.trackURI = "spotify:track:test\(serial)" }
        next()
        LyricsStub.body = try record(plain: "First light\nOpen window")
        let plain = try await service.lyrics(for: state)
        precondition(plain?.lines.isEmpty == true && plain?.plainText?.contains("First light") == true)
        next()
        LyricsStub.body = try record(instrumental: true)
        let instrumental = try await service.lyrics(for: state)
        precondition(instrumental?.instrumental == true)
        next()
        LyricsStub.body = try record(title: "Open Window (Live)", synced: "[00:00]Wrong version")
        let wrongTitle = try await service.lyrics(for: state)
        precondition(wrongTitle == nil)
        next()
        LyricsStub.body = try record(artist: "Another Artist", synced: "[00:00]Wrong artist")
        let wrongArtist = try await service.lyrics(for: state)
        precondition(wrongArtist == nil)
        next()
        LyricsStub.body = try record(duration: 123, synced: "[00:00]Wrong timing")
        let wrongDuration = try await service.lyrics(for: state)
        precondition(wrongDuration == nil)
        next()
        LyricsStub.status = 404
        let missing = try await service.lyrics(for: state)
        precondition(missing == nil)
        LyricsStub.status = 200
        LyricsStub.body = try record(synced: "[00:00]Now available")
        let retried = try await service.lyrics(for: state)
        precondition(retried != nil, "Missing lyrics must remain retryable")
        next()
        LyricsStub.status = 429
        do { _ = try await service.lyrics(for: state); fatalError("Expected busy response") }
        catch LyricsService.Failure.response(429) {}
        next()
        LyricsStub.status = 200
        LyricsStub.body = Data("not json".utf8)
        do { _ = try await service.lyrics(for: state); fatalError("Expected malformed response") }
        catch LyricsService.Failure.unavailable {}
        next()
        state.trackURI = "spotify:episode:spoken"
        let beforePodcast = LyricsStub.requests.count
        let podcast = try await service.lyrics(for: state)
        precondition(podcast == nil && LyricsStub.requests.count == beforePodcast)
        // Both presentations share one request and track changes cannot publish stale words.
        LyricsStub.status = 200
        LyricsStub.body = try record(synced: "[00:00]First light\n[00:05]Open window\n[00:10]")
        state.trackURI = "spotify:track:shared-lyrics"
        let shared = LyricsState(service: service)
        let beforeShared = LyricsStub.requests.count
        shared.load(for: state)
        shared.load(for: state)
        try await waitForLyrics(shared)
        precondition(LyricsStub.requests.count == beforeShared + 1, "Inline and full lyrics share one lookup")
        precondition(shared.document?.currentText(at: 6) == "Open window")
        precondition(shared.document?.currentText(at: 10) == nil, "Clear words during a timed gap")
        precondition(shared.document?.currentText(at: -1) == nil)
        shared.load(for: state)
        precondition(LyricsStub.requests.count == beforeShared + 1)

        let cachedState = state
        // Closing/reopening the player keeps the app-owned state; returning
        // after another song must also restore from cache without a spinner.
        shared.load(for: nil)
        shared.load(for: cachedState)
        precondition(!shared.isLoading && shared.document?.currentText(at: 6) == "Open window")
        precondition(LyricsStub.requests.count == beforeShared + 1, "Reopening cached lyrics must not fetch again")
        let anotherPresentation = LyricsState(service: service)
        anotherPresentation.load(for: cachedState)
        precondition(!anotherPresentation.isLoading && anotherPresentation.document != nil,
                     "Cached lyrics must be available synchronously to a new presentation")
        precondition(LyricsStub.requests.count == beforeShared + 1)

        var otherSong = state
        otherSong.trackURI = "spotify:track:another-cached-song"
        shared.load(for: otherSong)
        try await waitForLyrics(shared)
        let afterOtherSong = LyricsStub.requests.count
        shared.load(for: cachedState)
        precondition(!shared.isLoading && shared.trackURI == cachedState.trackURI)
        precondition(shared.document?.currentText(at: 6) == "Open window")
        precondition(LyricsStub.requests.count == afterOtherSong, "A → B → A must reuse A's lyrics")

        var episode = cachedState
        episode.trackURI = "spotify:episode:spoken"
        shared.load(for: episode)
        precondition(!shared.isLoading && shared.document == nil && shared.trackURI == nil,
                     "Switching to a podcast must clear lyrics without starting a lookup")
        shared.load(for: cachedState)
        precondition(!shared.isLoading && shared.document != nil)
        precondition(LyricsStub.requests.count == afterOtherSong, "Returning from a podcast must reuse cached lyrics")

        state.trackURI = "spotify:track:old-pending"
        shared.load(for: state)
        state.trackURI = "demo:new-song"
        let sample = LyricsDocument(lines: LRCParser.parse("[00:00]New song"), instrumental: false, sourceURL: nil)
        shared.load(for: state, sample: sample)
        try await Task.sleep(for: .milliseconds(30))
        precondition(shared.document?.currentText(at: 1) == "New song" && shared.trackURI == state.trackURI)
        shared.load(for: nil)
        precondition(shared.document == nil && shared.trackURI == nil && !shared.isLoading)

        state.trackURI = "spotify:track:retry-shared"
        LyricsStub.status = 503
        shared.load(for: state)
        try await waitForLyrics(shared)
        precondition(shared.error != nil)
        LyricsStub.status = 200
        shared.load(for: state, retry: true)
        try await waitForLyrics(shared)
        precondition(shared.error == nil && shared.document?.currentText(at: 6) == "Open window")

        print("Lyrics checks passed: LRC timing, gaps, offsets, repeats, matching, duration, request privacy, cache, plain lyrics, instrumental, missing, retry, malformed response, podcasts, shared presentation state, song changes, live gaps, and retry")
    }

    @MainActor private static func waitForLyrics(_ lyrics: LyricsState) async throws {
        for _ in 0..<200 {
            if !lyrics.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Lyrics lookup did not finish")
    }

}
