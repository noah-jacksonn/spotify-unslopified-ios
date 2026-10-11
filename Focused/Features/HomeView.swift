import SwiftUI

/// Home: the wordmark and the chosen playlists. Search happens in place —
/// the search button stretches into the field, the wordmark and playlists
/// give way to results, and Cancel morphs it back (Noah, 2026-10-02:
/// "morph the current page" rather than push a search screen).
struct HomeView: View {
    @Binding var showsLibrary: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var isSearching = false
    @State private var query = ""
    @State private var isLoadingResults = false
    @State private var barsTaps = 0
    @State private var barsPressed = false
    @State private var showsSleepTimer = false
    @FocusState private var searchFocused: Bool
    @Namespace private var morph

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: look.gap * 1.6) {
                header
                if isSearching {
                    SearchResultsView(query: query, isLoading: $isLoadingResults)
                        .transition(.opacity.combined(with: .offset(y: 16)))
                } else {
                    Group {
                        content
                        VStack(spacing: 12) {
                            if !model.homePlaylists.isEmpty { allPlaylistsButton }
                            dailyFiveButton
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: 24)))
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { if !isSearching { await model.loadLibrary() } }
        .toolbar(.hidden, for: .navigationBar)
        .pageBackground()
        .animation(look.animation, value: model.home.ids)
        .sheet(isPresented: $showsSleepTimer) {
            SleepTimerSheet().environment(\.look, look)
        }
        .onAppear {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-openSearch"), !isSearching { setSearching(true) }
            if arguments.contains("-openSleepTimer") { showsSleepTimer = true }
            #endif
        }
    }

    private func setSearching(_ on: Bool) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            isSearching = on
            if !on { query = "" }
        }
        searchFocused = on
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if isSearching {
                    SearchField(query: $query, isLoading: isLoadingResults, focused: $searchFocused, namespace: morph)
                    Button("Cancel") { setSearching(false) }
                        .font(look.font(16, .medium))
                        .foregroundStyle(look.palette.text)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    Spacer()
                    QueueButton()
                    searchButton
                    // One way into All playlists: the button under Home's
                    // list (an icon here duplicated it).
                    accountMenu
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .frame(height: 44)
            if !isSearching {
                HStack(alignment: .center, spacing: 12) {
                    barsButton
                    Text("Spotify Unslopified")
                        .font(look.display(28))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .tracking(look.titleTracking)
                        .foregroundStyle(look.palette.text)
                    Spacer(minLength: 0)
                    if let endsAt = model.sleepTimer.endsAt {
                        sleepBadge(endsAt)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .animation(look.animation, value: model.sleepTimer.endsAt == nil)
                .transition(.opacity.combined(with: .offset(y: -12)))
            }
        }
        .padding(.horizontal, look.margin)
        .padding(.top, 8)
    }

    /// Shares its icon and shape ids with `SearchField`.
    private var searchButton: some View {
        Button { setSearching(true) } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(look.palette.text)
                .matchedGeometryEffect(id: "search.icon", in: morph)
                .frame(width: 38, height: 38)
                .background {
                    Capsule()
                        .fill(look.palette.surface)
                        .matchedGeometryEffect(id: "search.shape", in: morph)
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Search")
    }

    /// The wordmark's moving bars double as play/pause, and a long press
    /// opens the sleep timer (Noah, 2026-10-03). A tap is inert when
    /// nothing is loaded, so a stray one never starts music. Gestures, not
    /// a Button: a Button would also fire its tap at the end of a long
    /// press.
    private var barsButton: some View {
        BarsMark(color: look.palette.accent, size: 30, playing: isPlaying)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .scaleEffect(barsPressed ? 0.95 : 1)
            .opacity(barsPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: barsPressed)
            .onTapGesture(perform: tapBars)
            .onLongPressGesture(minimumDuration: 0.4) {
                showsSleepTimer = true
            } onPressingChanged: { barsPressed = $0 }
            .sensoryFeedback(.impact(weight: .light), trigger: barsTaps)
            .sensoryFeedback(.impact(weight: .medium), trigger: showsSleepTimer) { _, shown in shown }
            .padding(-7)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityHint("Controls the current song; touch and hold for the sleep timer")
            .accessibilityIdentifier("home.playbackToggle")
            .accessibilityAction { tapBars() }
            .accessibilityAction(named: "Sleep timer") { showsSleepTimer = true }
    }

    private func tapBars() {
        guard let music = model.music, music.nowPlaying != nil else { return }
        music.togglePause()
        barsTaps += 1
    }

    /// Time left on the sleep timer, beside the wordmark; tap to change it.
    private func sleepBadge(_ endsAt: Date) -> some View {
        Button { showsSleepTimer = true } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(SleepTimerSheet.short(endsAt.timeIntervalSince(context.date)), systemImage: "moon.zzz.fill")
                    .font(look.font(14, .semibold).monospacedDigit())
                    .foregroundStyle(look.palette.muted)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .surface(look, in: Capsule())
            }
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Sleep timer")
    }

    private var isPlaying: Bool { model.music?.nowPlaying.map { !$0.isPaused } ?? false }

    private var isLoading: Bool {
        model.playlists.isEmpty && (model.libraryState == .idle || model.libraryState == .loading)
    }

    private var accountMenu: some View {
        Menu {
            Button("Sleep timer", systemImage: "moon.zzz") { showsSleepTimer = true }
            if model.mode == .preview {
                Label("Previewing sample music", systemImage: "sparkles")
                Button("Leave preview", systemImage: "arrow.uturn.left") { model.signOut() }
            } else {
                Button("Sign out of Spotify", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    model.signOut()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(look.palette.text)
                .frame(width: 38, height: 38)
                .surface(look, in: Circle())
        }
        .accessibilityLabel("Account")
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            // Only before anything has loaded; a refresh keeps the list up.
            HomeLoadingView()
        } else if case .failed(let message) = model.libraryState {
            emptyState(title: "Couldn't load your playlists", detail: message, action: "Try again") {
                Task { await model.loadLibrary() }
            }
        } else if model.homePlaylists.isEmpty {
            emptyState(title: "Home is empty", detail: "Choose the playlists you want here. Nothing else shows up.",
                       action: "Choose playlists") { showsLibrary = true }
        } else {
            PlaylistList(playlists: model.homePlaylists)
        }
    }

    private var dailyFiveButton: some View {
        NavigationLink(value: DailyFiveRoute()) {
            DiscoverEntry(artworks: discoverArtworks)
        }
        .buttonStyle(PressScale())
        .padding(.horizontal, look.margin)
    }

    private var discoverArtworks: [Artwork] {
        // Source playlists guide Discover, but their covers aren't its contents.
        // Empty sleeves stay neutral until a saved or newly loaded edition exists.
        (model.dailyFive?.edition?.picks ?? []).map {
            Artwork(url: $0.track.imageURL, seed: $0.track.demoSeed)
        }
    }

    private var allPlaylistsButton: some View {
        Button { showsLibrary = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.stack")
                Text("All playlists")
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
            }
            .font(look.font(16, .medium))
            .foregroundStyle(look.palette.text)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .surface(look, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScale())
        .padding(.horizontal, look.margin)
    }

    private func emptyState(title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(look.display(26))
                .tracking(look.titleTracking)
                .foregroundStyle(look.palette.text)
            Text(detail)
                .font(look.font(16))
                .foregroundStyle(look.palette.muted)
            PlayPill(title: action, systemName: "plus", action: perform)
                .padding(.top, 10)
        }
        .padding(.horizontal, look.margin)
        .padding(.top, 30)
    }
}

/// Home's playlists: 88 pt round-cornered art beside the name, like the
/// extension's Home. Swipe right to play, left to shuffle; long-press for
/// Play, Move to top, Remove from Home.
private struct PlaylistList: View {
    var playlists: [Playlist]
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var deleting: Playlist?

    var body: some View {
        VStack(spacing: look.gap) {
            ForEach(playlists) { playlist in
                NavigationLink(value: playlist) {
                    row(playlist).contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .contextMenu {
                    if playlist.isMine {
                        Button("Add to queue", systemImage: "text.badge.plus") { model.enqueue(playlist) }
                    }
                    Button("Play", systemImage: "play.fill") { model.music?.play(.context(uri: playlist.uri)) }
                    Button("Move to top", systemImage: "arrow.up.to.line") { model.home.moveToTop(playlist) }
                    Button("Remove from Home", systemImage: "minus.circle") { model.home.remove(playlist) }
                    Button(playlist.isOwned ? "Delete playlist" : "Remove from library", systemImage: "trash", role: .destructive) {
                        deleting = playlist
                    }
                }
                .rowSwipes(
                    leading: RowSwipe(systemName: "play.fill", label: "Play") {
                        model.music?.play(.context(uri: playlist.uri))
                    },
                    trailing: RowSwipe(systemName: "shuffle", label: "Shuffle") { shuffle(playlist) }
                )
            }
        }
        .deletePlaylistConfirmation($deleting)
        .padding(.horizontal, look.margin)
    }

    /// Starts at a random song, as the playlist page's Shuffle does. Home
    /// doesn't load the songs, so it picks a position from the count.
    private func shuffle(_ playlist: Playlist) {
        let position = playlist.trackCount.flatMap { $0 > 0 ? Int.random(in: 0..<$0) : nil }
        model.music?.shuffle(.context(uri: playlist.uri, position: position))
    }

    private func row(_ playlist: Playlist) -> some View {
        let state = model.music?.nowPlaying
        let isCurrent = state?.contextURI == playlist.uri
        let detail = [playlist.trackCount.map { "\($0) songs" }, playlist.isMine ? nil : playlist.ownerName]
            .compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 16) {
            ArtworkView(artwork: Artwork(url: playlist.imageURL, seed: playlist.demoSeed))
                .frame(width: 88, height: 88)
                .artClip(look, size: 88)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isCurrent { BarsMark(color: look.palette.accent, size: 14, playing: state?.isPaused == false) }
                    Text(playlist.name)
                        .font(look.font(18, .semibold))
                        .foregroundStyle(look.palette.text)
                        .lineLimit(1)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(look.font(14))
                        .foregroundStyle(look.palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Home's loader: `BarsLoader` where the list will appear.
private struct HomeLoadingView: View {
    var body: some View {
        BarsLoader()
            .frame(maxWidth: .infinity, minHeight: 220)
            .accessibilityLabel("Loading your playlists")
    }
}
