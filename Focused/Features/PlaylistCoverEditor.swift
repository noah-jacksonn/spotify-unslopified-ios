import SwiftUI
import PhotosUI
import ImageIO

extension View {
    func playlistCoverEditor(_ playlist: Binding<Playlist?>) -> some View {
        modifier(PlaylistCoverEditorPresentation(playlist: playlist))
    }
}

private struct PlaylistCoverEditorPresentation: ViewModifier {
    @Binding var playlist: Playlist?
    @Environment(\.look) private var look

    func body(content: Content) -> some View {
        content.sheet(item: $playlist) { target in
            PlaylistCoverEditor(playlist: target)
                .environment(\.look, look)
        }
    }
}

private struct PlaylistCoverEditor: View {
    let playlist: Playlist
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var crop = PlaylistCoverCrop()
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var translation = CGSize.zero

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(playlist.name)
                        .font(look.font(18, .semibold))
                        .foregroundStyle(look.palette.text)
                    GeometryReader { geometry in
                        let side = geometry.size.width
                        if let image {
                            let active = activeCrop(side: side)
                            let rect = active.imageRect(imageSize: image.size, side: side)
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .frame(width: side, height: side)
                                .clipped()
                                .contentShape(Rectangle())
                                .gesture(
                                    MagnifyGesture()
                                        .updating($magnification) { value, state, _ in state = value.magnification }
                                        .onEnded { value in
                                            crop.zoom *= value.magnification
                                            crop = crop.constrained(imageSize: image.size)
                                        }
                                )
                                .simultaneousGesture(
                                    DragGesture()
                                        .updating($translation) { value, state, _ in state = value.translation }
                                        .onEnded { value in
                                            crop.x += value.translation.width / side
                                            crop.y += value.translation.height / side
                                            crop = crop.constrained(imageSize: image.size)
                                        }
                                )
                                .accessibilityLabel("Cover crop preview")
                                .accessibilityHint("Pinch to zoom and drag to position. Crop controls are below.")
                        } else {
                            ArtworkView(artwork: model.artwork(for: playlist))
                                .frame(width: side, height: side)
                                .clipped()
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if loading || saving { ProgressView().padding(16).glassEffect() }
                    }
                    .allowsHitTesting(!loading && !saving)

                    if image != nil {
                        Text("Pinch to zoom · Drag to position")
                            .font(look.font(14))
                            .foregroundStyle(look.palette.muted)
                        HStack {
                            Image(systemName: "minus.magnifyingglass")
                            Slider(value: $crop.zoom, in: 1...6)
                                .accessibilityLabel("Zoom")
                                .onChange(of: crop.zoom) { _, _ in
                                    if let image { crop = crop.constrained(imageSize: image.size) }
                                }
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .foregroundStyle(look.palette.muted)
                        .disabled(loading || saving)
                        HStack(spacing: 24) {
                            cropButton("Move left", symbol: "arrow.left", x: -0.05, y: 0)
                            cropButton("Move right", symbol: "arrow.right", x: 0.05, y: 0)
                            cropButton("Move up", symbol: "arrow.up", x: 0, y: -0.05)
                            cropButton("Move down", symbol: "arrow.down", x: 0, y: 0.05)
                            Button("Reset") { crop = PlaylistCoverCrop() }
                        }
                        .font(look.font(14))
                        .disabled(loading || saving)
                    }
                    PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                        Label(image == nil ? "Choose photo" : "Choose another photo", systemImage: "photo")
                            .font(look.font(16, .medium))
                    }
                    .disabled(loading || saving)
                    if let error {
                        Text(error)
                            .font(look.font(14))
                            .foregroundStyle(look.palette.text)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .padding(look.margin)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .pageBackground()
            .navigationTitle("Change cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.mode == .preview ? "Save preview" : "Save to Spotify") { save() }
                        .disabled(image == nil || loading || saving)
                }
            }
            .tint(look.palette.accent)
            .interactiveDismissDisabled(saving)
            .task(id: selection) { await loadSelection() }
        }
    }

    private func activeCrop(side: CGFloat) -> PlaylistCoverCrop {
        PlaylistCoverCrop(zoom: crop.zoom * magnification,
                          x: crop.x + translation.width / side,
                          y: crop.y + translation.height / side)
    }

    private func cropButton(_ label: String, symbol: String, x: CGFloat, y: CGFloat) -> some View {
        Button {
            guard let image else { return }
            crop.x += x
            crop.y += y
            crop = crop.constrained(imageSize: image.size)
        } label: {
            Image(systemName: symbol).frame(minWidth: 28, minHeight: 44)
        }
        .accessibilityLabel(label)
    }

    private func loadSelection() async {
        guard let selection else { return }
        loading = true
        error = nil
        do {
            guard let data = try await selection.loadTransferable(type: Data.self) else {
                throw CoverImageError.unreadable
            }
            let decoded = try await Task.detached(priority: .userInitiated) {
                try PlaylistCoverImage.decode(data)
            }.value
            try Task.checkCancellation()
            image = decoded
            crop = PlaylistCoverCrop()
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn't load this photo. Try another image or download it from iCloud first."
            loading = false
        }
    }

    private func save() {
        guard let image, !saving, !loading else { return }
        saving = true
        error = nil
        let crop = crop
        let session = model.auth.sessionID
        let mode = model.mode
        Task {
            do {
                let jpeg = try await Task.detached(priority: .userInitiated) {
                    try PlaylistCoverImage.jpeg(image, crop: crop)
                }.value
                guard model.auth.sessionID == session, model.mode == mode else { throw CancellationError() }
                try await model.updateCover(jpeg, for: playlist)
                dismiss()
            } catch {
                self.error = "Couldn't save the cover. \(error.localizedDescription)"
            }
            saving = false
        }
    }
}

private enum CoverImageError: LocalizedError {
    case unreadable, tooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: "This image couldn't be opened."
        case .tooLarge: "This image couldn't be made small enough. Try a different photo."
        }
    }
}

private nonisolated enum PlaylistCoverImage {
    static func decode(_ data: Data) throws -> UIImage {
        // Decode a bounded thumbnail directly, including HEIC orientation.
        // Never inflate the full 48MP original just to show a small crop editor.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw CoverImageError.unreadable }
        return UIImage(cgImage: cgImage)
    }

    static func jpeg(_ image: UIImage, crop: PlaylistCoverCrop) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // 640px matches Spotify's large covers. The original photo stays intact.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format)
        let rendered = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
            image.draw(in: crop.imageRect(imageSize: image.size, side: 640))
        }
        for quality in [0.92, 0.85, 0.75, 0.65, 0.5, 0.35] {
            if let data = rendered.jpegData(compressionQuality: quality),
               data.base64EncodedData().count <= 256_000 { return data }
        }
        throw CoverImageError.tooLarge
    }
}
