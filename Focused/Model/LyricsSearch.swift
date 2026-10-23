import Foundation

/// Finds songs by their words, then resolves them to playable Spotify tracks.
/// Genius's public website endpoint is separate from its developer API and
/// can change: an unavailable/malformed response must be an error, not no hits.
/// Only the typed phrase goes to Genius. No Spotify credentials or lyrics
/// documents are sent, and no lyric text is downloaded from song pages.
@MainActor
final class LyricsSearchService {
    enum Failure: LocalizedError {
        case unavailable, busy

        var errorDescription: String? {
            switch self {
            case .unavailable: "Lyrics search isn’t available right now. Try again in a moment."
            case .busy: "Lyrics search is busy. Try again in a moment."
            }
        }
    }

    private struct Response: Decodable {
        var meta: Meta
        var response: Body
        struct Meta: Decodable { var status: Int }
        struct Body: Decodable {
            var sections: [Section]
            var next_page: Int?
        }
        struct Section: Decodable {
            var type: String
            var hits: [Hit]
        }
        struct Hit: Decodable {
            var type: String
            var result: Song?
            var highlights: [Highlight]?
        }
        struct Highlight: Decodable {
            var property: String
            var value: String
        }
        struct Song: Decodable {
            var title: String?
            var primary_artist: Artist?
        }
        struct Artist: Decodable { var name: String }
    }

    private let session: URLSession
    private struct CacheKey: Hashable {
        var phrase: String
        var page: Int
    }
    private var cache: [CacheKey: LyricsSearchPage] = [:]
    private var cacheOrder: [CacheKey] = []

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func search(_ phrase: String, page: Int = 1, catalogSearch: (String) async throws -> [Track]) async throws -> LyricsSearchPage {
        try Task.checkCancellation()
        guard page > 0 else { throw Failure.unavailable }
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return LyricsSearchPage() }
        let key = CacheKey(phrase: Self.normalized(phrase), page: page)
        if let cached = cache[key] { return cached }

        var url = URLComponents(string: "https://genius.com/api/search/lyric")!
        url.queryItems = [.init(name: "q", value: phrase), .init(name: "per_page", value: "5"),
                          .init(name: "page", value: String(page))]
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SpotifyUnslopified/1.0 (iOS lyrics search)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        if http.statusCode == 429 { throw Failure.busy }
        guard http.statusCode == 200, data.count <= 1_000_000,
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.meta.status == 200,
              let section = decoded.response.sections.first(where: { $0.type == "lyric" }) else {
            throw Failure.unavailable
        }

        var matches: [LyricsSearchMatch] = []
        var seenSongs = Set<String>()
        var seenTracks = Set<String>()
        var lookupCount = 0
        for hit in section.hits.prefix(5) where hit.type == "song" {
            try Task.checkCancellation()
            guard let rawTitle = hit.result?.title, let artist = hit.result?.primary_artist?.name,
                  let excerpt = hit.highlights?.first(where: { $0.property == "lyrics" })?.value,
                  !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !Self.normalized(rawTitle).isEmpty, !Self.normalized(artist).isEmpty else { continue }
            let title = Self.catalogTitle(rawTitle)
            let songKey = "\(Self.normalized(title))|\(Self.normalized(artist))"
            guard seenSongs.insert(songKey).inserted else { continue }
            // Pace catalog requests and stop the whole chain when typing resumes.
            if lookupCount > 0 { try await Task.sleep(for: .milliseconds(200)) }
            lookupCount += 1
            let query = "track:\"\(Self.quoted(title))\" artist:\"\(Self.quoted(artist))\""
            let candidates = try await catalogSearch(query)
            try Task.checkCancellation()
            // Never play an unrelated top hit, cover, or unavailable recording.
            if let track = candidates.first(where: {
                $0.isPlayable != false && $0.uri.hasPrefix("spotify:track:") &&
                Self.normalized(Self.catalogTitle($0.name)) == Self.normalized(title) &&
                ($0.artistNames.isEmpty ? [$0.artists] : $0.artistNames).contains {
                    Self.normalized($0) == Self.normalized(artist)
                }
            }), seenTracks.insert(track.uri).inserted {
                matches.append(LyricsSearchMatch(track: track, excerpt: Self.excerpt(excerpt, matching: phrase)))
            }
        }

        try Task.checkCancellation()
        // A page can have no Spotify matches and still have more lyric hits.
        // Reject backwards cursors so an unexpected response cannot loop.
        let nextPage = section.hits.isEmpty ? nil : decoded.response.next_page.flatMap { $0 > page ? $0 : nil }
        let result = LyricsSearchPage(matches: matches, nextPage: nextPage)
        if !matches.isEmpty {
            if cache[key] == nil { cacheOrder.append(key) }
            cache[key] = result
            if cacheOrder.count > 12 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
        return result
    }

    /// Keep nearby words, like Harmony's transcript snippets, without letting
    /// a long provider excerpt push the actual match outside the visible lines.
    static func excerpt(_ text: String, matching phrase: String) -> String {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let phrase = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count > 240 else { return text }
        let match = text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive])
        let start = match.map { text.index($0.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
        let end = text.index(start, offsetBy: 240, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + String(text[start..<end]) + (end == text.endIndex ? "" : "…")
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "\\", with: " ")
            .components(separatedBy: .newlines).joined(separator: " ")
    }

    /// Spotify often appends a remaster label to the same recording. Ignore
    /// that label only; live, acoustic and remix versions remain distinct.
    private static func catalogTitle(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)(?:\s+[-–—]\s*|\s*\()(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?\)?\s*$"#,
            with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
