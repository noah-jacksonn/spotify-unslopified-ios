import Foundation
import Observation

struct LyricLine: Identifiable, Equatable {
    var id: Int
    var time: TimeInterval
    var text: String
}

struct LyricsDocument {
    var lines: [LyricLine]
    var plainText: String?
    var instrumental: Bool
    var sourceURL: URL?

    func activeLine(at seconds: TimeInterval) -> Int? {
        lines.last { $0.time <= seconds }?.id
    }

    func currentText(at seconds: TimeInterval) -> String? {
        guard let line = lines.last(where: { $0.time <= seconds }), !line.text.isEmpty else { return nil }
        return line.text
    }
}

/// Owned by the app, shared by successive player sheets and both lyric views.
/// A song change cancels the old lookup; reopening reuses its result or request.
@MainActor @Observable
final class LyricsState {
    private(set) var document: LyricsDocument?
    private(set) var trackURI: String?
    private(set) var isLoading = false
    private(set) var error: String?
    private var lookupKey: String?
    @ObservationIgnored private var request: Task<Void, Never>?
    private let service: LyricsService

    init(service: LyricsService? = nil) { self.service = service ?? LyricsService() }

    func load(for state: NowPlaying?, sample: LyricsDocument? = nil, retry: Bool = false) {
        guard let state, !state.isEpisode else {
            request?.cancel()
            request = nil
            lookupKey = nil
            trackURI = nil
            document = nil
            error = nil
            isLoading = false
            return
        }
        let key = "\(state.trackURI)|\(state.durationMs)|\(state.title)|\(state.artist)|\(state.album)"
        guard retry || lookupKey != key else { return }
        request?.cancel()
        lookupKey = key
        trackURI = state.trackURI
        document = sample ?? service.cachedLyrics(for: state)
        error = nil
        isLoading = document == nil
        guard document == nil else { request = nil; return }
        request = Task { [weak self, service] in
            do {
                let document = try await service.lyrics(for: state)
                guard !Task.isCancelled, let self, self.lookupKey == key else { return }
                self.document = document
                self.isLoading = false
                self.request = nil
            } catch {
                guard !Task.isCancelled, let self, self.lookupKey == key else { return }
                self.error = error.localizedDescription
                self.isLoading = false
                self.request = nil
            }
        }
    }
}

/// LRC supports repeated timestamps and a file-wide millisecond offset.
/// Blank timed lines are kept as instrumental gaps, not sung text.
enum LRCParser {
    static func parse(_ text: String) -> [LyricLine] {
        let timestamps = try! NSRegularExpression(pattern: #"\[(\d+):([0-5]\d)(?:[.:](\d{1,3}))?\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let whole = NSRange(text.startIndex..., in: text)
        let offset = offsetPattern.firstMatch(in: text, range: whole).flatMap { match -> Double? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return Double(text[range]).map { $0 / 1000 }
        } ?? 0
        var parsed: [(time: Double, text: String, order: Int)] = []
        for raw in text.components(separatedBy: .newlines) {
            let matches = timestamps.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            guard !matches.isEmpty else { continue }
            let words = timestamps.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for match in matches {
                func number(_ index: Int) -> String {
                    Range(match.range(at: index), in: raw).map { String(raw[$0]) } ?? ""
                }
                guard let minutes = Double(number(1)), let seconds = Double(number(2)) else { continue }
                let fraction = Double("0." + number(3)) ?? 0
                let time = max(0, minutes * 60 + seconds + fraction + offset)
                guard time.isFinite else { continue }
                parsed.append((time, words, parsed.count))
            }
        }
        let sorted = parsed.sorted { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        var seen = Set<String>()
        return sorted.filter { seen.insert("\($0.time):\($0.text)").inserted }
            .enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }
}

/// On-demand public lyrics lookup. Spotify credentials never leave Spotify.
/// Cache is bounded and memory-only; failures can always be retried.
@MainActor
final class LyricsService {
    private struct Record: Decodable {
        var id: Int
        var trackName: String
        var artistName: String
        var duration: Double
        var instrumental: Bool
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    enum Failure: LocalizedError {
        case unavailable, response(Int)
        var errorDescription: String? {
            switch self {
            case .unavailable: "The lyrics service sent an unexpected response. Try again."
            case .response(429): "The lyrics service is busy. Try again in a moment."
            case .response: "Couldn’t load lyrics right now. Try again."
            }
        }
    }

    private let session: URLSession
    private var cache: [String: LyricsDocument] = [:]
    private var order: [String] = []

    init(session: URLSession = .shared) { self.session = session }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Read synchronously so a cached song never flashes a loading state.
    func cachedLyrics(for state: NowPlaying) -> LyricsDocument? {
        guard !state.isEpisode else { return nil }
        return cache[Self.cacheKey(for: state)]
    }

    private static func cacheKey(for state: NowPlaying) -> String {
        "\(state.trackURI)|\(state.durationMs)"
    }

    func lyrics(for state: NowPlaying) async throws -> LyricsDocument? {
        guard !state.isEpisode else { return nil }
        let key = Self.cacheKey(for: state)
        if let cached = cache[key] { return cached }
        let artist = state.artistItem?.name ?? state.artist
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            .init(name: "track_name", value: state.title),
            .init(name: "artist_name", value: artist),
            .init(name: "album_name", value: state.album),
        ]
        if state.durationMs > 0 && state.durationMs <= 3_600_000 {
            components.queryItems?.append(.init(name: "duration", value: String(Double(state.durationMs) / 1000)))
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("SpotifyUnslopified/1.0 (iOS lyrics viewer)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw Failure.response(http.statusCode) }
        guard data.count <= 1_000_000 else { throw Failure.unavailable }
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { throw Failure.unavailable }
        guard Self.normalized(record.trackName) == Self.normalized(state.title),
              [Self.normalized(artist), Self.normalized(state.artist)].contains(Self.normalized(record.artistName)) else { return nil }
        // Never attach timing for a different recording/version to this song.
        guard state.durationMs <= 0 || abs(record.duration - Double(state.durationMs) / 1000) <= 2 else { return nil }
        let lines = LRCParser.parse(record.syncedLyrics ?? "").filter {
            state.durationMs <= 0 || $0.time * 1000 <= Double(state.durationMs)
        }
        let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard record.instrumental || lines.contains(where: { !$0.text.isEmpty }) || plain?.isEmpty == false else { return nil }
        let document = LyricsDocument(lines: lines, plainText: plain, instrumental: record.instrumental,
                                      sourceURL: URL(string: "https://lrclib.net")!)
        cache[key] = document
        order.append(key)
        if order.count > 24 { cache.removeValue(forKey: order.removeFirst()) }
        return document
    }
}
