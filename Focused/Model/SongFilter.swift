import Foundation

enum SongFilter: Equatable, Codable {
    case all
    case latest(Int)
    case days(Int)
    case dates(Date, Date)

    static func load(for playlistID: String, defaults: UserDefaults = .standard) -> SongFilter {
        guard let data = defaults.data(forKey: storageKey(playlistID)),
              let saved = try? JSONDecoder().decode(SongFilter.self, from: data),
              saved.isValid else { return .all }
        return saved
    }

    func save(for playlistID: String, defaults: UserDefaults = .standard) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey(playlistID))
    }

    private static func storageKey(_ playlistID: String) -> String { "songFilter.imported.\(playlistID)" }

    private var isValid: Bool {
        switch self {
        case .all: true
        case .latest(let count): count > 0
        case .days(let count): [7, 30, 90].contains(count)
        case .dates(let from, let through): from <= through
        }
    }

    var label: String {
        switch self {
        case .all: "All songs"
        case .latest(let count): "Latest \(count)"
        case .days(7): "Past week"
        case .days(let count): "Past \(count) days"
        case .dates: "Custom dates"
        }
    }

    func apply<T>(_ songs: [T], now: Date = Date(), calendar: Calendar = .current,
                  created: (T) -> Date?, imported: (T) -> Date?) -> [T] {
        let newestFirst = songs.enumerated().sorted {
            let left = created($0.element) ?? imported($0.element) ?? .distantPast
            let right = created($1.element) ?? imported($1.element) ?? .distantPast
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
        let from: Date
        let through: Date
        switch self {
        case .all: return newestFirst
        case .latest(let count):
            return Array(newestFirst.prefix(max(0, count)))
        case .days(let count):
            through = calendar.startOfDay(for: now)
            from = calendar.date(byAdding: .day, value: -(count - 1), to: through) ?? through
        case .dates(let start, let end):
            from = start
            through = end
        }
        let start = calendar.startOfDay(for: from)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through)) ?? through
        return newestFirst.filter { song in
            guard let date = created(song) else { return false }
            return date >= start && date < end
        }
    }
}
