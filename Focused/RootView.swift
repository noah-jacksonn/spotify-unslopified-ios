import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// "system", "light" or "dark". A segtest panel's footer toggles it;
    /// it was left at dark when the look was locked in.
    @AppStorage("appearanceOverride") private var appearanceOverride = "system"

    var body: some View {
        let look = Look(isDark: colorScheme == .dark)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let music = model.music, let state = music.nowPlaying {
                MiniPlayer(state: state, music: music) { showsNowPlaying = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(look.animation, value: model.music?.nowPlaying == nil)
        .noticeOverlay()
        .sheet(isPresented: $showsLibrary) {
            LibrarySheet()
                .environment(\.look, look)
                .noticeOverlay()
        }
        .sheet(isPresented: $showsNowPlaying) {
            if let music = model.music {
                NowPlayingSheet(music: music)
                    .environment(\.look, look)
                    .noticeOverlay()
            }
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
    /// each stack (Home's and the library sheet's) so they stay in step.
    func appDestinations() -> some View {
        navigationDestination(for: Playlist.self) { PlaylistView(playlist: $0) }
            .navigationDestination(for: CatalogItem.self) { CatalogPage(item: $0) }
    }

    /// The app's notice capsule. Applied to the main screen and to each
    /// sheet, so a message is never hidden behind a sheet.
    func noticeOverlay() -> some View {
        modifier(NoticeOverlay())
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
