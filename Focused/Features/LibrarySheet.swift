import SwiftUI

/// Every saved playlist, with + / ✓ to choose what shows on Home. Opens on
/// "By you" each time, like the extension's library drawer.
struct LibrarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .mine
    @State private var query = ""
    @State private var deleting: Playlist?
    @State private var editingCover: Playlist?
    @State private var path = NavigationPath()
    @State private var showsCreatePlaylist = false
    @State private var pendingPlaylist: ImportedPlaylistRoute?

    enum Filter: String, CaseIterable { case mine = "By you", imported = "Imported", all = "All", others = "By others" }

    var body: some View {
        let visible = visible
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: look.gap * 0.7) {
                    filters
                    if filter == .imported {
                        createPlaylistButton
                        SharedFolderControls()
                    }
                    ForEach(visibleImported) { playlist in
                        ImportedPlaylistLibraryRow(playlist: playlist)
                    }
                    ForEach(visible) { playlist in row(playlist) }
                    if visible.isEmpty && visibleImported.isEmpty {
                        if model.libraryState == .loading && filter != .imported {
                            BarsLoader().frame(maxWidth: .infinity).padding(.top, 40)
                        } else if filter != .imported || !query.isEmpty {
                            Text("No playlists here")
                                .font(look.font(15))
                                .foregroundStyle(look.palette.muted)
                                .padding(.top, 20)
                        }
                    }
                }
                .padding(.horizontal, look.margin)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter playlists")
            .navigationTitle("All playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CloseToolbarItem { dismiss() }
            }
            .pageBackground()
            .appDestinations()
        }
        .songAlbumNavigation(path: $path)
        .playerBar()
        .deletePlaylistConfirmation($deleting)
        .playlistCoverEditor($editingCover)
        .presentationBackground(look.palette.background)
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-openImportedLibrary") { filter = .imported }
        }
        #endif
        .sheet(isPresented: $showsCreatePlaylist, onDismiss: {
            if let pendingPlaylist { path.append(pendingPlaylist) }
            pendingPlaylist = nil
        }) {
            CreateImportedPlaylistView { pendingPlaylist = ImportedPlaylistRoute(id: $0.id) }
                .environment(\.look, look)
        }
    }

    private var visibleImported: [ImportedPlaylist] {
        guard filter != .others else { return [] }
        return model.localLibrary.playlists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var visible: [Playlist] {
        model.playlists.filter { playlist in
            switch filter {
            case .mine: playlist.isMine
            case .imported: false
            case .others: !playlist.isMine
            case .all: true
            }
        }
        .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { option in
                    let selected = option == filter
                    Button { filter = option } label: {
                        Text(option.rawValue)
                            .font(look.font(14, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? look.palette.onAccent : look.palette.text)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(selected ? look.palette.accent : look.palette.raised, in: Capsule())
                    }
                    .buttonStyle(PressScale())
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var createPlaylistButton: some View {
        Button { showsCreatePlaylist = true } label: {
            Label("Create playlist", systemImage: "plus")
                .font(look.font(16, .medium))
                .foregroundStyle(look.palette.text)
                .frame(maxWidth: .infinity, minHeight: 50)
                .surface(look, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScale())
        .padding(.vertical, 8)
    }

    /// Tapping the row opens the playlist (songs, Play); only the small
    /// + / ✓ changes what's on Home (Noah, 2026-10-02).
    private func row(_ playlist: Playlist) -> some View {
        let chosen = model.home.contains(playlist)
        return HStack(spacing: 10) {
            NavigationLink(value: playlist) {
                HStack(spacing: 14) {
                    ArtworkView(artwork: model.artwork(for: playlist))
                        .frame(width: 56, height: 56)
                        .artClip(look, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(playlist.name).font(look.font(16, .medium)).foregroundStyle(look.palette.text).lineLimit(1)
                        Text(playlist.isMine ? (playlist.trackCount.map { "\($0) songs" } ?? "") : playlist.ownerName)
                            .font(look.font(13)).foregroundStyle(look.palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if playlist.isMine {
                    Button("Add to queue", systemImage: "text.badge.plus") { model.enqueue(playlist) }
                }
                if playlist.isOwned {
                    Button("Change cover", systemImage: "photo") { editingCover = playlist }
                }
                Button(playlist.isOwned ? "Delete playlist" : "Remove from library", systemImage: "trash", role: .destructive) {
                    deleting = playlist
                }
            }

            Button {
                withAnimation(look.animation) { model.home.toggle(playlist) }
            } label: {
                Image(systemName: chosen ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(chosen ? look.palette.onAccent : look.palette.text)
                    .frame(width: 26, height: 26)
                    .background(chosen ? look.palette.accent : look.palette.raised, in: Circle())
                    // Small to look at, still a comfortable tap target.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .sensoryFeedback(.selection, trigger: chosen)
            .accessibilityLabel(chosen ? "Remove \(playlist.name) from Home" : "Show \(playlist.name) on Home")
        }
    }
}

private struct ImportedPlaylistLibraryRow: View {
    let playlist: ImportedPlaylist
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: ImportedPlaylistRoute(id: playlist.id)) {
                HStack(spacing: 14) {
                    ArtworkView(artwork: model.localLibrary.artwork(for: playlist.id))
                        .frame(width: 56, height: 56).artClip(look, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(playlist.name).font(look.font(16, .medium)).foregroundStyle(look.palette.text).lineLimit(1)
                        Text("\(model.localLibrary.songs(in: playlist.id).count) songs")
                            .font(look.font(13)).foregroundStyle(look.palette.muted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .importedPlaylistActions(playlist)
            Button {
                do { try model.localLibrary.setShowsOnHome(!playlist.showsOnHome, playlistID: playlist.id) }
                catch { model.show(error.localizedDescription) }
            } label: {
                Image(systemName: playlist.showsOnHome ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(playlist.showsOnHome ? look.palette.onAccent : look.palette.text)
                    .frame(width: 26, height: 26)
                    .background(playlist.showsOnHome ? look.palette.accent : look.palette.raised, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(playlist.showsOnHome ? "Hide \(playlist.name) from Home" : "Show \(playlist.name) on Home")
        }
    }
}

extension View {
    /// Asks before deleting `playlist` (set it to show the dialog). Says
    /// "Delete" for your own playlists and "Remove" for others', since
    /// Spotify only removes those from your library.
    func deletePlaylistConfirmation(_ playlist: Binding<Playlist?>) -> some View {
        modifier(DeletePlaylistConfirmation(playlist: playlist))
    }
}

private struct DeletePlaylistConfirmation: ViewModifier {
    @Binding var playlist: Playlist?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            playlist.map { $0.isOwned ? "Delete “\($0.name)”?" : "Remove “\($0.name)” from your library?" } ?? "",
            isPresented: Binding(get: { playlist != nil }, set: { if !$0 { playlist = nil } }),
            titleVisibility: .visible,
            presenting: playlist
        ) { target in
            Button(target.isOwned ? "Delete playlist" : "Remove from library", role: .destructive) {
                Task { await model.delete(target) }
            }
        } message: { target in
            Text(target.isOwned
                 ? "It's deleted from your Spotify library. Spotify can restore it from your account page for 90 days."
                 : "It stays on Spotify; it just leaves your library.")
        }
    }
}
