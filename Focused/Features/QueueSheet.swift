import SwiftUI

/// Spotify owns this queue, including tracks added from another device.
struct QueueSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var queue: PlaybackQueue?
    @State private var localQueueIndex: Int?
    @State private var error: String?
    @State private var loading = false
    @State private var refreshPending = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let current = queue?.current {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: "Now playing")
                            queueRow(current, isCurrent: true)
                        }
                    }
                    if let queue, !queue.upcoming.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: "Next up")
                            // A song may appear more than once; identify occurrences.
                            ForEach(Array(queue.upcoming.enumerated()), id: \.offset) { offset, track in
                                queueRow(track, upcomingOffset: offset)
                            }
                        }
                    } else if queue == nil && error == nil {
                        BarsLoader().frame(maxWidth: .infinity, minHeight: 160)
                    }
                    if let error {
                        Text(error).font(look.font(15)).foregroundStyle(look.palette.muted)
                        Button("Try again") { Task { await refresh() } }
                    }
                    if model.pendingQueueRequests > 0 {
                        HStack { BarsLoader(size: 16, delay: .zero); Text("Adding to queue…").font(look.font(14)) }
                    }
                    if showsSpotifyMessage && !isEmptyQueue { spotifyMessage }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(look.margin)
            }
            .overlay {
                if showsSpotifyMessage && isEmptyQueue {
                    spotifyMessage.padding(look.margin)
                }
            }
            .refreshable { await refresh() }
            .pageBackground()
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CloseToolbarItem { dismiss() }
            }
            .appDestinations()
        }
        .songAlbumNavigation(path: $path)
        .playerBar(isCovered: path.isEmpty)
        .presentationBackground(look.palette.background)
        .task {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if scenePhase == .active { await refresh() }
            }
        }
        .onChange(of: model.queueRevision) { Task { await refresh() } }
        .onChange(of: model.music?.nowPlaying?.trackURI) { Task { await refresh() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private var isEmptyQueue: Bool {
        queue?.current == nil && queue?.upcoming.isEmpty == true
            && error == nil && model.pendingQueueRequests == 0
    }

    private var showsSpotifyMessage: Bool {
        queue != nil && (model.music as? CombinedMusic)?.usesLocalPlayback != true
    }

    private var spotifyMessage: some View {
        Text("To reorder or remove songs, open the queue in Spotify.")
            .font(look.font(12))
            .foregroundStyle(look.palette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func queueRow(_ track: Track, isCurrent: Bool = false, upcomingOffset: Int? = nil) -> some View {
        HStack(spacing: 12) {
            Button {
                play(track, isCurrent: isCurrent, upcomingOffset: upcomingOffset)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(artwork: Artwork(url: track.imageURL, seed: track.demoSeed))
                        .frame(width: 48, height: 48).artClip(look, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.name).font(look.font(16, .medium)).foregroundStyle(look.palette.text).lineLimit(2)
                        Text(track.artists).font(look.font(13)).foregroundStyle(look.palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.name) by \(track.artists)")
            AddToPlaylistMenu(track: track)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .songContextMenu(track, play: { play(track, isCurrent: isCurrent, upcomingOffset: upcomingOffset) })
        // In a queue, swiping implies removing this occurrence. Spotify
        // doesn't expose removal, so don't reuse the browse-row add gesture.
    }

    private func play(_ track: Track, isCurrent: Bool, upcomingOffset: Int?) {
        guard let music = model.music else { return }
        if isCurrent, let current = music.nowPlaying, current.trackURI == track.uri {
            if current.isPaused { music.togglePause() }
            return
        }
        if let combined = music as? CombinedMusic, combined.usesLocalPlayback,
           let localQueueIndex, let upcomingOffset {
            combined.playQueuedSong(at: localQueueIndex + 1 + upcomingOffset, uri: track.uri)
            return
        }
        // Play this song just like a search result. Spotify's queue response
        // is only a snapshot, so never rebuild playback from its remaining rows.
        music.play(.tracks([track.uri]))
    }

    private func refresh() async {
        guard let music = model.music else { return }
        refreshPending = true
        guard !loading else { return }
        loading = true
        defer { loading = false }
        repeat {
            refreshPending = false
            do {
                let result = try await music.playbackQueue()
                guard !Task.isCancelled, model.music === music else { return }
                withTransaction(Transaction(animation: nil)) {
                    queue = result
                    if let combined = music as? CombinedMusic, combined.usesLocalPlayback {
                        localQueueIndex = combined.local.index
                    } else { localQueueIndex = nil }
                    error = nil
                }
            } catch {
                guard !Task.isCancelled, model.music === music else { return }
                self.error = "Couldn’t refresh your queue. " + error.localizedDescription
            }
            // Coalesce additions during a request into one fresh read instead
            // of dropping them or cancelling the only in-flight refresh.
        } while refreshPending
    }
}

/// Each presentation surface owns its sheet, including the full player.
struct QueueButton: View {
    @Environment(\.look) private var look
    @State private var showsQueue = false

    var body: some View {
        Button { showsQueue = true } label: {
            Image(systemName: "list.bullet")
                .font(look.font(19, .medium))
                .foregroundStyle(look.palette.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View queue")
        .sheet(isPresented: $showsQueue) {
            QueueSheet().environment(\.look, look).noticeOverlay()
        }
    }
}
