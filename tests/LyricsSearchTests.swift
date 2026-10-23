import Foundation

private final class SearchStub: URLProtocol {
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
struct LyricsSearchTests {
    static func hit(_ title: String, _ artist: String, excerpt: String = "Morning light across the floor") -> [String: Any] {
        ["type": "song", "result": ["title": title, "primary_artist": ["name": artist]],
         "highlights": [["property": "lyrics", "value": excerpt]]]
    }

    static func response(_ hits: [[String: Any]], nextPage: Int? = nil) throws -> Data {
        var body: [String: Any] = ["sections": [["type": "lyric", "hits": hits]]]
        body["next_page"] = nextPage.map { $0 as Any } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: ["meta": ["status": 200], "response": body])
    }

    static func track(_ title: String = "Open Window", _ artist: String = "Example Artist", id: String = "one") -> Track {
        Track(id: id, name: title, artists: artist, album: "Daylight", imageURL: nil, durationMs: 180_000,
              uri: "spotify:track:\(id)", artistNames: [artist])
    }

    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = LyricsSearchService(session: session)
        SearchStub.body = try response([hit("Open Window", "Example Artist"), hit("Open Window", "Example Artist")])
        var queries: [String] = []
        let matches = try await service.search("  morning light  ") { query in
            queries.append(query)
            var unavailable = track(id: "blocked")
            unavailable.isPlayable = false
            return [track("Open Window", "Wrong Artist", id: "cover"), unavailable,
                    track("Open Window Live", id: "live"), track()]
        }
        precondition(matches.matches.count == 1 && matches.matches[0].track.id == "one")
        precondition(matches.matches[0].excerpt == "Morning light across the floor")
        precondition(queries == ["track:\"Open Window\" artist:\"Example Artist\""], "Deduplicate provider songs before catalog lookups")
        let request = SearchStub.requests.last!
        let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(request.url?.host == "genius.com" && request.url?.path == "/api/search/lyric")
        precondition(queryItems.first { $0.name == "q" }?.value == "morning light")
        precondition(queryItems.first { $0.name == "page" }?.value == "1")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil && !request.httpShouldHandleCookies)
        let count = SearchStub.requests.count
        _ = try await service.search("MORNING LIGHT") { _ in preconditionFailure("Cached search should not re-query Spotify") }
        precondition(SearchStub.requests.count == count)

        // Neither whitespace nor an empty provider result should hit Spotify.
        let blank = try await service.search(" \n ") { _ in preconditionFailure("Blank query") }
        precondition(blank.matches.isEmpty && SearchStub.requests.count == count)
        SearchStub.body = try response([])
        let empty = try await service.search("nothing") { _ in preconditionFailure("No lyric matches") }
        precondition(empty.matches.isEmpty && empty.nextPage == nil)

        // A song without a lyric excerpt is not a lyric hit.
        var noLyrics = hit("Open Window", "Example Artist")
        noLyrics["highlights"] = [["property": "title", "value": "Open Window"]]
        SearchStub.body = try response([noLyrics])
        let titleOnly = try await service.search("title only") { _ in preconditionFailure("Title-only hit") }
        precondition(titleOnly.matches.isEmpty)

        // Missing Spotify matches must not substitute an unrelated first result.
        SearchStub.body = try response([hit("Open Window", "Example Artist")])
        let wrong = try await service.search("wrong match") { _ in [track("Other Song")] }
        precondition(wrong.matches.isEmpty)
        let recovered = try await service.search("wrong match") { _ in [track()] }
        precondition(recovered.matches.count == 1, "Do not cache missing catalog results")

        SearchStub.body = try response([hit("Open Window (2011 Remaster)", "Example Artist"), hit("Open Window", "Example Artist")])
        var remasterCalls = 0
        let remaster = try await service.search("remaster") { query in
            remasterCalls += 1
            precondition(query == "track:\"Open Window\" artist:\"Example Artist\"")
            return [track("Open Window - Live", id: "live"), track("Open Window - Remastered 2011", id: "remaster")]
        }
        precondition(remaster.matches.count == 1 && remaster.matches[0].track.id == "remaster" && remasterCalls == 1,
                     "Resolve equivalent remaster labels without substituting live versions or duplicating lookups")

        // Unicode punctuation/diacritics can differ between catalogs.
        SearchStub.body = try response([hit("Don’t Go", "Beyoncé")])
        let unicode = try await service.search("unicode") { _ in [track("Don't Go", "Beyonce")] }
        precondition(unicode.matches.count == 1)
        SearchStub.body = try response([hit("A \"Window\"", "Example Artist")])
        _ = try await service.search("quoted") { query in
            precondition(query == "track:\"A  Window \" artist:\"Example Artist\"")
            return []
        }

        // A broken provider is a retryable error, never a false empty result.
        for status in [403, 429, 500] {
            SearchStub.status = status
            do {
                _ = try await service.search("failure \(status)") { _ in [] }
                preconditionFailure("Expected HTTP failure")
            } catch is LyricsSearchService.Failure {}
        }
        SearchStub.status = 200
        for body in [Data("<html>unavailable</html>".utf8), Data("{\"meta\":{\"status\":200},\"response\":{\"sections\":[]}}".utf8)] {
            SearchStub.body = body
            do {
                _ = try await service.search("malformed") { _ in [] }
                preconditionFailure("Expected malformed-response failure")
            } catch is LyricsSearchService.Failure {}
        }

        SearchStub.body = try response([hit("Open Window", "Example Artist"), hit("Second Song", "Other Artist")])
        var catalogCalls = 0
        let cancelled = Task {
            try await service.search("cancelled") { _ in
                catalogCalls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return [track()]
            }
        }
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancellation must prevent results and later catalog calls")
        } catch is CancellationError {}
        precondition(catalogCalls == 1)

        // The provider cannot make us fan out to an unbounded number of requests.
        SearchStub.body = try response((0..<20).map { hit("Song \($0)", "Example Artist") })
        catalogCalls = 0
        _ = try await service.search("bounded") { _ in catalogCalls += 1; return [] }
        precondition(catalogCalls == 5)

        SearchStub.body = try response([hit("Open Window", "Example Artist")])
        for index in 0..<13 { _ = try await service.search("cache \(index)") { _ in [track()] } }
        let beforeEviction = SearchStub.requests.count
        _ = try await service.search("cache 0") { _ in [track()] }
        precondition(SearchStub.requests.count == beforeEviction + 1, "Bound memory-only cache")

        let long = String(repeating: "before ", count: 80) + "morning light" + String(repeating: " after", count: 80)
        let excerpt = LyricsSearchService.excerpt(long, matching: "morning light")
        precondition(excerpt.contains("morning light") && excerpt.count <= 242)

        let demo = DemoMusic()
        let demoResults = try await demo.searchLyrics("morning light", page: 1)
        precondition(!demoResults.matches.isEmpty && demoResults.matches.allSatisfy { $0.excerpt.lowercased().contains("morning light") })
        precondition(demoResults.nextPage == 2)
        let demoMore = try await demo.searchLyrics("morning light", page: 2)
        precondition(!demoMore.matches.isEmpty && Set(demoMore.matches.map(\.id)).isDisjoint(with: demoResults.matches.map(\.id)))
        let demoEmpty = try await demo.searchLyrics("unmatched invented lyric", page: 1)
        precondition(demoEmpty.matches.isEmpty && demoEmpty.nextPage == nil)

        try await pagination(service)
        print("Lyrics search checks passed: true lyric hits, Spotify identity, excerpts, Unicode, privacy, pagination, deduplication, retry, cancellation, bounded requests/cache, preview")
    }

    @MainActor static func pagination(_ service: LyricsSearchService) async throws {
        SearchStub.body = try response([hit("Open Window", "Example Artist")], nextPage: 2)
        let first = try await service.search("paged", page: 1) { _ in [track()] }
        precondition(first.nextPage == 2)

        // Later pages must use the provider's cursor, not the visible row count.
        SearchStub.body = try response([hit("Open Window", "Example Artist"), hit("Second Song", "Example Artist")], nextPage: 3)
        let second = try await service.search("paged", page: 2) { query in
            [query.contains("Second Song") ? track("Second Song", id: "two") : track()]
        }
        let query = URLComponents(url: SearchStub.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.first { $0.name == "page" }?.value == "2")
        var combined = first
        combined.append(second)
        precondition(combined.matches.map(\.track.id) == ["one", "two"] && combined.nextPage == 3,
                     "Append new rows without duplicating earlier songs")

        let beforeCache = SearchStub.requests.count
        let cachedFirst = try await service.search("PAGED", page: 1) { _ in preconditionFailure("Page 1 cache") }
        let cachedSecond = try await service.search("paged", page: 2) { _ in preconditionFailure("Page 2 cache") }
        precondition(SearchStub.requests.count == beforeCache && cachedFirst.nextPage == 2 && cachedSecond.nextPage == 3)

        SearchStub.status = 500
        do {
            let failed = try await service.search("paged", page: 3) { _ in [] }
            combined.append(failed)
            preconditionFailure("Expected page failure")
        } catch is LyricsSearchService.Failure {}
        precondition(combined.matches.count == 2 && combined.nextPage == 3, "Failure must leave songs and retry cursor intact")

        // No Spotify matches is not the end when the provider still has hits.
        SearchStub.status = 200
        SearchStub.body = try response([hit("Unmatched Song", "Example Artist")], nextPage: 4)
        let unmatched = try await service.search("paged", page: 3) { _ in [] }
        precondition(unmatched.matches.isEmpty && unmatched.nextPage == 4)
        combined.append(unmatched)
        precondition(combined.matches.count == 2 && combined.nextPage == 4)

        SearchStub.body = try response([hit("Last Song", "Example Artist")])
        combined.append(try await service.search("paged", page: 4) { _ in [track("Last Song", id: "last")] })
        precondition(combined.matches.map(\.track.id) == ["one", "two", "last"] && combined.nextPage == nil)

        SearchStub.body = try response([hit("Open Window", "Example Artist")], nextPage: 2)
        let backwards = try await service.search("bad cursor", page: 2) { _ in [track()] }
        precondition(backwards.nextPage == nil, "Never request the same or an earlier page again")
        SearchStub.body = try response([], nextPage: 6)
        let empty = try await service.search("empty page", page: 5) { _ in preconditionFailure("No hits") }
        precondition(empty.nextPage == nil)
    }
}
