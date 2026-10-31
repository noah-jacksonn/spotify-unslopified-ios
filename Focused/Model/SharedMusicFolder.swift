import Foundation

/// Portable folder format, also read by the Chrome extension. The directory
/// and audio filenames are authoritative; sidecars are optional.
nonisolated struct FolderSongInfo: Codable {
    var title: String?
    var artist: String?
    var createdAt: String?
    var importedAt: String?
    var durationMs: Int?
    var lyrics: String?
    var sourceURL: String?
    var artworkFile: String?
    var order: Double?

    func displayTitle(filename: String) -> String { Self.nonempty(title) ?? (filename as NSString).deletingPathExtension }
    var displayArtist: String { Self.nonempty(artist) ?? "Unknown artist" }
    private static func nonempty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

nonisolated struct MusicFolderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated struct SharedMusicFolder: Codable, Equatable {
    private(set) var bookmark: Data
    let key: UUID
    let name: String
    private static let setting = "imported.sharedMusicFolder"
    private static let fm = FileManager.default
    static let audioTypes: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "mp4", "caf"]
    var cache: URL { URL.applicationSupportDirectory.appending(path: "SharedMusic/\(key.uuidString)") }

    static func selected() -> Self? {
        UserDefaults.standard.data(forKey: setting).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    func saveSelection() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.setting)
    }
    static func disconnect() { UserDefaults.standard.removeObject(forKey: setting) }

    init(url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw MusicFolderError("Choose the main folder containing your playlists.")
        }
        bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        if let previous = Self.selected(), (try? previous.access(writing: false) { $0.standardizedFileURL == url.standardizedFileURL }) == true {
            key = previous.key
        } else { key = UUID() }
        name = url.lastPathComponent
    }

    static func valid(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") &&
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// Coordinate access with Files/iCloud. Never redirect failed shared writes into local storage.
    func access<T>(writing: Bool, _ body: @escaping (URL) throws -> T) throws -> T {
        var stale = false
        let saved = Self.selected()
        let currentBookmark = saved?.key == key ? (saved?.bookmark ?? bookmark) : bookmark
        let root = try URL(resolvingBookmarkData: currentBookmark, options: [.withoutUI],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        if stale, saved?.key == key {
            var renewed = self
            renewed.bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            try renewed.saveSelection()
        }
        let coordinator = NSFileCoordinator()
        var failure: NSError?
        var result: Result<T, Error>?
        let perform: (URL) -> Void = { url in result = Result { try body(url) } }
        if writing {
            coordinator.coordinate(writingItemAt: root, options: .forMerging, error: &failure, byAccessor: perform)
        } else {
            coordinator.coordinate(readingItemAt: root, options: [], error: &failure, byAccessor: perform)
        }
        if let failure { throw failure }
        guard let result else { throw MusicFolderError("The shared music folder is unavailable. Reconnect it in All playlists.") }
        return try result.get()
    }

    static func child(_ name: String, in folder: URL) throws -> URL {
        guard valid(name) else { throw MusicFolderError("Choose a simple file or playlist name.") }
        let url = folder.appending(path: name)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw MusicFolderError("Links outside the music folder are unsupported.")
        }
        return url
    }

    func isArchived(playlist: String) throws -> Bool {
        try access(writing: false) { root in
            Self.occupied(try Self.child("Unslopified.archive.json", in: Self.child(playlist, in: root)))
        }
    }

    @discardableResult
    func create(name: String, cover: Data?, edit: CoverEdit? = nil, avoiding reserved: Set<String> = []) throws -> String {
        try access(writing: true) { root in
            var chosen = name
            var folder = try Self.child(chosen, in: root)
            // A new playlist must never silently restore archived songs.
            if Self.occupied(try Self.child("Unslopified.archive.json", in: folder)) {
                var suffix = 2
                repeat {
                    chosen = "\(name) (\(suffix))"
                    folder = try Self.child(chosen, in: root)
                    suffix += 1
                } while Self.occupied(folder) || reserved.contains(chosen.lowercased())
            }
            try Self.fm.createDirectory(at: folder, withIntermediateDirectories: false)
            do {
                if let cover, let edit { try CoverStorage.save(jpeg: cover, edit: edit, in: folder) }
                else if let cover { try cover.write(to: folder.appending(path: "cover.jpg"), options: .atomic) }
            }
            catch { try? Self.fm.removeItem(at: folder); throw error }
            return chosen
        }
    }

    func archive(playlist: String) throws {
        try access(writing: true) { root in
            let folder = try Self.child(playlist, in: root)
            let marker = try Self.child("Unslopified.archive.json", in: folder)
            try Data(#"{"archived":true}"#.utf8).write(to: marker, options: .atomic)
        }
    }

    func importFile(_ source: URL, named preferredName: String, playlist: String,
                    info: FolderSongInfo, artwork: Data?) throws -> Bool {
        let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
        return try access(writing: true) { root in
            let folder = try Self.child(playlist, in: root)
            guard Self.audioTypes.contains((preferredName as NSString).pathExtension.lowercased()) else {
                throw MusicFolderError("Unsupported audio format.")
            }
            let existing = try Self.fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            for item in existing where Self.audioTypes.contains(item.pathExtension.lowercased()) {
                let values = try item.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .ubiquitousItemDownloadingStatusKey])
                if values.isSymbolicLink != true, values.fileSize == bytes.count,
                   values.ubiquitousItemDownloadingStatus != .notDownloaded,
                   try Data(contentsOf: item, options: .mappedIfSafe) == bytes { return false }
            }
            var filename = preferredName
            var destination = try Self.child(filename, in: folder)
            var suffix = 1
            while Self.occupied(destination) || Self.occupied(folder.appending(path: filename + ".json")) || Self.occupied(folder.appending(path: filename + ".cover.jpg")) {
                suffix += 1
                let path = preferredName as NSString
                filename = "\(path.deletingPathExtension) (\(suffix)).\(path.pathExtension)"
                destination = try Self.child(filename, in: folder)
            }
            let staging = folder.appending(path: ".import-" + UUID().uuidString)
            defer { try? Self.fm.removeItem(at: staging) }
            try bytes.write(to: staging, options: .atomic)
            var metadata = info
            if let artwork {
                let artName = filename + ".cover.jpg"
                try artwork.write(to: Self.child(artName, in: folder), options: .atomic)
                metadata.artworkFile = artName
            }
            try JSONEncoder().encode(metadata).write(to: Self.child(filename + ".json", in: folder), options: .atomic)
            try Self.fm.moveItem(at: staging, to: destination)
            return true
        }
    }

    func edit(playlist: String, file: String, _ change: @escaping (inout FolderSongInfo) throws -> Void) throws {
        try access(writing: true) { root in
            let folder = try Self.child(playlist, in: root)
            let audio = try Self.child(file, in: folder)
            guard Self.fm.fileExists(atPath: audio.path) else { throw CocoaError(.fileNoSuchFile) }
            let sidecar = try Self.child(file + ".json", in: folder)
            var info = try Self.readInfo(sidecar)
            try change(&info)
            try JSONEncoder().encode(info).write(to: sidecar, options: .atomic)
        }
    }

    func setCover(_ data: Data, playlist: String, file: String? = nil, edit: CoverEdit? = nil) throws {
        try access(writing: true) { root in
            let folder = try Self.child(playlist, in: root)
            let name = file.map { $0 + ".cover.jpg" } ?? "cover.jpg"
            if file == nil, let edit { try CoverStorage.save(jpeg: data, edit: edit, in: folder) }
            else { try data.write(to: Self.child(name, in: folder), options: .atomic) }
            if let file {
                let sidecar = try Self.child(file + ".json", in: folder)
                var info = try Self.readInfo(sidecar)
                info.artworkFile = name
                try JSONEncoder().encode(info).write(to: sidecar, options: .atomic)
            }
        }
    }

    static func occupied(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path) ||
            fm.fileExists(atPath: url.deletingLastPathComponent().appending(path: "." + url.lastPathComponent + ".icloud").path)
    }

    static func readInfo(_ url: URL) throws -> FolderSongInfo {
        guard fm.fileExists(atPath: url.path) else {
            let placeholder = url.deletingLastPathComponent().appending(path: "." + url.lastPathComponent + ".icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try fm.startDownloadingUbiquitousItem(at: url)
                throw MusicFolderError("Song details are downloading from iCloud. Try again shortly.")
            }
            return FolderSongInfo()
        }
        return try JSONDecoder().decode(FolderSongInfo.self, from: Data(contentsOf: url))
    }

    /// Copy changed files into a device-only mirror for offline playback. A
    /// failed listing never removes cached tracks. Cloud placeholders keep their
    /// cached counterpart while the provider downloads the current version.
    func refreshCache() throws {
        try access(writing: false) { root in
            try Self.fm.createDirectory(at: cache, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var cachedDirectory = cache
            try cachedDirectory.setResourceValues(values)
            let folders = try Self.fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var present = Set<String>()
            for folder in folders {
                let name = folder.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    let pending = String(name.dropFirst().dropLast(7))
                    guard Self.valid(pending) else { continue }
                    present.insert(pending)
                    try? Self.fm.startDownloadingUbiquitousItem(at: root.appending(path: pending))
                    continue
                }
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .ubiquitousItemDownloadingStatusKey])
                guard Self.valid(name), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let marker = try Self.child("Unslopified.archive.json", in: folder)
                if Self.fm.fileExists(atPath: marker.path) ||
                    Self.fm.fileExists(atPath: folder.appending(path: ".Unslopified.archive.json.icloud").path) { continue }
                present.insert(name)
                if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try Self.fm.startDownloadingUbiquitousItem(at: folder)
                    continue
                }
                let local = cache.appending(path: name)
                try Self.fm.createDirectory(at: local, withIntermediateDirectories: true)
                let files = try Self.fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                var seen = Set<String>()
                for file in files {
                    var name = file.lastPathComponent
                    if name.hasPrefix("."), name.hasSuffix(".icloud") {
                        name = String(name.dropFirst().dropLast(7))
                        seen.insert(name)
                        try? Self.fm.startDownloadingUbiquitousItem(at: folder.appending(path: name))
                        continue
                    }
                    guard Self.valid(name), name.hasPrefix("cover-original-") || Self.audioTypes.contains(file.pathExtension.lowercased()) ||
                        ["json", "jpg", "jpeg", "png", "webp"].contains(file.pathExtension.lowercased()) else { continue }
                    let props = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey])
                    guard props.isRegularFile == true, props.isSymbolicLink != true else { continue }
                    seen.insert(name)
                    if props.ubiquitousItemDownloadingStatus == .notDownloaded {
                        try Self.fm.startDownloadingUbiquitousItem(at: file)
                        continue
                    }
                    let dest = local.appending(path: name)
                    let old = try? dest.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    if old == nil || old?.fileSize != props.fileSize || old?.contentModificationDate != props.contentModificationDate {
                        try Data(contentsOf: file, options: .mappedIfSafe).write(to: dest, options: .atomic)
                        if let date = props.contentModificationDate { try Self.fm.setAttributes([.modificationDate: date], ofItemAtPath: dest.path) }
                    }
                }
                try Self.prune(local, keeping: seen)
            }
            try Self.prune(cache, keeping: present)
        }
    }

    private static func prune(_ directory: URL, keeping names: Set<String>) throws {
        for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            where !names.contains(item.lastPathComponent) {
            try fm.removeItem(at: item)
        }
    }
}
