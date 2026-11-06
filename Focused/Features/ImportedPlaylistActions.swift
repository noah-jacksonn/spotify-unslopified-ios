import SwiftUI

extension View {
    func importedPlaylistActions(_ playlist: ImportedPlaylist) -> some View {
        modifier(ImportedPlaylistActions(playlist: playlist))
    }
}

private struct ImportedPlaylistActions: ViewModifier {
    let playlist: ImportedPlaylist
    @Environment(AppModel.self) private var model
    @State private var confirmsDeletion = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(playlist.showsOnHome ? "Hide from Home" : "Show on Home",
                       systemImage: playlist.showsOnHome ? "eye.slash" : "eye") {
                    do { try model.localLibrary.setShowsOnHome(!playlist.showsOnHome, playlistID: playlist.id) }
                    catch { model.show(error.localizedDescription) }
                }
                Button("Delete playlist", systemImage: "trash", role: .destructive) { confirmsDeletion = true }
            }
            .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
                Button("Delete playlist", role: .destructive) { model.deleteImportedPlaylist(playlist) }
            } message: {
                Text(model.localLibrary.sharedFolder != nil
                     ? "This playlist will be archived on all connected devices. Its files will stay in the shared folder."
                     : "Songs used only by this playlist will also be removed from the app. Songs in other imported playlists will stay.")
            }
    }
}
