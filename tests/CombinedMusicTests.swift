import Foundation

// In-memory boundaries for testing the real router without files or audio hardware.
struct LocalSong {
    var id: String
    var uri: String { "suno:\(id)" }
    var track: Track {
        Track(id: id, name: id, artists: "Local", album: "Imported music", durationMs: 60_000, uri: uri)
    }
}

final class LocalLibrary {
    var songs: [LocalSong] = []
    func song(uri: String) -> LocalSong? { songs.first { $0.uri == uri } }
    func reload() {}
}

final class LocalPlayback {
    var onNotice: ((Notice) -> Void)?
    var nowPlaying: NowPlaying?
    var queue: [LocalSong] = []
    var index = 0
    var failsNextPlay = false
    func play(_ songs: [LocalSong], startAt: Int = 0) throws {
        if failsNextPlay { failsNextPlay = false; throw URLError(.cannotOpenFile) }
        precondition(songs.indices.contains(startAt))
        queue = songs
        index = startAt
        let song = songs[startAt]
        nowPlaying = NowPlaying(title: song.id, artist: "Local", album: "Imported music", artwork: .none,
            trackURI: song.uri, isPaused: false, positionMs: 0, durationMs: 60_000, updatedAt: Date())
    }
    func stop() { queue = []; nowPlaying = nil }
    func togglePause() { nowPlaying?.isPaused.toggle() }
    func next() {}
    func previous() {}
    func seek(toMs: Int) {}
    func refresh(songs: [LocalSong]) {}
    func enqueue(_ song: LocalSong) throws { queue.append(song) }
}

@main
struct CombinedMusicTests {
    @MainActor static func main() async throws {
        let remote = DemoMusic()
        let library = LocalLibrary()
        library.songs = [LocalSong(id: "a"), LocalSong(id: "b"), LocalSong(id: "c")]
        let music = CombinedMusic(remote: remote, library: library)
        var sourceChanges = 0
        music.onSourceChanged = { sourceChanges += 1 }
        let playlists = try await remote.loadPlaylists()
        let tracks = try await remote.tracks(in: playlists[0])
        music.play(.tracks([tracks[0].uri]))
        precondition(!music.usesLocalPlayback && music.nowPlaying?.trackURI == tracks[0].uri)
        do {
            try await music.enqueue(library.songs[0].track)
            preconditionFailure("Local additions must not enter Spotify's queue")
        } catch {}

        music.local.failsNextPlay = true
        music.play(.tracks(["suno:a"]))
        precondition(!music.usesLocalPlayback && remote.nowPlaying?.isPaused == false,
                     "A failed local start must leave remote playback running")
        music.play(.context(uri: "suno:library", position: 50))
        precondition(!music.usesLocalPlayback && remote.nowPlaying?.isPaused == false,
                     "An invalid local position must leave remote playback running")

        music.play(.tracks(["suno:a", "suno:b", "suno:b", "suno:c"]))
        precondition(music.usesLocalPlayback && remote.nowPlaying?.isPaused == true)
        precondition(sourceChanges == 1)
        music.playQueuedSong(at: 2, uri: "suno:b")
        precondition(music.local.index == 2, "Select the exact duplicate occurrence")
        precondition(music.local.queue.map(\.uri) == ["suno:a", "suno:b", "suno:b", "suno:c"],
                     "Selecting a queued song preserves later songs and previous-song history")
        let queue = try await music.playbackQueue()
        precondition(queue.current?.uri == "suno:b" && queue.upcoming.map(\.uri) == ["suno:c"])
        music.playQueuedSong(at: -1, uri: "suno:b")
        music.playQueuedSong(at: 50, uri: "suno:b")
        music.playQueuedSong(at: 3, uri: "suno:b")
        precondition(music.local.index == 2, "Ignore stale or invalid queue offsets")
        try await music.enqueue(library.songs[0].track)
        let appended = try await music.playbackQueue()
        precondition(appended.upcoming.map(\.uri) == ["suno:c", "suno:a"])
        do {
            try await music.enqueue(tracks[0])
            preconditionFailure("Spotify additions must not enter the local queue")
        } catch {}
        music.local.stop()
        do {
            try await music.enqueue(library.songs[0].track)
            preconditionFailure("Queueing after deleting the playing playlist must not start audio")
        } catch {}
        precondition(music.nowPlaying == nil && music.local.queue.isEmpty)

        music.stopLocalPlayback()
        precondition(!music.usesLocalPlayback && sourceChanges == 2,
                     "Deleting a playing imported playlist must restore the remote source")
        try await music.enqueue(tracks[1])
        music.play(.tracks([tracks[1].uri]))
        precondition(music.nowPlaying?.trackURI == tracks[1].uri)
        music.endSession()
        precondition(remote.nowPlaying?.isPaused == true)
        print("Combined music checks passed: source switching, failed starts, isolated queues, duplicate selection, queue retention, deletion recovery, session cleanup")
    }
}
