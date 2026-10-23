import Foundation
import Observation

struct DailyPick: Codable, Identifiable {
    var track: Track
    var sourcePlaylist: String
    var artist: CatalogItem
    var connection: String? = nil
    var id: String { track.uri }
}

struct DailyEdition: Codable {
    var day: String
    var createdAt: Date
    var picks: [DailyPick]
}

/// Pure selection rules, shared by production and the regression checks.
/// No listening profile: only the playlists explicitly selected for this feature.
enum DailySelection {
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func rank(_ text: String) -> UInt64 {
        text.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    /// Also excludes alternate releases of the same recording by title/artist.
    static func keys(_ track: Track) -> Set<String> {
        let title = track.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artistIDs.sorted().joined(separator: ",")
        let credit = artist.isEmpty ? track.artists.lowercased() : artist
        var result: Set<String> = [track.uri, "song:\(credit):\(title)"]
        if let recording = track.recordingID { result.insert("recording:\(recording)") }
        return result
    }

    static func choose(_ buckets: [[DailyPick]], excluding: Set<String>, day: String) -> [DailyPick] {
        let ordered = buckets.map { bucket in
            bucket.filter { $0.track.isPlayable != false && excluding.isDisjoint(with: keys($0.track)) }
                .sorted { rank(day + $0.id) < rank(day + $1.id) }
        }
        var seen = excluding
        var picks: [DailyPick] = []
        // Advance past unavailable/duplicate hits within each bucket before
        // moving on, so shared collaborations cannot crowd out an artist.
        var positions = Array(repeating: 0, count: ordered.count)
        while ordered.indices.contains(where: { positions[$0] < ordered[$0].count }) {
            for index in ordered.indices {
                while positions[index] < ordered[index].count {
                    let pick = ordered[index][positions[index]]
                    positions[index] += 1
                    let keys = keys(pick.track)
                    guard seen.isDisjoint(with: keys) else { continue }
                    picks.append(pick)
                    seen.formUnion(keys)
                    if picks.count == 5 { return picks }
                    break
                }
            }
        }
        return picks
    }
}

@MainActor @Observable
final class DailyFive {
    private struct History: Codable { var day: String; var keys: Set<String> }
    private struct Saved: Codable {
        var sourceIDs: [String] = []
        var edition: DailyEdition?
        var history: [History] = []
    }

    var sourceIDs: [String] { saved.sourceIDs }
    var edition: DailyEdition? { saved.edition }
    private(set) var isLoading = false
    private(set) var progress = ""
    private(set) var error: String?
    private var saved: Saved
    private let defaults: UserDefaults
    private let key: String
    private var revision = 0

    init(accountID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "dailyFive.v1.\(accountID)"
        saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    var isToday: Bool { edition?.day == DailySelection.dayKey(Date()) }

    /// Hide stale picks even before the view's load task starts. Keep the last
    /// edition available as a fallback only after a refresh fails.
    func showsLoadingSkeleton(on date: Date = .now) -> Bool {
        !sourceIDs.isEmpty && edition?.day != DailySelection.dayKey(date)
            && (isLoading || error == nil)
    }

    func setSources(_ playlists: [Playlist]) {
        var seen = Set<String>()
        saved.sourceIDs = Array(playlists.filter { $0.isMine && seen.insert($0.id).inserted }.prefix(5).map(\.id))
        persist()
        error = nil
    }

    /// Called before switching account; in-flight network results cannot persist.
    func cancel() { revision += 1 }

    func load(using music: any MusicService, playlists: [Playlist], clock: () -> Date = Date.init) async {
        let now = clock()
        let day = DailySelection.dayKey(now)
        if let edition {
            music.prepareForPlayback(edition.picks.map(\.track))
            if edition.day == day { return }
        }
        guard !isLoading, !sourceIDs.isEmpty else { return }
        let requestRevision = revision
        isLoading = true
        error = nil
        progress = "Reading your chosen playlists…"
        defer { isLoading = false; progress = "" }
        do {
            let sources = sourceIDs.compactMap { id in playlists.first { $0.id == id && $0.isMine } }
            guard !sources.isEmpty else { throw DiscoveryFailure.missingSources }
            var known = Set<String>()
            var seeds: [(artist: CatalogItem, playlist: String)] = []
            var artists = Set<String>()
            for source in sources {
                try Task.checkCancellation()
                let tracks = try await music.tracks(in: source)
                for track in tracks {
                    known.formUnion(DailySelection.keys(track))
                    guard !NowPlaying.isSpoken(uri: track.uri) else { continue }
                    for (id, name) in zip(track.artistIDs, track.artistNames) where artists.insert(id).inserted {
                        seeds.append((.spotifyArtist(id: id, name: name), source.name))
                    }
                }
            }
            guard !seeds.isEmpty else { throw DiscoveryFailure.noArtists }
            // Deterministic daily rotation; artist frequency in a playlist does
            // not give one artist a monopoly on the five slots.
            seeds.sort { DailySelection.rank(day + $0.artist.id) < DailySelection.rank(day + $1.artist.id) }
            let history = saved.history.filter { $0.day >= Self.historyCutoff(now) }
            let excluded = known.union(history.flatMap(\.keys))
            var buckets: [[DailyPick]] = []
            for seed in seeds.prefix(10) {
                try Task.checkCancellation()
                guard revision == requestRevision else { throw CancellationError() }
                progress = "Exploring \(seed.artist.name)…"
                let rotation = Int(DailySelection.rank(day + seed.artist.id) % 10000)
                let tracks = try await music.discoveryTracks(for: seed.artist, rotation: rotation)
                let picks = tracks.filter { !NowPlaying.isSpoken(uri: $0.uri) }.map {
                    DailyPick(track: $0, sourcePlaylist: seed.playlist, artist: seed.artist)
                }
                buckets.append(picks)
                // Prefer five distinct artists; use a second track only when
                // fewer artists have eligible songs after the bounded search.
                let trial = DailySelection.choose(buckets, excluding: excluded, day: day)
                if trial.count == 5 && Set(trial.map { $0.artist.id }).count == 5 { break }
            }
            var picks = DailySelection.choose(buckets, excluding: excluded, day: day)
            // A small step outside the source artists: a credited collaborator
            // can lead to one solo song of theirs. The connection is shown,
            // and never fabricated from genres or a restricted related API.
            var collaboratorIDs = artists
            let connections = buckets.flatMap { $0 }.flatMap { pick in
                zip(pick.track.artistIDs, pick.track.artistNames).compactMap { id, name -> (CatalogItem, DailyPick)? in
                    guard collaboratorIDs.insert(id).inserted else { return nil }
                    return (.spotifyArtist(id: id, name: name), pick)
                }
            }.sorted { DailySelection.rank(day + $0.0.id) < DailySelection.rank(day + $1.0.id) }
            for (collaborator, origin) in connections.prefix(2) {
                try Task.checkCancellation()
                progress = "Following a connection to \(collaborator.name)…"
                let tracks: [Track]
                do {
                    tracks = try await music.discoveryTracks(for: collaborator,
                        rotation: Int(DailySelection.rank(day + collaborator.id) % 10000))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    // This extra connection is optional once five eligible
                    // songs exist. A provider failure shouldn't discard them.
                    guard picks.count == 5 else { throw error }
                    break
                }
                let candidates = tracks.filter {
                    !NowPlaying.isSpoken(uri: $0.uri) && artists.isDisjoint(with: $0.artistIDs)
                }.map {
                    DailyPick(track: $0, sourcePlaylist: origin.sourcePlaylist, artist: collaborator,
                              connection: origin.artist.name)
                }
                if let discovery = DailySelection.choose([candidates], excluding: excluded, day: day).first {
                    picks = Array(picks.prefix(4)) + [discovery]
                    break
                }
            }
            guard picks.count == 5 else { throw DiscoveryFailure.notEnough }
            try Task.checkCancellation()
            guard revision == requestRevision else { throw CancellationError() }
            guard DailySelection.dayKey(clock()) == day else { throw DiscoveryFailure.dayChanged }
            music.prepareForPlayback(picks.map(\.track))
            let edition = DailyEdition(day: day, createdAt: now, picks: picks)
            saved.history = history + [History(day: day, keys: Set(picks.flatMap { DailySelection.keys($0.track) }))]
            saved.edition = edition
            persist()
        } catch is CancellationError {
            // Navigation and account changes are not user-facing failures.
        } catch {
            guard revision == requestRevision, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private static func historyCutoff(_ date: Date) -> String {
        DailySelection.dayKey(Calendar.current.date(byAdding: .day, value: -30, to: date) ?? date)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
    }

    private enum DiscoveryFailure: LocalizedError {
        case missingSources, noArtists, notEnough, dayChanged
        var errorDescription: String? {
            switch self {
            case .missingSources: "Choose a playlist you own or collaborate on to guide your five."
            case .noArtists: "These playlists don't have any available songs yet. Try a different playlist."
            case .dayChanged: "A new day just started. Try again for today’s five."
            case .notEnough: "Couldn't find five fresh songs from these artists. Add another source playlist or try again tomorrow."
            }
        }
    }
}
