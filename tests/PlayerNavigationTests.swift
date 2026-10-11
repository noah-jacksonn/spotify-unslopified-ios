import Foundation

@main
struct PlayerNavigationTests {
    @MainActor static func main() async throws {
        let album = CatalogItem.spotifyAlbum(uri: "spotify:album:release", name: "Recording", artist: "Artist")!
        precondition(album.id == "release" && album.kind == .album)
        precondition(CatalogItem.spotifyAlbum(uri: "spotify:playlist:release", name: "Wrong", artist: "Artist") == nil)
        precondition(CatalogItem.spotifyAlbum(uri: "spotify:album:", name: "Missing", artist: "Artist") == nil)

        let music = DemoMusic()
        let playlists = try await music.loadPlaylists()
        let tracks = try await music.tracks(in: playlists[0])
        precondition(tracks.allSatisfy { $0.albumItem?.name == $0.album && $0.albumItem?.kind == .album },
                     "Every preview song should expose its album to the song menu")
        music.play(.context(uri: playlists[0].uri))
        let playing = music.nowPlaying!
        let destination = playing.albumItem!
        precondition(destination.name == playing.album && destination.kind == .album)
        let queue = try await music.playbackQueue()
        precondition(queue.current?.albumItem == destination)
        precondition(queue.upcoming.allSatisfy { $0.albumItem != nil }, "Queue songs keep their album destination")
        let search = try await music.search(tracks[0].name)
        precondition(!search.tracks.isEmpty && search.tracks.allSatisfy { $0.albumItem?.name == $0.album },
                     "Search results keep each recording's album destination")
        let page = try await music.albumPage(destination)
        precondition(page.album == destination)
        precondition(page.tracks.allSatisfy { $0.albumItem == destination })
        var sparseAlbum = destination
        sparseAlbum.name = ""
        sparseAlbum.imageURL = nil
        sparseAlbum.demoSeed = nil
        let hydratedPage = try await music.albumPage(sparseAlbum)
        precondition(hydratedPage.album == destination,
                     "An album route without cover/title must hydrate from the loaded album")
        music.play(.context(uri: destination.uri, startAt: page.tracks[2].uri, position: 2))
        precondition(music.nowPlaying?.trackURI == page.tracks[2].uri)
        precondition(music.nowPlaying?.albumItem == destination, "Keep the exact album while playing its songs")

        let oldTrack = Data(#"{"id":"old","name":"Song","artists":"Artist","album":"Album","durationMs":1000,"uri":"spotify:track:old","artistIDs":[],"artistNames":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(Track.self, from: oldTrack)
        precondition(decoded.albumItem == nil, "Previously cached Discover editions must still decode")
        print("Player navigation checks passed: exact album, song menus, queue, search, preview playback, legacy cache")
    }
}
