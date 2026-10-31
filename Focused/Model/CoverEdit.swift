import Foundation
import CryptoKit

/// Shared with Chrome. Pan offsets are fractions of the square viewport.
nonisolated struct CoverCropSettings: Codable, Equatable, Sendable {
    var zoom: Double = 1
    var x: Double = 0
    var y: Double = 0
    var isValid: Bool { zoom.isFinite && (1...6).contains(zoom) && x.isFinite && y.isFinite }
}

nonisolated struct CoverRecipe: Codable, Sendable {
    var version = 1
    let originalFile: String
    let previewFile: String
    let renderedFile: String
    let crop: CoverCropSettings

    var isValid: Bool {
        version == 1 && crop.isValid &&
        Self.asset(originalFile, prefix: "cover-original-") &&
        Self.asset(previewFile, prefix: "cover-source-") &&
        Self.asset(renderedFile, prefix: "cover-rendered-")
    }

    private static func asset(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && !name.contains("/") && !name.contains("\\") &&
        !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

nonisolated struct CoverEdit: Sendable {
    /// Untouched selected bytes; preview is an oriented, uncropped JPEG for both platforms.
    let original: Data
    let originalExtension: String
    let preview: Data
    var crop = CoverCropSettings()
}

nonisolated enum CoverStorage {
    static func load(in directory: URL) throws -> CoverEdit? {
        let recipeURL = directory.appending(path: "cover.json")
        if FileManager.default.fileExists(atPath: recipeURL.path) {
            let recipe = try JSONDecoder().decode(CoverRecipe.self, from: Data(contentsOf: recipeURL))
            guard recipe.isValid else { throw CocoaError(.fileReadCorruptFile) }
            return CoverEdit(original: try read(recipe.originalFile, in: directory),
                             originalExtension: (recipe.originalFile as NSString).pathExtension,
                             preview: try read(recipe.previewFile, in: directory), crop: recipe.crop)
        }
        // Older covers remain editable, within the pixels that were previously saved.
        let cover = directory.appending(path: "cover.jpg")
        guard FileManager.default.fileExists(atPath: cover.path) else { return nil }
        let data = try Data(contentsOf: cover)
        return CoverEdit(original: data, originalExtension: "jpg", preview: data)
    }

    static func renderedURL(in directory: URL) -> URL? {
        if let data = try? Data(contentsOf: directory.appending(path: "cover.json")),
           let recipe = try? JSONDecoder().decode(CoverRecipe.self, from: data), recipe.isValid,
           let url = try? safeURL(recipe.renderedFile, in: directory),
           FileManager.default.fileExists(atPath: url.path) { return url }
        let legacy = directory.appending(path: "cover.jpg")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    static func save(jpeg: Data, edit: CoverEdit, in directory: URL) throws {
        guard edit.crop.isValid else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = edit.originalExtension.lowercased()
        let safeExtension = ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "gif", "tif", "tiff", "bmp"].contains(ext) ? ext : "bin"
        let originalFile = "cover-original-\(hash(edit.original)).\(safeExtension)"
        let previewFile = "cover-source-\(hash(edit.preview)).jpg"
        let renderedFile = "cover-rendered-\(hash(jpeg)).jpg"
        for (name, bytes) in [(originalFile, edit.original), (previewFile, edit.preview), (renderedFile, jpeg)] {
            let url = try safeURL(name, in: directory)
            if !FileManager.default.fileExists(atPath: url.path) { try bytes.write(to: url, options: .atomic) }
        }
        // Immutable assets first, recipe last: remote readers never mix two photos.
        try jpeg.write(to: safeURL("cover.jpg", in: directory), options: .atomic)
        let recipe = CoverRecipe(originalFile: originalFile, previewFile: previewFile, renderedFile: renderedFile, crop: edit.crop)
        try JSONEncoder().encode(recipe).write(to: safeURL("cover.json", in: directory), options: .atomic)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func read(_ name: String, in directory: URL) throws -> Data {
        try Data(contentsOf: safeURL(name, in: directory), options: .mappedIfSafe)
    }
    private static func safeURL(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        guard !name.contains("/"), !name.contains("\\"),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return url
    }
}
