import SwiftUI

/// Search results, shown in place of Home's playlists while Home is in
/// search mode. Empty until you type: no recents, no browse categories.
struct SearchResultsView: View {
    var query: String
    @Binding var isLoading: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var results = SearchResults()
    /// The text `results` answers. While typing, the old results stay up and
    /// "Nothing found" waits until a search for the current text comes back
    /// empty, so it never flashes mid-word.
    @State private var resultsQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: look.gap * 1.6) {
            if !results.tracks.isEmpty { songs }
            if !results.artists.isEmpty { ReleaseShelf(title: "Artists", releases: results.artists, size: 128, circle: true) }
            if !results.albums.isEmpty { ReleaseShelf(title: "Albums", releases: results.albums, size: 128) }
            if !results.playlists.isEmpty { playlists }
            if results.isEmpty && !trimmed.isEmpty && resultsQuery == trimmed {
                Text("Nothing found for “\(query)”")
                    .font(look.font(15))
                    .foregroundStyle(look.palette.muted)
                    .padding(.horizontal, look.margin)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: query) { await search() }
    }

    private var songs: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Songs")
            ForEach(results.tracks) { track in
                TrackRow(track: track, showsAddMenu: true) {
                    model.music?.play(.tracks([track.uri]))
                }
            }
        }
        .padding(.horizontal, look.margin)
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Playlists")
            ForEach(results.playlists) { item in
                // CatalogPage turns it into a Playlist, keeping library info.
                NavigationLink(value: item) {
                    HStack(spacing: 12) {
                        ArtworkView(artwork: Artwork(url: item.imageURL, seed: item.demoSeed))
                            .frame(width: 52, height: 52)
                            .artClip(look, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(look.font(16, .medium)).foregroundStyle(look.palette.text).lineLimit(1)
                            Text(item.subtitle).font(look.font(13)).foregroundStyle(look.palette.muted).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, look.margin)
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private func search() async {
        let text = trimmed
        guard !text.isEmpty, let music = model.music else {
            results = SearchResults()
            resultsQuery = ""
            isLoading = false
            return
        }
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let found = try await music.search(text)
            guard !Task.isCancelled else { return }
            withAnimation(look.animation) {
                results = found
                resultsQuery = text
            }
        } catch {
            if !Task.isCancelled { model.show(error.localizedDescription) }
        }
    }
}

/// The search pill: transparent with a quiet outline, like the extension's.
/// Its outline shares a matched-geometry id with Home's search button, so
/// the button stretches into the field.
struct SearchField: View {
    @Binding var query: String
    var isLoading: Bool
    var focused: FocusState<Bool>.Binding
    var namespace: Namespace.ID
    @Environment(\.look) private var look

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(look.palette.muted)
                .matchedGeometryEffect(id: "search.icon", in: namespace)
            TextField("Songs, artists, albums", text: $query)
                .font(look.font(17))
                .foregroundStyle(look.palette.text)
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if isLoading {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(look.palette.muted)
                }
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background {
            Capsule()
                .fill(look.palette.surface.opacity(0.5))
                .overlay(Capsule().stroke(look.palette.line, lineWidth: look.hairline))
                .matchedGeometryEffect(id: "search.shape", in: namespace)
        }
    }
}

/// A + beside a song: lists the playlists you can edit (yours and
/// collaborative ones) and adds the song to the one you pick. Turns into a
/// ✓ for a moment once added, so the confirmation sits where the tap was.
struct AddToPlaylistMenu: View {
    enum Style { case compact, quiet }

    var track: Track
    var style: Style = .compact
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var justAdded = false

    var body: some View {
        Menu {
            Section("Add to playlist") {
                ForEach(model.playlists.filter(\.isMine)) { playlist in
                    Button(playlist.name) {
                        Task { await add(to: playlist) }
                    }
                }
            }
        } label: {
            switch style {
            case .compact:
                Image(systemName: justAdded ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(look.palette.text)
                    .frame(width: 26, height: 26)
                    .background(look.palette.raised, in: Circle())
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            case .quiet:
                // Matches the playlist page's Home toggle beside its title.
                Image(systemName: justAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 26, weight: .regular))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(look.palette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .sensoryFeedback(.success, trigger: justAdded) { _, new in new }
        .accessibilityLabel(justAdded ? "Added" : "Add \(track.name) to a playlist")
    }

    private func add(to playlist: Playlist) async {
        guard await model.add(track, to: playlist) else { return }
        withAnimation(look.animation) { justAdded = true }
        try? await Task.sleep(for: .seconds(2))
        withAnimation(look.animation) { justAdded = false }
    }
}
