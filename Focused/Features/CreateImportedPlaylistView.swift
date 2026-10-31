import SwiftUI
import PhotosUI

struct CreateImportedPlaylistView: View {
    var onCreate: (ImportedPlaylist) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cover: Data?
    @State private var coverEdit: CoverEdit?
    @State private var coverID = UUID().uuidString
    @State private var editsCover = false
    @State private var selection: PhotosPickerItem?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var artwork: Artwork { cover == nil ? .none : .image(id: coverID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Playlist name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("importedPlaylist.name")
                    if cover == nil {
                        PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) { coverLabel }
                    } else {
                        Button { selection = nil; editsCover = true } label: { coverLabel }
                    }
                } footer: {
                    if let folder = model.localLibrary.sharedFolder {
                        Text("Saves to \(folder.name).")
                    } else {
                        Text("Connect an iCloud folder to sync with Chrome.")
                    }
                }
                if let error { Text(error).foregroundStyle(look.palette.muted) }
            }
            .navigationTitle("Create playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("importedPlaylist.create")
                }
            }
            .onChange(of: selection) { _, item in
                if item != nil { editsCover = true }
            }
            .sheet(isPresented: $editsCover, onDismiss: { selection = nil }) {
                CoverEditor(title: name.isEmpty ? "New playlist" : name, artwork: artwork, initialSelection: selection, initialEdit: coverEdit) { jpeg, edit in
                    let id = UUID().uuidString
                    if let image = UIImage(data: jpeg) { ImageCache.shared.store(image, id: id) }
                    coverID = id
                    cover = jpeg
                    coverEdit = edit
                }
                .environment(\.look, look)
            }
            .onAppear { nameFocused = true }
        }
    }

    private var coverLabel: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: artwork).frame(width: 56, height: 56).artClip(look, size: 56)
            Text(cover == nil ? "Choose cover" : "Change cover")
        }
    }

    private func create() {
        do {
            let playlist = try model.localLibrary.createPlaylist(name: name, cover: cover, coverEdit: coverEdit)
            dismiss()
            onCreate(playlist)
        } catch { self.error = "Couldn't create the playlist. \(error.localizedDescription)" }
    }
}
