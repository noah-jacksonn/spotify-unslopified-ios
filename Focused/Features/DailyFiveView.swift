import SwiftUI

struct DailyFiveRoute: Hashable {}

/// A single daily destination, not an expanding recommendations feed.
struct DailyFiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look

    var body: some View {
        Group {
            if let daily = model.dailyFive {
                DailyFiveContent(daily: daily)
            } else {
                VStack(spacing: 18) {
                    if let error = model.dailyFiveError {
                        Text(error).font(look.font(16)).foregroundStyle(look.palette.muted)
                        Button("Try again") { Task { await model.prepareDailyFive() } }
                    } else {
                        BarsLoader()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(look.margin)
            }
        }
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .pageBackground()
        .task { await model.prepareDailyFive() }
    }
}

private struct DailyFiveContent: View {
    var daily: DailyFive
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsSources = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                introduction
                if daily.sourceIDs.isEmpty {
                    setup
                } else {
                    if daily.showsLoadingSkeleton() {
                        DiscoverSkeleton()
                    } else if let edition = daily.edition {
                        editionView(edition)
                    }
                    if let error = daily.error {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(error).font(look.font(15)).foregroundStyle(look.palette.muted)
                            HStack(spacing: 18) {
                                Button("Try again") { Task { await load() } }
                                Button("Change sources") { showsSources = true }
                            }
                            .font(look.font(15, .semibold))
                        }
                    }
                }
            }
            .padding(.horizontal, look.margin)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsSources = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Discover sources")
                    .disabled(daily.isLoading)
            }
        }
        .sheet(isPresented: $showsSources, onDismiss: { Task { await load() } }) {
            DailySourcesSheet(daily: daily).environment(\.look, look)
        }
        .task { await load() }
        .onChange(of: model.libraryState) { _, state in
            if state == .loaded { Task { await load() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            Task { await load() }
        }
    }

    private var introduction: some View {
        DiscoverHeading(isToday: daily.showsLoadingSkeleton() || daily.edition == nil || daily.isToday)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "music.note.list")
                .font(look.font(30)).foregroundStyle(look.palette.accent)
            Text("Start with your kind of music")
                .font(look.display(22)).foregroundStyle(look.palette.text)
            Text("Choose up to five playlists you own or share. We’ll find something new.")
                .font(look.font(15)).foregroundStyle(look.palette.muted)
            PlayPill(title: "Choose playlists", systemName: "plus") { showsSources = true }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(look, in: RoundedRectangle(cornerRadius: 26))
    }

    private func editionView(_ edition: DailyEdition) -> some View {
        let tracks = edition.picks.map(\.track)
        return VStack(alignment: .leading, spacing: 22) {
            if !daily.isToday {
                Text("Your last five · \(edition.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(look.font(14, .medium)).foregroundStyle(look.palette.muted)
            }
            HStack(spacing: 12) {
                PlayPill(title: "Play five") { model.music?.play(.tracks(tracks.map(\.uri))) }
                CircleIconButton(systemName: "text.badge.plus", label: "Add all five to queue") { model.enqueue(tracks) }
                Menu {
                    let playlists = model.playlists.filter(\.isMine)
                    if playlists.isEmpty { Text("No editable playlists") }
                    ForEach(playlists) { playlist in
                        Button(playlist.name) { Task { await model.add(tracks, to: playlist) } }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(look.font(19, .medium)).foregroundStyle(look.palette.text)
                        .frame(width: 46, height: 46).surface(look, in: Circle())
                }
                .accessibilityLabel("Save all five to a playlist")
            }
            DiscoverTracks(edition: edition)
        }
    }

    private func load() async {
        guard let music = model.music else { return }
        if model.libraryState == .idle { await model.loadLibrary() }
        guard model.libraryState != .loading || daily.isToday else { return }
        await daily.load(using: music, playlists: model.playlists)
    }
}

private struct DailySourcesSheet: View {
    var daily: DailyFive
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()

    private var playlists: [Playlist] { model.playlists.filter(\.isMine) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Where should we start?")
                        .font(look.display(28)).foregroundStyle(look.palette.text)
                    Text("Pick up to five playlists to guide your daily songs.")
                        .font(look.font(16)).foregroundStyle(look.palette.muted)
                    if daily.isToday {
                        Text("Changes start with tomorrow’s five.")
                            .font(look.font(14)).foregroundStyle(look.palette.accent)
                    }
                    if playlists.isEmpty {
                        Text("Create a playlist in Spotify, then refresh your library here. Spotify only shares songs from playlists you own or collaborate on.")
                            .font(look.font(15)).foregroundStyle(look.palette.muted)
                        Button("Refresh library") { Task { await model.loadLibrary() } }
                    }
                    ForEach(playlists) { playlist in
                        Button {
                            if selected.contains(playlist.id) { selected.remove(playlist.id) }
                            else if selected.count < 5 { selected.insert(playlist.id) }
                        } label: {
                            HStack(spacing: 14) {
                                ArtworkView(artwork: model.artwork(for: playlist))
                                    .frame(width: 54, height: 54).artClip(look, size: 54)
                                Text(playlist.name).font(look.font(16, .medium)).multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: selected.contains(playlist.id) ? "checkmark.circle.fill" : "circle")
                                    .font(look.font(23)).foregroundStyle(selected.contains(playlist.id) ? look.palette.accent : look.palette.muted)
                            }
                            .foregroundStyle(look.palette.text)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!selected.contains(playlist.id) && selected.count >= 5)
                        .accessibilityAddTraits(selected.contains(playlist.id) ? .isSelected : [])
                    }
                }
                .padding(look.margin)
            }
            .pageBackground()
            .navigationTitle("Your sources · \(selected.count)/5")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        daily.setSources(playlists.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .presentationBackground(look.palette.background)
        .onAppear {
            let available = Set(playlists.map(\.id))
            selected = Set(daily.sourceIDs).intersection(available)
            if selected.isEmpty {
                selected = Set(model.homePlaylists.filter(\.isMine).prefix(3).map(\.id))
                if selected.isEmpty, let first = playlists.first { selected = [first.id] }
            }
        }
    }
}
