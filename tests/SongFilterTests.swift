import Foundation

@main
struct SongFilterTests {
    struct Song { let id: Int; let created: Date?; var imported: Date? = nil }
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        let songs = [Song(id: 0, created: date(10, 30)), Song(id: 1, created: date(10, 31)),
                     Song(id: 2, created: date(11, 6, 23)), Song(id: 3, created: date(11, 7)),
                     Song(id: 4, created: nil, imported: date(11, 8))]
        func ids(_ filter: SongFilter) -> [Int] {
            filter.apply(songs, now: date(11, 6), calendar: calendar, created: \.created, imported: \.imported).map(\.id)
        }
        precondition(ids(.all) == [4,3,2,1,0], "All songs defaults to newest first")
        precondition(ids(.latest(2)) == [4,3], "Use import date when creation date is missing")
        precondition(ids(.days(7)) == [2,1], "Calendar days cross DST and exclude future/unknown creation dates")
        precondition(ids(.dates(date(10, 1), date(11, 6))) == [2,1,0], "Date ranges stay newest first")
        let tied = [Song(id: 0, created: nil), Song(id: 1, created: date(11, 6)),
                    Song(id: 2, created: date(11, 6)), Song(id: 3, created: nil)]
        precondition(SongFilter.all.apply(tied, created: \.created, imported: \.imported).map(\.id) == [1,2,0,3],
                     "Equal and missing dates preserve source order, with unknown dates last")
        precondition(ids(.dates(date(11,6),date(11,6))) == [2], "Include the entire final day")
        let suite = "SongFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for selection: SongFilter in [.all, .latest(5), .latest(10), .latest(23), .days(7), .days(30), .days(90), .dates(date(10, 1), date(11, 6))] {
            selection.save(for: "first", defaults: defaults)
            let reopened = UserDefaults(suiteName: suite)!
            precondition(SongFilter.load(for: "first", defaults: reopened) == selection, "Restore every selection after reopening")
            precondition(SongFilter.load(for: "second", defaults: reopened) == .all, "Keep playlist selections independent")
        }
        SongFilter.latest(10).save(for: "second", defaults: defaults)
        SongFilter.all.save(for: "first", defaults: defaults)
        precondition(SongFilter.load(for: "first", defaults: defaults) == .all)
        precondition(SongFilter.load(for: "second", defaults: defaults) == .latest(10))
        defaults.set(Data("invalid".utf8), forKey: "songFilter.imported.first")
        precondition(SongFilter.load(for: "first", defaults: defaults) == .all, "Invalid saved data falls back safely")
        print("Song filters passed: recency, date boundaries, persisted selections, playlist isolation, invalid saved data")
    }
}
