import SwiftUI

/// Spotify owns this queue, including tracks added from another device.
struct QueueSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var queue: PlaybackQueue?
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
                            queueRow(current)
                        }
                    }
                    if let queue {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: "Next up")
                            if queue.upcoming.isEmpty {
                                Text("Your queue is empty. Add songs from search, an album, or a playlist.")
                                    .font(look.font(16)).foregroundStyle(look.palette.muted)
                            } else {
                                // A song may appear more than once; identify occurrences.
                                ForEach(Array(queue.upcoming.enumerated()), id: \.offset) { _, track in
                                    queueRow(track)
                                }
                            }
                        }
                    } else if loading {
                        BarsLoader().frame(maxWidth: .infinity, minHeight: 160)
                    }
                    if let error {
                        Text(error).font(look.font(15)).foregroundStyle(look.palette.muted)
                        Button("Try again") { Task { await refresh() } }
                    }
                    if model.pendingQueueRequests > 0 {
                        HStack { BarsLoader(size: 16, delay: .zero); Text("Adding to queue…").font(look.font(14)) }
                    }
                    Text("Upcoming tracks are supplied by Spotify. To reorder or remove songs, open the queue in Spotify.")
                        .font(look.font(12)).foregroundStyle(look.palette.muted)
                }
                .padding(look.margin)
            }
            .refreshable { await refresh() }
            .pageBackground()
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
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

    private func queueRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: Artwork(url: track.imageURL, seed: track.demoSeed))
                .frame(width: 48, height: 48).artClip(look, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.name).font(look.font(16, .medium)).foregroundStyle(look.palette.text).lineLimit(2)
                Text(track.artists).font(look.font(13)).foregroundStyle(look.palette.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            AddToPlaylistMenu(track: track)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .songContextMenu(track)
        // In a queue, swiping implies removing this occurrence. Spotify
        // doesn't expose removal, so don't reuse the browse-row add gesture.
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
                queue = result
                error = nil
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
