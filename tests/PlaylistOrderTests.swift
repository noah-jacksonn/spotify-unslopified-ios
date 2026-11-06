import Foundation

@main
struct PlaylistOrderTests {
    static func main() {
        let scope = "test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "playlistOrder.\(scope)") }
        let order = PlaylistOrder(scope: scope)
        let items = ["spotify:a", "imported:b", "spotify:c"]
        precondition(order.move(items[2], to: items[0], among: items))
        precondition(order.sorted(items, id: { $0 }) == [items[2],items[0],items[1]])
        let restored = PlaylistOrder(scope: scope)
        precondition(restored.ids == order.ids, "Order survives relaunch")
        precondition(restored.move(items[1], to: items[2], among: [items[2],items[1]]))
        precondition(restored.ids == [items[1],items[0],items[2]], "Filtered moves preserve hidden playlists")
        precondition(!restored.move("missing", to: items[0], among: items))
        precondition(restored.sorted(items + ["new"], id: { $0 }).last == "new")
        print("Playlist ordering passed: mixed sources, relaunch, filtered moves, new playlists")
    }
}
