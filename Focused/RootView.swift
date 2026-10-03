import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// "system", "light" or "dark". A segtest panel's footer toggles it;
    /// it was left at dark when the look was locked in.
    @AppStorage("appearanceOverride") private var appearanceOverride = "system"
    /// The current song's art color, for the page glow.
    @State private var artTint: UIColor?

    var body: some View {
        let look = Look(isDark: colorScheme == .dark, artTint: artTint)
        Group {
            switch model.mode {
            case .signedOut:
                SignInView()
            case .preview, .spotify:
                MainView()
            }
        }
        .environment(\.look, look)
        .tint(look.palette.accent)
        .animation(look.animation, value: model.mode)
        .background { ArtTintWatcher(tint: $artTint) }
        .onAppear { applyAppearance() }
        .onChange(of: appearanceOverride) { applyAppearance() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.music?.appBecameActive()
            // Not on .inactive: Control Center, banners and the app switcher
            // pass through it, and dropping the App Remote link there meant
            // the next play had to bounce through the Spotify app again.
            case .background: model.music?.appWillResignActive()
            case .inactive: break
            @unknown default: break
            }
        }
    }

    /// Applied to every window, a segtest panel's included.
    private func applyAppearance() {
        let style: UIUserInterfaceStyle = switch appearanceOverride {
        case "light": .light
        case "dark": .dark
        default: .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

/// Keeps `tint` on the current song's art color. Its own view, so playback
/// updates re-render only this and not the whole app.
private struct ArtTintWatcher: View {
    @Binding var tint: UIColor?
    @Environment(AppModel.self) private var model

    var body: some View {
        Color.clear.task(id: model.music?.nowPlaying?.artwork) { await update() }
    }

    /// Back to the accent when nothing is playing. A song whose art hasn't
    /// arrived yet keeps the previous color, so the glow doesn't flash
    /// between songs.
    private func update() async {
        guard let artwork = model.music?.nowPlaying?.artwork else {
            tint = nil
            return
        }
        guard artwork != .none else { return }
        let found = await ArtGlow.tint(for: artwork)
        if !Task.isCancelled { tint = found }
    }
}

/// Signed in (or previewing): Home in a navigation stack, the mini player
/// over every page, and sheets for the library and the full player.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var path = NavigationPath()
    @State private var showsLibrary = false
    @State private var showsNowPlaying = false
    @State private var openedDebugScreen = false

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(showsLibrary: $showsLibrary)
                .appDestinations()
        }
        .playerBar(isCovered: showsLibrary, showsFullPlayer: $showsNowPlaying)
        .noticeOverlay()
        .sheet(isPresented: $showsLibrary) {
            LibrarySheet()
                .environment(\.look, look)
                .noticeOverlay()
        }
        .task(id: model.mode) {
            await model.loadLibrary()
            if !openedDebugScreen {
                openedDebugScreen = true
                openDebugScreen()
            }
        }
    }

    /// Debug launch arguments from `scripts/run-on-iphone.sh` that open a
    /// screen directly, run once the library has loaded. (`-openSearch` is
    /// handled by HomeView, which owns search mode.)
    private func openDebugScreen() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-openPlaylist") || arguments.contains("-autoplay") {
            if let first = model.homePlaylists.first {
                if arguments.contains("-autoplay") { model.music?.play(.context(uri: first.uri)) }
                if arguments.contains("-openPlaylist") { path.append(first) }
            }
        }
        if arguments.contains("-openLibrary") { showsLibrary = true }
        if arguments.contains("-openArtist") || arguments.contains("-openAlbum") {
            // The first artist a search turns up, or that artist's first album.
            Task {
                guard let music = model.music,
                      let artist = try? await music.search("the").artists.first else { return }
                if arguments.contains("-openAlbum") {
                    if let album = try? await music.artistPage(artist).albums.first { path.append(album) }
                } else {
                    path.append(artist)
                }
            }
        }
        if arguments.contains("-openNowPlaying") {
            if model.music?.nowPlaying == nil, let first = model.playlists.first {
                model.music?.play(.context(uri: first.uri))
            }
            showsNowPlaying = true
        }
        #endif
    }
}

extension View {
    /// Every destination a navigation stack in the app can push. Applied to
    /// each stack so they stay in step.
    func appDestinations() -> some View {
        navigationDestination(for: Playlist.self) { PlaylistView(playlist: $0) }
            .navigationDestination(for: CatalogItem.self) { CatalogPage(item: $0) }
    }

    /// The mini player docked at the bottom, opening the full player. On
    /// the main screen and inside the library sheet, which would otherwise
    /// cover it. `isCovered` skips drawing a bar a sheet is hiding;
    /// `showsFullPlayer` lets a caller open the player itself.
    func playerBar(isCovered: Bool = false, showsFullPlayer: Binding<Bool>? = nil) -> some View {
        modifier(PlayerBar(isCovered: isCovered, external: showsFullPlayer))
    }

    /// The app's notice capsule. Applied to the main screen and to each
    /// sheet, so a message is never hidden behind a sheet.
    func noticeOverlay() -> some View {
        modifier(NoticeOverlay())
    }
}

private struct PlayerBar: ViewModifier {
    var isCovered: Bool
    var external: Binding<Bool>?
    @State private var showsOwn = false
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look

    private var showsFullPlayer: Binding<Bool> { external ?? $showsOwn }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isCovered, let music = model.music, let state = music.nowPlaying {
                    MiniPlayer(state: state, music: music) { showsFullPlayer.wrappedValue = true }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(look.animation, value: model.music?.nowPlaying == nil)
            .sheet(isPresented: showsFullPlayer) {
                if let music = model.music {
                    NowPlayingSheet(music: music)
                        .environment(\.look, look)
                        .noticeOverlay()
                }
            }
    }
}

private struct NoticeOverlay: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = model.notice {
                    Text(notice.opensSpotify ? "\(notice.text) Tap to open Spotify." : notice.text)
                        .font(look.font(14, .medium))
                        .foregroundStyle(look.palette.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .surface(look, in: Capsule(), raised: true)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { model.tapNotice() }
                }
            }
            .animation(look.animation, value: model.notice)
    }
}
