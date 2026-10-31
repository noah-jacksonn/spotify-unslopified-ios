import SwiftUI

extension View {
    func importedPlaylistActions(_ playlist: ImportedPlaylist) -> some View {
        modifier(ImportedPlaylistActions(playlist: playlist))
    }
}

private struct ImportedPlaylistActions: ViewModifier {
    let playlist: ImportedPlaylist
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var showsActions = false
    @State private var confirmsDeletion = false

    func body(content: Content) -> some View {
        content
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in showsActions = true })
            .accessibilityAction(named: "Playlist actions") { showsActions = true }
            .popover(isPresented: $showsActions, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                VStack(spacing: 0) {
                    Button {
                        do { try model.localLibrary.setShowsOnHome(!playlist.showsOnHome, playlistID: playlist.id) }
                        catch { model.show(error.localizedDescription) }
                        showsActions = false
                    } label: {
                        Label(playlist.showsOnHome ? "Hide from Home" : "Show on Home",
                              systemImage: playlist.showsOnHome ? "eye.slash" : "eye")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    Divider()
                    Button(role: .destructive) { confirmsDeletion = true } label: {
                        Label("Delete playlist", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
                .font(look.font(16))
                .buttonStyle(.plain)
                .frame(width: 230)
                .presentationCompactAdaptation(.popover)
                .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
                    Button("Delete playlist", role: .destructive) {
                        showsActions = false
                        model.deleteImportedPlaylist(playlist)
                    }
                } message: {
                    Text("Songs used only by this playlist will also be removed from the app. Songs in other imported playlists will stay.")
                }
            }
    }
}
