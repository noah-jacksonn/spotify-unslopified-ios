import SwiftUI

struct PlaylistView: View {
    var playlist: Playlist
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var entries: [Entry] = []
    @State private var state: LoadState = .loading

    private enum LoadState: Equatable { case loading, loaded, unavailable, failed(String) }

    /// A playlist can hold the same song twice, so rows get their own ids.
    private struct Entry: Identifiable {
        let id = UUID()
        var track: Track
    }

    private var tracks: [Track] { entries.map(\.track) }

    /// A plain List (styled like the rest of the app) rather than a
    /// ScrollView, because swipe actions only exist on List rows.
    var body: some View {
        ScrollViewReader { proxy in
            List {
                Group {
                    header.padding(.bottom, look.gap * 0.6)
                    switch state {
                    case .loading:
                        BarsLoader().frame(maxWidth: .infinity, minHeight: 120)
                    case .unavailable:
                        note("Spotify only shares the song list for playlists you own. Play works as usual.")
                    case .failed(let message):
                        note(message)
                    case .loaded:
                        ForEach(entries) { entry in row(entry.track) }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: look.margin, bottom: 0, trailing: look.margin))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .scrollIndicators(.hidden)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .pageBackground()
            .task {
                await load()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-playlistBottom"), let last = entries.last {
                    // Reproduce the last-row/mini-player layout without changing
                    // saved preferences or requiring manual scrolling.
                    await Task.yield()
                    proxy.scrollTo(last.id, anchor: .bottom)
                    try? await Task.sleep(for: .milliseconds(500))
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                #endif
            }
        }
    }

    private var isOnHome: Bool { model.home.contains(playlist) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderCover(artwork: Artwork(url: playlist.imageURL, seed: playlist.demoSeed))
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    Text(playlist.name)
                        .font(look.display(32))
                        .tracking(look.titleTracking)
                        .foregroundStyle(look.palette.text)
                    // Home lists library playlists only, so the toggle is
                    // hidden for one opened from search and not saved.
                    if model.isInLibrary(playlist) { homeButton }
                }
                // The library's count, which tracks adds and removals.
                Text([playlist.ownerName, (model.playlists.first { $0.id == playlist.id } ?? playlist).trackCount.map { "\($0) songs" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(look.font(14))
                    .foregroundStyle(look.palette.muted)
            }
            ContextPlayControls(contextURI: playlist.uri, tracks: tracks)
                .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    /// Quiet Home toggle beside the title (Noah, 2026-10-02: the filled
    /// circle in the button row was far too prominent). ⊕ adds, ✓ removes.
    private var homeButton: some View {
        Button {
            withAnimation(look.animation) { model.home.toggle(playlist) }
        } label: {
            Image(systemName: isOnHome ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 20, weight: .regular))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(look.palette.muted)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .sensoryFeedback(.selection, trigger: isOnHome)
        .accessibilityLabel(isOnHome ? "Remove from Home" : "Show on Home")
    }


    /// Swipe right queues; removal stays on the opposite edge and in the menu.
    private func row(_ track: Track) -> some View {
        TrackRow(track: track, swipeToQueue: false, onRemove: { remove(track) }) {
            model.music?.play(.context(uri: playlist.uri, startAt: track.uri, position: track.position))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Queue", systemImage: "text.badge.plus") { model.enqueue([track]) }
                .tint(look.palette.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { remove(track) } label: {
                Label("Remove", systemImage: "trash")
            }
            // The app-wide accent tint would otherwise paint it blue.
            .tint(.red)
        }
        .accessibilityHint("Swipe right to queue")
    }

    /// Removes right away and puts the song back if Spotify refuses.
    /// Spotify removes every copy of the song, so every copy goes here too.
    private func remove(_ track: Track) {
        let removed = entries.enumerated().filter { $0.element.track.uri == track.uri }
        let positions = removed.compactMap(\.element.track.position)
        withAnimation(look.animation) { entries.removeAll { $0.track.uri == track.uri } }
        // Spotify closes the gap, so later songs move up; their positions
        // must follow or tapping one would play its neighbor.
        closeGaps(at: positions)
        Task {
            if await !model.remove(track, from: playlist, copies: removed.count) {
                reopenGaps(at: positions)
                // Put back only these rows, where they were, so removals
                // that succeeded meanwhile stay removed.
                withAnimation(look.animation) {
                    for (index, entry) in removed {
                        entries.insert(entry, at: min(index, entries.count))
                    }
                }
            }
        }
    }

    /// Each remaining song moves up one per removed position before it.
    private func closeGaps(at removed: [Int]) {
        for index in entries.indices {
            guard let position = entries[index].track.position else { continue }
            entries[index].track.position = position - removed.filter { $0 < position }.count
        }
    }

    /// Undoes `closeGaps`: re-inserts the positions lowest first, each
    /// pushing everything at or after it down one.
    private func reopenGaps(at removed: [Int]) {
        for gap in removed.sorted() {
            for index in entries.indices {
                if let position = entries[index].track.position, position >= gap {
                    entries[index].track.position = position + 1
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(look.font(15))
            .foregroundStyle(look.palette.muted)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(look, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func load() async {
        guard let music = model.music else { return }
        guard playlist.isMine else {
            state = .unavailable
            return
        }
        do {
            entries = try await music.tracks(in: playlist).map { Entry(track: $0) }
            state = .loaded
        } catch let error as SpotifyAPI.APIError where error.status == 403 || error.status == 404 {
            state = .unavailable
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
