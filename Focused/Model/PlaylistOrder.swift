import Foundation
import Observation

/// One local order shared by Home and All playlists, including future Home picks.
/// Spotify and the shared music folder stay untouched.
@Observable
final class PlaylistOrder {
    private(set) var ids: [String]
    private let key: String

    init(scope: String) {
        key = "playlistOrder.\(scope)"
        ids = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func sorted<T>(_ items: [T], id: (T) -> String) -> [T] {
        let ranks = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return items.enumerated().sorted {
            (ranks[id($0.element)] ?? ids.count + $0.offset) < (ranks[id($1.element)] ?? ids.count + $1.offset)
        }.map(\.element)
    }

    @discardableResult
    func move(_ source: String, to target: String, among visible: [String]) -> Bool {
        guard source != target, let from = visible.firstIndex(of: source),
              let to = visible.firstIndex(of: target) else { return false }
        var order = visible
        order.remove(at: from)
        order.insert(source, at: to)
        // Keep hidden entries, so filtering a library never loses its saved order.
        let visibleSet = Set(visible)
        var iterator = order.makeIterator()
        let existing = ids + visible.filter { !ids.contains($0) }
        ids = existing.map { visibleSet.contains($0) ? iterator.next() ?? $0 : $0 }
        UserDefaults.standard.set(ids, forKey: key)
        return true
    }
}
