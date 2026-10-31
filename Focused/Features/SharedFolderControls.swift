import SwiftUI
import UniformTypeIdentifiers

struct SharedFolderControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var choosing = false
    private var library: LocalLibrary { model.localLibrary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let folder = library.sharedFolder {
                HStack {
                    Label(folder.name, systemImage: "folder")
                    Spacer()
                    if library.refreshingFolder { ProgressView() }
                    Menu {
                        Button("Refresh library", systemImage: "arrow.clockwise") { library.reload() }
                        Button("Copy device playlists here", systemImage: "square.on.square") {
                            Task {
                                do { try await library.copyDevicePlaylists(); model.show("Device playlists copied") }
                                catch { model.show(error.localizedDescription) }
                            }
                        }
                        Button("Choose another folder", systemImage: "folder") { choosing = true }
                        Button("Disconnect folder", systemImage: "eject") {
                            do {
                                try library.disconnectFolder()
                                (model.music as? CombinedMusic)?.stopLocalPlayback()
                            } catch { model.show(error.localizedDescription) }
                        }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("Shared folder options")
                    .disabled(library.isImporting)
                }
            } else {
                Button { choosing = true } label: { Label("Connect music folder", systemImage: "folder.badge.plus") }
            }
            if let error = library.error { Text(error).font(look.font(13)) }
        }
        .font(look.font(15, .medium))
        .foregroundStyle(look.palette.muted)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            do {
                try library.connectFolder(result.get())
                (model.music as? CombinedMusic)?.stopLocalPlayback()
            } catch { model.show(error.localizedDescription) }
        }
        .onAppear { if library.sharedFolder != nil { library.reload() } }
    }
}
