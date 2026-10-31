import AVFoundation
import CryptoKit
import Foundation
import UIKit

struct ImportedPlaylist: Codable, Identifiable, Equatable {
    static let legacyID = "suno"
    var id: String
    var name: String
    var showsOnHome = true
    var coverFile: String?
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

    func belongs(to playlistID: String) -> Bool {
        (playlistIDs ?? [ImportedPlaylist.legacyID]).contains(playlistID)
    }

    var directory: URL { LocalLibrary.directory.appending(path: id, directoryHint: .isDirectory) }
    var audioURL: URL { directory.appending(path: audioFile) }
    var artworkURL: URL? { artworkFile.map { directory.appending(path: $0) } }
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
    static let directory = URL.applicationSupportDirectory.appending(path: "Suno", directoryHint: .isDirectory)
    private(set) var songs: [LocalSong] = []
    private(set) var error: String?
    private(set) var isImporting = false
    private(set) var playlists: [ImportedPlaylist] = []
    private var playlistsReady = false
    private static let playlistsURL = directory.appending(path: ".playlists.json")

    var homePlaylists: [ImportedPlaylist] { playlists.filter(\.showsOnHome) }

    func playlist(id: String) -> ImportedPlaylist? { playlists.first { $0.id == id } }

    func songs(in playlistID: String) -> [LocalSong] { songs.filter { $0.belongs(to: playlistID) } }

    func artwork(for playlistID: String) -> Artwork {
        if let coverFile = playlist(id: playlistID)?.coverFile, Self.isFilename(coverFile) {
            return .url(Self.directory.appending(path: coverFile))
        }
        return Artwork(url: songs(in: playlistID).first?.artworkURL, seed: nil)
    }

    init() { reload() }

    func reload() {
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

    func createPlaylist(name: String, cover: Data?) throws -> ImportedPlaylist {
        guard playlistsReady else { throw CocoaError(.fileReadCorruptFile) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        var playlist = ImportedPlaylist(id: UUID().uuidString, name: trimmed)
        if let cover {
            let file = ".cover-\(UUID().uuidString).jpg"
            try cover.write(to: Self.directory.appending(path: file), options: .atomic)
            playlist.coverFile = file
        }
        do { try savePlaylists(playlists + [playlist]) }
        catch {
            if let file = playlist.coverFile { try? FileManager.default.removeItem(at: Self.directory.appending(path: file)) }
            throw error
        }
        return playlist
    }

    func setShowsOnHome(_ shows: Bool, playlistID: String) throws {
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
        return (removed, failures)
    }

    /// Each song is committed as one directory, so interrupted imports are retryable.
    func importAudio(_ urls: [URL], into playlistID: String) async -> (added: Int, failures: [String]) {
        guard !isImporting else { return (0, ["An import is already running."]) }
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

    func update(_ song: LocalSong) throws {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        var updated = song
        updated.playlistIDs = songs[index].playlistIDs
        try Self.write(updated, to: updated.directory)
        songs[index] = updated
        songs.sort { ($0.createdAt ?? $0.importedAt) > ($1.createdAt ?? $1.importedAt) }
    }

    func saveCover(_ jpeg: Data, for song: LocalSong? = nil, playlistID: String? = nil) throws {
        guard song != nil || (playlistsReady && playlistID.flatMap({ playlist(id: $0) }) != nil) else {
            throw CocoaError(.fileNoSuchFile)
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
