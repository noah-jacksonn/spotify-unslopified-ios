import Foundation

@main
struct DailyFiveTests {
    @MainActor static func main() async throws {
        let suite = "DailyFiveTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let midnight = ISO8601DateFormatter().date(from: "2026-10-11T16:00:00Z")!
        precondition(DailySelection.dayKey(midnight.addingTimeInterval(-1), calendar: calendar) == "2026-10-11")
        precondition(DailySelection.dayKey(midnight, calendar: calendar) == "2026-10-12")

        let music = DemoMusic()
        let playlists = try await music.loadPlaylists()
        let daily = DailyFive(accountID: "one", defaults: defaults)
        daily.setSources(Array(playlists.filter(\.isMine).prefix(3)))
        let today = Date()
        await daily.load(using: music, playlists: playlists, clock: { today })
        guard let edition = daily.edition else { fatalError(daily.error ?? "No edition") }
        precondition(edition.picks.count == 5)
        precondition(Set(edition.picks.map { $0.artist.id }).count == 5, "Prefer different artists")
        let ids = edition.picks.map(\.id)
        precondition(Set(ids).count == 5, "No duplicate recordings")
        var known = Set<String>()
        for source in playlists.filter({ daily.sourceIDs.contains($0.id) }) {
            let tracks = try await music.tracks(in: source)
            for track in tracks { known.formUnion(DailySelection.keys(track)) }
        }
        precondition(edition.picks.allSatisfy { known.isDisjoint(with: DailySelection.keys($0.track)) })
        await daily.load(using: music, playlists: playlists, clock: { today })
        precondition(daily.edition?.picks.map(\.id) == ids, "Reload must preserve today's five")
        let restored = DailyFive(accountID: "one", defaults: defaults)
        precondition(restored.edition?.picks.map(\.id) == ids, "Persist across launches")
        precondition(restored.sourceIDs == daily.sourceIDs)
        let freshDemo = DemoMusic()
        await restored.load(using: freshDemo, playlists: playlists, clock: { today })
        freshDemo.play(.tracks(ids))
        precondition(freshDemo.nowPlaying?.trackURI == ids.first, "Cached preview songs must remain playable after relaunch")
        let other = DailyFive(accountID: "two", defaults: defaults)
        precondition(other.edition == nil && other.sourceIDs.isEmpty, "Account isolation")
        daily.setSources([playlists[0]])
        precondition(daily.edition?.picks.map(\.id) == ids, "Changing sources must preserve today's edition")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        await restored.load(using: music, playlists: [], clock: { tomorrow })
        precondition(restored.edition?.picks.map(\.id) == ids && restored.error != nil,
                     "Failed refresh must preserve the last playable edition")
        await daily.load(using: music, playlists: playlists, clock: { tomorrow })
        guard let next = daily.edition else { fatalError("Missing next edition") }
        precondition(next.day != edition.day && next.picks.count == 5)
        let yesterdayKeys = Set(edition.picks.flatMap { DailySelection.keys($0.track) })
        precondition(next.picks.allSatisfy { yesterdayKeys.isDisjoint(with: DailySelection.keys($0.track)) }, "No recent repeats")

        // Duplicate album editions, excluded first hits, and sparse pools.
        let a = edition.picks[0]
        var duplicate = a
        duplicate.track.uri = "different-release"
        duplicate.track.id = "different-release"
        let remaining = Array(edition.picks.dropFirst())
        let result = DailySelection.choose([[a, duplicate]] + remaining.map { [$0] }, excluding: [], day: "fixed")
        precondition(result.count == 5 && Set(result.map { $0.artist.id }).count == 5)
        let filtered = DailySelection.choose([[a, duplicate]], excluding: DailySelection.keys(a.track), day: "fixed")
        precondition(filtered.isEmpty, "Exclude alternate releases by title and artist")
        var remaster = duplicate
        var original = a
        original.track.recordingID = "same-isrc"
        remaster.track.recordingID = "same-isrc"
        remaster.track.name += " (Remastered)"
        precondition(DailySelection.choose([[original, remaster]], excluding: [], day: "fixed").count == 1)
        var restricted = a
        restricted.track.isPlayable = false
        precondition(DailySelection.choose([[restricted]], excluding: [], day: "fixed").isEmpty,
                     "Unavailable tracks stay in source lists but cannot become recommendations")
        precondition(DailySelection.choose([[duplicate]], excluding: DailySelection.keys(restricted.track), day: "fixed").isEmpty,
                     "A restricted source recording must still exclude its playable alternate release")

        let collaboratorMusic = FailingCollaboratorMusic()
        let fallback = DailyFive(accountID: "collaborator-fallback", defaults: defaults)
        fallback.setSources([playlists[0]])
        await fallback.load(using: collaboratorMusic, playlists: playlists)
        precondition(collaboratorMusic.collaboratorRequests > 0)
        precondition(fallback.edition?.picks.count == 5 && fallback.error == nil,
                     "An optional collaborator failure must preserve five valid picks")
        collaboratorMusic.cancelLookup = true
        let interrupted = DailyFive(accountID: "collaborator-cancelled", defaults: defaults)
        interrupted.setSources([playlists[0]])
        await interrupted.load(using: collaboratorMusic, playlists: playlists)
        precondition(interrupted.edition == nil, "Never treat cancellation as an optional lookup failure")

        // Cancellation never publishes an unfinished edition.
        let cancelled = DailyFive(accountID: "cancelled", defaults: defaults)
        cancelled.setSources([playlists[0]])
        let job = Task { await cancelled.load(using: music, playlists: playlists) }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        await job.value
        precondition(cancelled.edition == nil)
        let emptySource = Playlist(id: "empty", name: "Empty", ownerName: "You", isMine: true, uri: "demo:empty")
        let empty = DailyFive(accountID: "empty", defaults: defaults)
        empty.setSources([emptySource])
        await empty.load(using: music, playlists: [emptySource])
        precondition(empty.edition == nil && empty.error != nil)
        let crossing = DailyFive(accountID: "crossing", defaults: defaults)
        crossing.setSources([playlists[0]])
        var clockReads = 0
        await crossing.load(using: music, playlists: playlists, clock: {
            clockReads += 1
            return clockReads == 1 ? today : tomorrow
        })
        precondition(crossing.edition == nil && crossing.error != nil, "Discard a generation that crosses midnight")
        print("Daily Five checks passed: five distinct artists, exclusions, duplicate releases, persistence, local midnight, refresh, 30-day history, account isolation, source changes, cancellation, empty sources")
    }
}

private final class FailingCollaboratorMusic: MusicService {
    private let demo = DemoMusic()
    var collaboratorRequests = 0
    var cancelLookup = false
    var nowPlaying: NowPlaying? { demo.nowPlaying }
    var onNotice: ((Notice) -> Void)?
    func accountID() async throws -> String { "test" }
    func loadPlaylists() async throws -> [Playlist] { try await demo.loadPlaylists() }
    func tracks(in playlist: Playlist) async throws -> [Track] { try await demo.tracks(in: playlist) }
    func discoveryTracks(for artist: CatalogItem, rotation: Int) async throws -> [Track] {
        if artist.id == "guest" {
            collaboratorRequests += 1
            if cancelLookup { throw CancellationError() }
            throw URLError(.networkConnectionLost)
        }
        var tracks = try await demo.discoveryTracks(for: artist, rotation: rotation)
        tracks[0].artistIDs.append("guest")
        tracks[0].artistNames.append("Guest")
        return tracks
    }
    func search(_ query: String) async throws -> SearchResults { try await demo.search(query) }
    func artistPage(_ artist: CatalogItem) async throws -> ArtistPage { try await demo.artistPage(artist) }
    func albumPage(_ album: CatalogItem) async throws -> AlbumPage { try await demo.albumPage(album) }
    func add(_ trackURIs: [String], to playlist: Playlist) async throws {}
    func deletePlaylist(_ playlist: Playlist) async throws {}
    func remove(_ trackURIs: [String], from playlist: Playlist) async throws {}
    func playbackQueue() async throws -> PlaybackQueue { try await demo.playbackQueue() }
    func enqueue(_ track: Track) async throws {}
    func play(_ request: PlayRequest) {}
    func shuffle(_ request: PlayRequest) {}
    func openSpotify() {}
    func togglePause() {}
    func next() {}
    func previous() {}
    func seek(toMs position: Int) {}
    func appBecameActive() {}
    func appWillResignActive() {}
    func handle(url: URL) {}
}
