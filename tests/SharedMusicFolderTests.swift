import Foundation

@main
struct SharedMusicFolderTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appending(path: UUID().uuidString)
        let root = temp.appending(path: "Music")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let library = try SharedMusicFolder(url: root)
        defer { try? fm.removeItem(at: library.cache) }
        try library.create(name: "Suno", cover: nil)
        let source = temp.appending(path: "Song.mp3")
        let info = FolderSongInfo(title: "Song title", lyrics: "[00:00.00]Line", order: 1)
        let blankInfo = FolderSongInfo(title: "  ", artist: "\n")
        precondition(blankInfo.displayTitle(filename: "Song.mp3") == "Song" && blankInfo.displayArtist == "Unknown artist")
        try Data([1, 2, 3]).write(to: source)
        let first = try library.importFile(source, named: "Song.mp3", playlist: "Suno", info: info, artwork: nil)
        let retry = try library.importFile(source, named: "Song.mp3", playlist: "Suno", info: info, artwork: nil)
        let renamedRetry = try library.importFile(source, named: "Renamed.mp3", playlist: "Suno", info: info, artwork: nil)
        precondition(first && !retry && !renamedRetry)
        try Data([4, 5, 6]).write(to: source)
        let collision = try library.importFile(source, named: "Song.mp3", playlist: "Suno", info: info, artwork: nil)
        precondition(collision)
        let folder = root.appending(path: "Suno")
        let original = try Data(contentsOf: folder.appending(path: "Song.mp3"))
        let alternate = try Data(contentsOf: folder.appending(path: "Song (2).mp3"))
        precondition(original == Data([1, 2, 3]) && alternate == Data([4, 5, 6]))
        try library.edit(playlist: "Suno", file: "Song.mp3") { $0.artist = "Singer" }
        let updated = try SharedMusicFolder.readInfo(folder.appending(path: "Song.mp3.json"))
        precondition(updated.artist == "Singer" && updated.order == 1 && updated.lyrics == info.lyrics)
        try library.refreshCache()
        let cached = library.cache.appending(path: "Suno/Song.mp3")
        precondition(fm.fileExists(atPath: cached.path))
        let sourcePhoto = Data([10, 20, 30, 40])
        let previewPhoto = Data([1, 3, 5])
        let crop = CoverCropSettings(zoom: 2.5, x: -0.3, y: 0.2)
        let coverEdit = CoverEdit(original: sourcePhoto, originalExtension: "heic", preview: previewPhoto, crop: crop)
        try library.setCover(Data([7, 8]), playlist: "Suno", edit: coverEdit)
        try library.refreshCache()
        let reopened = try CoverStorage.load(in: library.cache.appending(path: "Suno"))!
        precondition(reopened.original == sourcePhoto && reopened.preview == previewPhoto && reopened.crop == crop)
        precondition(reopened.originalExtension == "heic", "Keep the untouched original, including its format")
        try library.setCover(Data([9, 10]), playlist: "Suno", edit: coverEdit)
        let assets = try fm.contentsOfDirectory(atPath: folder.path)
        precondition(assets.filter { $0.hasPrefix("cover-original-") }.count == 1, "Recropping reuses the original")
        // A delayed legacy cover.jpg must not override the recipe's matching render.
        try Data([99]).write(to: folder.appending(path: "cover.jpg"))
        let rendered = try Data(contentsOf: CoverStorage.renderedURL(in: folder)!)
        precondition(rendered == Data([9, 10]))
        let recipeURL = folder.appending(path: "cover.json")
        let recipeData = try Data(contentsOf: recipeURL)
        let recipe = try JSONDecoder().decode(CoverRecipe.self, from: recipeData)
        precondition(recipe.isValid)
        let bad = CoverRecipe(originalFile: "cover-original-../../outside", previewFile: recipe.previewFile,
                              renderedFile: recipe.renderedFile, crop: crop)
        precondition(!bad.isValid, "A shared recipe cannot read outside the playlist")
        try JSONEncoder().encode(bad).write(to: recipeURL)
        do { _ = try CoverStorage.load(in: folder); fatalError("Accepted unsafe recipe") }
        catch {}
        try recipeData.write(to: recipeURL)
        for name in ["../outside", ".hidden", "nested/song"] {
            do { try library.create(name: name, cover: nil); fatalError("Accepted unsafe name") }
            catch is MusicFolderError {}
        }
        let alias = root.appending(path: "Alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: temp)
        do { try library.setCover(Data([1]), playlist: "Alias"); fatalError("Followed a link outside the root") }
        catch is MusicFolderError {}
        try library.archive(playlist: "Suno")
        try library.refreshCache()
        precondition(!fm.fileExists(atPath: cached.path))
        precondition(fm.fileExists(atPath: folder.appending(path: "Song.mp3").path))
        let archived = try library.isArchived(playlist: "Suno")
        precondition(archived)
        let recreated = try library.create(name: "Suno", cover: nil, avoiding: ["suno (2)"])
        precondition(recreated == "Suno (3)", "Archived-name fallback must avoid other device playlists' reserved export names")
        precondition(!fm.fileExists(atPath: root.appending(path: "Suno (2)").path))
        print("Shared folder tests passed")
    }
}
