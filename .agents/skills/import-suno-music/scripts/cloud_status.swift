import Foundation

// Read-only. Uploaded from this Mac does not establish receipt on another device.
var rows: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    do {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey])
        rows.append(["file": url.lastPathComponent,
                     "icloud": values.isUbiquitousItem ?? false,
                     "uploaded": values.ubiquitousItemIsUploaded ?? false,
                     "uploading": values.ubiquitousItemIsUploading ?? false,
                     "error": values.ubiquitousItemUploadingError?.localizedDescription ?? ""])
    } catch {
        rows.append(["file": url.lastPathComponent, "error": error.localizedDescription])
    }
}
let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
