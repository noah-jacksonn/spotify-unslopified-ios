import Foundation

@main
struct QueueTests {
    @MainActor static func main() async throws {
        let music = DemoMusic()
        let lists = try await music.loadPlaylists()
        let tracks = try await music.tracks(in: lists[0])
        music.play(.context(uri: lists[0].uri))
        let before = try await music.playbackQueue()
        let originalCurrent = music.nowPlaying?.trackURI
        let added = tracks[5]
        try await music.enqueue(added)
        try await music.enqueue(added)
        let queued = try await music.playbackQueue()
        precondition(music.nowPlaying?.trackURI == originalCurrent, "Queueing must not interrupt playback")
        precondition(queued.upcoming.prefix(2).map(\.uri) == [added.uri, added.uri], "Duplicate requests must remain separate and in order")
        precondition(Array(queued.upcoming.dropFirst(2)) == before.upcoming, "Context must follow the explicit queue")
        music.next()
        precondition(music.nowPlaying?.trackURI == added.uri, "Next must consume the queued song")
        let afterSkip = try await music.playbackQueue()
        precondition(afterSkip.upcoming.first?.uri == added.uri, "Only one duplicate is consumed")
        try await music.enqueue(tracks[6])
        let afterAppend = try await music.playbackQueue()
        precondition(afterAppend.upcoming.prefix(2).map(\.uri) == [added.uri, tracks[6].uri], "New additions follow pending additions")
        let empty = DemoMusic()
        let initial = try await empty.playbackQueue()
        precondition(initial.current == nil && initial.upcoming.isEmpty)
        try await empty.enqueue(added)
        let inactive = try await empty.playbackQueue()
        precondition(inactive.current == nil && inactive.upcoming == [added], "Adding while inactive must not start playback")

        // Queued songs use the same direct play request as search results.
        // Do not turn Spotify's partial queue snapshot into a new track list.
        let selectedTrack = queued.upcoming[1]
        music.play(.tracks([selectedTrack.uri]))
        let selected = try await music.playbackQueue()
        precondition(selected.current?.uri == added.uri, "The selected queue song must start playing")
        precondition(music.nowPlaying?.isPaused == false)
        empty.play(.tracks([inactive.upcoming[0].uri]))
        precondition(empty.nowPlaying?.trackURI == added.uri && empty.nowPlaying?.isPaused == false, "A queued song must be playable without existing playback")
        print("Queue checks passed: order, duplicates, context, next, inactive playback, selected-song playback")
    }
}
