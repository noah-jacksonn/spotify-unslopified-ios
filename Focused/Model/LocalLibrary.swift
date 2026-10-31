import AVFoundation
import CryptoKit
import Foundation
import UIKit

struct ImportedPlaylist: Codable, Identifiable, Equatable {
    nonisolated static let legacyID = "suno"
    var id: String
    var name: String
    var showsOnHome = true
    var coverFile: String?
    var sharedCoverURL: URL?
}

struct LocalSong: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var artist: String
    var audioFile: String
    var durationMs: Int
    var createdAt: Date?
    var importedAt: Date
    var sourceURL: URL?
    var lyrics: String?
    var artworkFile: String?
    /// Older imports belong to the migrated Suno playlist.
    var playlistIDs: [String]?

    nonisolated func belongs(to playlistID: String) -> Bool {
        (playlistIDs ?? [ImportedPlaylist.legacyID]).contains(playlistID)
    }

    var sharedDirectory: URL?
    var sharedOrder: Double?

    nonisolated var directory: URL { sharedDirectory ?? LocalLibrary.directory.appending(path: id, directoryHint: .isDirectory) }
    nonisolated var audioURL: URL { directory.appending(path: audioFile) }
    var sharedArtworkRevision: String?
    nonisolated var artworkURL: URL? {
        artworkFile.map { name in
            let url = directory.appending(path: name)
            return sharedArtworkRevision.map { url.appending(queryItems: [URLQueryItem(name: "revision", value: $0)]) } ?? url
        }
    }
    var uri: String { "suno:\(id)" }
    var track: Track {
        Track(id: id, name: title, artists: artist, album: "Imported music", imageURL: artworkURL,
              durationMs: durationMs, uri: uri)
    }

    var lyricsDocument: LyricsDocument? {
        guard let lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lines = LRCParser.parse(lyrics)
        return LyricsDocument(lines: lines, plainText: lines.isEmpty ? lyrics : nil,
                              instrumental: false, sourceURL: sourceURL)
    }
}

@Observable
final class LocalLibrary {
    nonisolated static let directory = URL.applicationSupportDirectory.appending(path: "Suno", directoryHint: .isDirectory)
    private(set) var songs: [LocalSong] = []
    private(set) var error: String?
    private(set) var isImporting = false
    private(set) var playlists: [ImportedPlaylist] = []
    private var playlistsReady = false
    private static let playlistsURL = directory.appending(path: ".playlists.json")

    private(set) var sharedFolder: SharedMusicFolder?
    private(set) var refreshingFolder = false
    private var refreshAgain = false
    private var refreshingKey: UUID?

    var homePlaylists: [ImportedPlaylist] { playlists.filter(\.showsOnHome) }

    func playlist(id: String) -> ImportedPlaylist? { playlists.first { $0.id == id } }

    func songs(in playlistID: String) -> [LocalSong] { songs.filter { $0.belongs(to: playlistID) } }

    func artwork(for playlistID: String) -> Artwork {
        if let url = playlist(id: playlistID)?.sharedCoverURL { return .url(url) }
        if let coverFile = playlist(id: playlistID)?.coverFile, Self.isFilename(coverFile) {
            return .url(Self.directory.appending(path: coverFile))
        }
        return Artwork(url: songs(in: playlistID).first?.artworkURL, seed: nil)
    }

    init(loadSharedFolder: Bool = true) {
        sharedFolder = loadSharedFolder ? SharedMusicFolder.selected() : nil
        reload()
    }

    func reload() {
        if let folder = sharedFolder { refreshShared(folder); return }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: Self.directory,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var loaded: [LocalSong] = []
            var unreadable = 0
            for folder in folders {
                do {
                    let data = try Data(contentsOf: folder.appending(path: "song.json"))
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    var song = try decoder.decode(LocalSong.self, from: data)
                    guard song.id == folder.lastPathComponent,
                          Self.isFilename(song.audioFile),
                          song.artworkFile.map(Self.isFilename) ?? true,
                          FileManager.default.fileExists(atPath: song.audioURL.path) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    if song.artworkFile == nil || song.artworkFile == "gradient.jpg" {
                        let previousArtwork = song.artworkFile
                        do {
                            try Self.addFallbackArtwork(to: &song, in: folder)
                            try Self.write(song, to: folder)
                            if let previousArtwork {
                                try? FileManager.default.removeItem(at: folder.appending(path: previousArtwork))
                            }
                        } catch {
                            // Audio stays available if the cover can't be saved.
                            song.artworkFile = previousArtwork
                        }
                    }
                    loaded.append(song)
                } catch { unreadable += 1 }
            }
            songs = loaded.sorted { ($0.createdAt ?? $0.importedAt) > ($1.createdAt ?? $1.importedAt) }
            try loadPlaylists(hasLegacySongs: !folders.isEmpty)
            error = unreadable == 0 ? nil : "Couldn't read \(unreadable) imported songs. Their files are still saved."
        } catch {
            playlistsReady = false
            self.error = "Couldn't read your imported songs. \(error.localizedDescription)"
        }
    }

    func song(uri: String) -> LocalSong? { songs.first { $0.uri == uri } }

    private func loadPlaylists(hasLegacySongs: Bool) throws {
        playlistsReady = false
        if FileManager.default.fileExists(atPath: Self.playlistsURL.path) {
            let saved = try JSONDecoder().decode([ImportedPlaylist].self, from: Data(contentsOf: Self.playlistsURL))
            guard Set(saved.map(\.id)).count == saved.count,
                  saved.allSatisfy({ Self.isFilename($0.id) && ($0.coverFile.map(Self.isFilename) ?? true) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            playlists = saved
        } else {
            let savedCover = UserDefaults.standard.string(forKey: "suno.coverFile")
            let cover = savedCover.flatMap { name in
                Self.isFilename(name) && FileManager.default.fileExists(atPath: Self.directory.appending(path: name).path) ? name : nil
            }
            let migrated = hasLegacySongs || cover != nil
                ? [ImportedPlaylist(id: ImportedPlaylist.legacyID, name: "Suno", coverFile: cover)] : []
            try savePlaylists(migrated)
        }
        playlistsReady = true
    }

    private func savePlaylists(_ updated: [ImportedPlaylist]) throws {
        try JSONEncoder().encode(updated).write(to: Self.playlistsURL, options: .atomic)
        playlists = updated
    }

    func createPlaylist(name: String, cover: Data?, coverEdit: CoverEdit? = nil) throws -> ImportedPlaylist {
        if let folder = sharedFolder {
            let name = try folder.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines), cover: cover, edit: coverEdit)
            let playlist = ImportedPlaylist(id: Self.sharedID(name), name: name)
            playlists.append(playlist)
            reload()
            return playlist
        }
        guard playlistsReady else { throw CocoaError(.fileReadCorruptFile) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        var playlist = ImportedPlaylist(id: UUID().uuidString, name: trimmed)
        if let cover {
            if let coverEdit { try CoverStorage.save(jpeg: cover, edit: coverEdit, in: Self.coverEditDirectory(playlist.id)) }
            let file = ".cover-\(UUID().uuidString).jpg"
            try cover.write(to: Self.directory.appending(path: file), options: .atomic)
            playlist.coverFile = file
        }
        do { try savePlaylists(playlists + [playlist]) }
        catch {
            if let file = playlist.coverFile { try? FileManager.default.removeItem(at: Self.directory.appending(path: file)) }
            try? FileManager.default.removeItem(at: Self.coverEditDirectory(playlist.id))
            throw error
        }
        return playlist
    }

    func setShowsOnHome(_ shows: Bool, playlistID: String) throws {
        if let folder = sharedFolder {
            guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { throw CocoaError(.fileNoSuchFile) }
            UserDefaults.standard.set(!shows, forKey: Self.hiddenKey(folder, playlists[index].name))
            playlists[index].showsOnHome = shows
            return
        }
        guard playlistsReady, let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var updated = playlists
        updated[index].showsOnHome = shows
        try savePlaylists(updated)
    }

    /// Commit the playlist change first. A failed file cleanup leaves its audio
    /// recoverable, and never changes memberships in another playlist.
    func deletePlaylist(id: String) throws -> (removedSongs: Set<String>, cleanupFailures: Int) {
        if let folder = sharedFolder {
            guard let playlist = playlist(id: id) else { throw CocoaError(.fileNoSuchFile) }
            guard !isImporting else { throw ImportInProgress() }
            try folder.archive(playlist: playlist.name)
            let removed = Set(songs(in: id).map(\.id))
            playlists.removeAll { $0.id == id }
            songs.removeAll { removed.contains($0.id) }
            reload()
            return (removed, 0)
        }
        guard playlistsReady, let playlist = playlist(id: id) else { throw CocoaError(.fileNoSuchFile) }
        guard !isImporting else { throw ImportInProgress() }
        let remaining = playlists.filter { $0.id != id }
        try savePlaylists(remaining)
        let remainingIDs = Set(remaining.map(\.id))
        var removed = Set<String>()
        var failures = 0
        for var song in songs where song.belongs(to: id) {
            let memberships = (song.playlistIDs ?? [ImportedPlaylist.legacyID]).filter { remainingIDs.contains($0) }
            do {
                if memberships.isEmpty {
                    try FileManager.default.removeItem(at: song.directory)
                    removed.insert(song.id)
                } else {
                    song.playlistIDs = memberships
                    try Self.write(song, to: song.directory)
                    if let index = songs.firstIndex(where: { $0.id == song.id }) { songs[index] = song }
                }
            } catch { failures += 1 }
        }
        songs.removeAll { removed.contains($0.id) }
        if let cover = playlist.coverFile, !remaining.contains(where: { $0.coverFile == cover }) {
            do { try FileManager.default.removeItem(at: Self.directory.appending(path: cover)) }
            catch { failures += 1 }
        }
        let editDirectory = Self.coverEditDirectory(id)
        if FileManager.default.fileExists(atPath: editDirectory.path) {
            do { try FileManager.default.removeItem(at: editDirectory) }
            catch { failures += 1 }
        }
        return (removed, failures)
    }

    /// Each song is committed as one directory, so interrupted imports are retryable.
    func importAudio(_ urls: [URL], into playlistID: String) async -> (added: Int, failures: [String]) {
        guard !isImporting else { return (0, ["An import is already running."]) }
        if let folder = sharedFolder {
            guard let playlist = playlist(id: playlistID) else { return (0, ["This playlist couldn't be opened."]) }
            isImporting = true
            defer { isImporting = false; reload() }
            var added = 0
            var failures = [String]()
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let asset = AVURLAsset(url: url)
                    let seconds = try await asset.load(.duration).seconds
                    guard seconds.isFinite, seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    var info = FolderSongInfo(importedAt: Date().ISO8601Format(), durationMs: Int(seconds * 1000))
                    var art: Data?
                    for item in try await asset.load(.commonMetadata) {
                        switch item.commonKey {
                        case .commonKeyTitle: info.title = try? await item.load(.stringValue)
                        case .commonKeyArtist: info.artist = try? await item.load(.stringValue)
                        case .commonKeyCreationDate: info.createdAt = (try? await item.load(.dateValue))?.ISO8601Format()
                        case .commonKeyArtwork:
                            if let data = try? await item.load(.dataValue) {
                                art = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 900, height: 900))?.jpegData(compressionQuality: 0.85)
                            }
                        default: break
                        }
                    }
                    let name = playlist.name
                    if try await Task.detached(operation: { try folder.importFile(url, named: url.lastPathComponent, playlist: name, info: info, artwork: art) }).value { added += 1 }
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            return (added, failures)
        }
        guard playlistsReady, playlist(id: playlistID) != nil else { return (0, ["This playlist couldn't be opened."]) }
        isImporting = true
        defer { isImporting = false }
        var added = 0
        var failures: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
                let (data, id) = try await Task.detached {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    return (data, id)
                }.value
                if var existing = songs.first(where: { $0.id == id }) {
                    if !existing.belongs(to: playlistID) {
                        existing.playlistIDs = (existing.playlistIDs ?? [ImportedPlaylist.legacyID]) + [playlistID]
                        try Self.write(existing, to: existing.directory)
                        if let index = songs.firstIndex(where: { $0.id == existing.id }) { songs[index] = existing }
                        added += 1
                    }
                    continue
                }
                let staging = Self.directory.appending(path: ".import-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                let audioFile = "audio.\(url.pathExtension.lowercased())"
                try data.write(to: staging.appending(path: audioFile), options: .completeFileProtectionUntilFirstUserAuthentication)
                var song = LocalSong(id: id, title: url.deletingPathExtension().lastPathComponent,
                    artist: "Unknown artist", audioFile: audioFile, durationMs: Int(duration * 1000),
                    importedAt: Date(), playlistIDs: [playlistID])
                let metadata = try await asset.load(.commonMetadata)
                for item in metadata {
                    switch item.commonKey {
                    case .commonKeyTitle:
                        if let title = try? await item.load(.stringValue), !title.isEmpty { song.title = title }
                    case .commonKeyArtist:
                        if let artist = try? await item.load(.stringValue), !artist.isEmpty { song.artist = artist }
                    case .commonKeyCreationDate:
                        song.createdAt = try? await item.load(.dateValue)
                    case .commonKeyArtwork:
                        if let bytes = try? await item.load(.dataValue),
                           let image = UIImage(data: bytes)?.preparingThumbnail(of: CGSize(width: 900, height: 900)),
                           let jpeg = image.jpegData(compressionQuality: 0.85) {
                            try jpeg.write(to: staging.appending(path: "cover.jpg"))
                            song.artworkFile = "cover.jpg"
                        }
                    default: break
                    }
                }
                try Self.addFallbackArtwork(to: &song, in: staging)
                try Self.write(song, to: staging)
                try FileManager.default.moveItem(at: staging, to: song.directory)
                songs.append(song)
                added += 1
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        songs.sort { ($0.createdAt ?? $0.importedAt) > ($1.createdAt ?? $1.importedAt) }
        return (added, failures)
    }

    func update(_ song: LocalSong, original: LocalSong? = nil) throws {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        if let folder = sharedFolder, let name = songs[index].sharedDirectory?.lastPathComponent {
            // Merge only fields changed in this editor into the latest sidecar.
            let before = original ?? songs[index]
            try folder.edit(playlist: name, file: song.audioFile) { info in
                if song.title != before.title { info.title = song.title }
                if song.artist != before.artist { info.artist = song.artist }
                if song.lyrics != before.lyrics { info.lyrics = song.lyrics }
                if song.sourceURL != before.sourceURL { info.sourceURL = song.sourceURL?.absoluteString }
                if song.createdAt != before.createdAt { info.createdAt = song.createdAt?.ISO8601Format() }
                if song.sharedOrder != before.sharedOrder { info.order = song.sharedOrder }
            }
            songs[index] = song
            reload()
            return
        }
        var updated = song
        updated.playlistIDs = songs[index].playlistIDs
        try Self.write(updated, to: updated.directory)
        songs[index] = updated
        songs.sort { ($0.createdAt ?? $0.importedAt) > ($1.createdAt ?? $1.importedAt) }
    }

    nonisolated static func coverEditDirectory(_ playlistID: String) -> URL {
        directory.appending(path: ".cover-edits").appending(path: playlistID)
    }

    func coverEdit(for playlistID: String) throws -> CoverEdit? {
        guard let playlist = playlist(id: playlistID) else { return nil }
        if let sharedFolder {
            return try CoverStorage.load(in: sharedFolder.cache.appending(path: playlist.name))
        }
        if let edit = try CoverStorage.load(in: Self.coverEditDirectory(playlistID)) { return edit }
        guard let name = playlist.coverFile else { return nil }
        let bytes = try Data(contentsOf: Self.directory.appending(path: name))
        return CoverEdit(original: bytes, originalExtension: "jpg", preview: bytes)
    }

    func saveCover(_ jpeg: Data, for song: LocalSong? = nil, playlistID: String? = nil, edit: CoverEdit? = nil) throws {
        if let folder = sharedFolder {
            guard let name = song?.sharedDirectory?.lastPathComponent ?? playlistID.flatMap({ playlist(id: $0)?.name }) else { throw CocoaError(.fileNoSuchFile) }
            try folder.setCover(jpeg, playlist: name, file: song?.audioFile, edit: edit)
            reload()
            return
        }
        guard song != nil || (playlistsReady && playlistID.flatMap({ playlist(id: $0) }) != nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if song == nil, let playlistID, let edit {
            try CoverStorage.save(jpeg: jpeg, edit: edit, in: Self.coverEditDirectory(playlistID))
        }
        let filename = ".cover-\(UUID().uuidString).jpg"
        let folder = song?.directory ?? Self.directory
        let destination = folder.appending(path: filename)
        try jpeg.write(to: destination, options: .atomic)
        do {
            if var current = song.flatMap({ self.song(uri: $0.uri) }) {
                let old = current.artworkFile
                current.artworkFile = filename
                try update(current)
                if let old { try? FileManager.default.removeItem(at: folder.appending(path: old)) }
            } else if let index = playlists.firstIndex(where: { $0.id == playlistID }) {
                var updated = playlists
                let old = updated[index].coverFile
                updated[index].coverFile = filename
                try savePlaylists(updated)
                if let old { try? FileManager.default.removeItem(at: folder.appending(path: old)) }
            } else {
                throw CocoaError(.fileNoSuchFile)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func sharedID(_ name: String) -> String {
        name == "Suno" ? ImportedPlaylist.legacyID : "folder:" + name
    }

    private static func hiddenKey(_ folder: SharedMusicFolder, _ name: String) -> String {
        "imported.hidden.\(folder.key.uuidString).\(name)"
    }

    func connectFolder(_ url: URL) throws {
        guard !isImporting else { throw ImportInProgress() }
        let folder = try SharedMusicFolder(url: url)
        try folder.saveSelection()
        let previous = sharedFolder
        sharedFolder = folder
        discardInactiveMirror(previous)
        songs = []
        playlists = []
        reload()
    }

    func disconnectFolder() throws {
        guard !isImporting else { throw ImportInProgress() }
        SharedMusicFolder.disconnect()
        let previous = sharedFolder
        sharedFolder = nil
        discardInactiveMirror(previous)
        reload()
    }

    /// An explicit copy keeps the original private library intact. Repeating
    /// this operation skips byte-identical imports and never replaces user files.
    func copyDevicePlaylists() async throws {
        guard let folder = sharedFolder, !isImporting else { throw ImportInProgress() }
        isImporting = true
        defer { isImporting = false; reload() }
        let local = LocalLibrary(loadSharedFolder: false)
        guard local.playlistsReady else { throw MusicFolderError(local.error ?? "Couldn't read device playlists.") }
        let lists = local.playlists
        let tracks = local.songs
        // Keep the same destination when an export is retried, including when
        // private playlists share a name or contain path separators.
        let namesKey = "imported.exportNames." + folder.key.uuidString
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        var used = Set(names.values.map { $0.lowercased() })
        for playlist in lists where names[playlist.id] == nil {
            let cleaned = playlist.name.components(separatedBy: CharacterSet(charactersIn: "/\\").union(.controlCharacters))
                .joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
            let base = cleaned.isEmpty ? "Playlist" : cleaned
            var candidate = base
            var suffix = 1
            while used.contains(candidate.lowercased()) { suffix += 1; candidate = "\(base) (\(suffix))" }
            used.insert(candidate.lowercased())
            names[playlist.id] = candidate
        }
        UserDefaults.standard.set(names, forKey: namesKey)
        let savedNames = names
        let previousWarning = local.error
        try await Task.detached {
            var destinations = savedNames
            var failures = previousWarning.map { [$0] } ?? []
            for playlist in lists {
                guard var name = destinations[playlist.id] else { continue }
                do {
                    let exists = try folder.access(writing: false) { root in
                        FileManager.default.fileExists(atPath: try SharedMusicFolder.child(name, in: root).path)
                    }
                    let archived = exists ? try folder.isArchived(playlist: name) : false
                    if !exists || archived {
                        let art = try playlist.coverFile.map { try Data(contentsOf: Self.directory.appending(path: $0)) }
                        let edit = try CoverStorage.load(in: Self.coverEditDirectory(playlist.id))
                        let reserved = Set(destinations.filter { $0.key != playlist.id }.values.map { $0.lowercased() })
                        name = try folder.create(name: name, cover: art, edit: edit, avoiding: reserved)
                        destinations[playlist.id] = name
                        UserDefaults.standard.set(destinations, forKey: namesKey)
                    } else if let cover = playlist.coverFile {
                        try folder.access(writing: true) { root in
                            let dest = try SharedMusicFolder.child("cover.jpg", in: SharedMusicFolder.child(name, in: root))
                            if !SharedMusicFolder.occupied(dest) {
                                let jpeg = try Data(contentsOf: Self.directory.appending(path: cover))
                                if let edit = try CoverStorage.load(in: Self.coverEditDirectory(playlist.id)) {
                                    try CoverStorage.save(jpeg: jpeg, edit: edit, in: dest.deletingLastPathComponent())
                                } else { try jpeg.write(to: dest, options: .atomic) }
                            }
                        }
                    }
                } catch {
                    failures.append("\(playlist.name): \(error.localizedDescription)")
                    continue
                }
                for (position, song) in tracks.filter({ $0.belongs(to: playlist.id) }).enumerated() {
                    do {
                        let safe = song.title.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: "-")
                        let filename = (SharedMusicFolder.valid(safe) ? safe : song.id) + "." + song.audioURL.pathExtension
                        let info = FolderSongInfo(title: song.title, artist: song.artist, createdAt: song.createdAt?.ISO8601Format(),
                            importedAt: song.importedAt.ISO8601Format(), durationMs: song.durationMs, lyrics: song.lyrics,
                            sourceURL: song.sourceURL?.absoluteString, order: Double(position))
                        let artwork = try song.artworkURL.map { try Data(contentsOf: $0) }
                        _ = try folder.importFile(song.audioURL, named: filename, playlist: name, info: info, artwork: artwork)
                    } catch { failures.append("\(song.title): \(error.localizedDescription)") }
                }
            }
            if !failures.isEmpty {
                throw MusicFolderError("Copied available songs. \(failures.count) issues: " + failures.prefix(3).joined(separator: " · "))
            }
        }.value
    }

    private func discardInactiveMirror(_ folder: SharedMusicFolder?) {
        guard let folder, folder.key != sharedFolder?.key, folder.key != refreshingKey else { return }
        try? FileManager.default.removeItem(at: folder.cache)
    }

    private func refreshShared(_ folder: SharedMusicFolder) {
        if refreshingKey == folder.key { refreshAgain = true; return }
        refreshingKey = folder.key
        refreshAgain = false
        refreshingFolder = true
        Task {
            var warning: String?
            if songs.isEmpty, FileManager.default.fileExists(atPath: folder.cache.path),
               let cached = try? await readMirror(folder), sharedFolder == folder {
                playlists = cached.0
                songs = cached.1
            }
            do { try await Task.detached { try folder.refreshCache() }.value }
            catch { warning = "Shared folder unavailable. Showing downloaded songs. " + error.localizedDescription }
            if sharedFolder == folder {
                do {
                    let snapshot = try await readMirror(folder)
                    if sharedFolder == folder {
                        playlists = snapshot.0
                        songs = snapshot.1
                        error = warning ?? snapshot.2
                    }
                } catch { self.error = warning ?? error.localizedDescription }
            }
            guard refreshingKey == folder.key else { discardInactiveMirror(folder); return }
            refreshingKey = nil
            refreshingFolder = false
            discardInactiveMirror(folder)
            if refreshAgain { refreshAgain = false; reload() }
        }
    }

    private func readMirror(_ folder: SharedMusicFolder) async throws -> ([ImportedPlaylist], [LocalSong], String?) {
        let fm = FileManager.default
        let dirs = try fm.contentsOfDirectory(at: folder.cache, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var lists = [ImportedPlaylist]()
        var tracks = [LocalSong]()
        var issues = 0
        for dir in dirs.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = dir.lastPathComponent
            let id = Self.sharedID(name)
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var list = ImportedPlaylist(id: id, name: name, showsOnHome: !UserDefaults.standard.bool(forKey: Self.hiddenKey(folder, name)))
            if let cover = CoverStorage.renderedURL(in: dir) { list.sharedCoverURL = cover.appending(queryItems: [URLQueryItem(name: "revision", value: Self.artRevision(cover))]) }
            lists.append(list)
            for file in files where SharedMusicFolder.audioTypes.contains(file.pathExtension.lowercased()) {
                let filename = file.lastPathComponent
                let info: FolderSongInfo
                do { info = try SharedMusicFolder.readInfo(dir.appending(path: filename + ".json")) }
                catch { issues += 1; info = FolderSongInfo() }
                let seed = name + "/" + filename
                let trackID = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                var duration = info.durationMs ?? 0
                if duration <= 0, let seconds = try? await AVURLAsset(url: file).load(.duration).seconds, seconds.isFinite, seconds > 0 { duration = Int(seconds * 1000) }
                var track = LocalSong(id: trackID, title: info.displayTitle(filename: filename), artist: info.displayArtist,
                    audioFile: filename, durationMs: duration, createdAt: Self.folderDate(info.createdAt), importedAt: Self.folderDate(info.importedAt) ?? date,
                    sourceURL: info.sourceURL.flatMap(URL.init(string:)), lyrics: info.lyrics, playlistIDs: [id], sharedDirectory: dir, sharedOrder: info.order)
                if let art = info.artworkFile, SharedMusicFolder.valid(art), fm.fileExists(atPath: dir.appending(path: art).path) {
                    track.artworkFile = art
                    track.sharedArtworkRevision = Self.artRevision(dir.appending(path: art))
                } else {
                    let art = ".gradient-" + trackID + ".jpg"
                    let destination = dir.appending(path: art)
                    if !fm.fileExists(atPath: destination.path) { try Self.fallbackArtwork(seed: seed)?.write(to: destination, options: .atomic) }
                    track.artworkFile = art
                }
                tracks.append(track)
            }
        }
        tracks.sort {
            if $0.sharedOrder != $1.sharedOrder { return ($0.sharedOrder ?? .infinity) < ($1.sharedOrder ?? .infinity) }
            if $0.importedAt != $1.importedAt { return $0.importedAt > $1.importedAt }
            return $0.audioFile < $1.audioFile
        }
        return (lists, tracks, issues > 0 ? "Couldn't read details for \(issues) songs." : nil)
    }

    private static func artRevision(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values?.fileSize ?? 0)"
    }

    private static func folderDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return (try? Date(raw, strategy: .iso8601)) ?? (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    private static func write(_ song: LocalSong, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(song).write(to: folder.appending(path: "song.json"), options: .atomic)
    }

    private static func addFallbackArtwork(to song: inout LocalSong, in folder: URL) throws {
        guard song.artworkFile == nil || song.artworkFile == "gradient.jpg" else { return }
        guard let jpeg = fallbackArtwork(seed: song.id) else { throw CocoaError(.fileWriteUnknown) }
        try jpeg.write(to: folder.appending(path: "gradient-v2.jpg"), options: .atomic)
        song.artworkFile = "gradient-v2.jpg"
    }

    private static func fallbackArtwork(seed: String) -> Data? {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        let hue = CGFloat(Int(digest[0]) * 256 + Int(digest[1])) / 65536
        let shadowHue = (hue + 0.08).truncatingRemainder(dividingBy: 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { renderer in
            let context = renderer.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let colors = [
                UIColor(hue: hue, saturation: 0.3, brightness: 0.9, alpha: 1).cgColor,
                UIColor(hue: hue, saturation: 0.65, brightness: 0.62, alpha: 1).cgColor,
                UIColor(hue: shadowHue, saturation: 0.75, brightness: 0.24, alpha: 1).cgColor
            ]
            if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.48, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 560, y: 640), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            let glowColors = [UIColor(white: 1, alpha: 0.3).cgColor, UIColor(white: 1, alpha: 0).cgColor]
            if let glow = CGGradient(colorsSpace: space, colors: glowColors as CFArray, locations: [0, 1]) {
                context.drawRadialGradient(glow, startCenter: CGPoint(x: 490, y: 80), startRadius: 0,
                    endCenter: CGPoint(x: 490, y: 80), endRadius: 440, options: [])
            }
        }
        return image.jpegData(compressionQuality: 0.88)
    }

    nonisolated private static func isFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }
}

private struct ImportInProgress: LocalizedError {
    var errorDescription: String? { "Wait for the current import to finish before deleting a playlist." }
}
