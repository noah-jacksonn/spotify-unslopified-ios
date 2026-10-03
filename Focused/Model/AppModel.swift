import Foundation
import UIKit

@Observable
final class AppModel {
    enum Mode { case signedOut, preview, spotify }
    enum LibraryState: Equatable { case idle, loading, loaded, failed(String) }

    let auth = SpotifyAuth()
    let sleepTimer: SleepTimer
    private(set) var mode: Mode = .signedOut
    private(set) var music: (any MusicService)?
    private(set) var playlists: [Playlist] = []
    private(set) var libraryState: LibraryState = .idle
    private(set) var home = HomeSelection(scope: "spotify")
    var signInError: String?
    /// A short message shown over every screen (`noticeOverlay`), then
    /// cleared after a few seconds.
    private(set) var notice: Notice?
    private var noticeTask: Task<Void, Never>?
    /// Deleted this session; kept out of library loads that started before
    /// Spotify caught up.
    private var deletedIDs: Set<String> = []

    init() {
        sleepTimer = SleepTimer(auth: auth)
        sleepTimer.music = { [weak self] in self?.music }
        sleepTimer.usesSpotify = { [weak self] in self?.mode == .spotify }
        auth.onExpired = { [weak self] in
            guard let self, self.mode == .spotify else { return }
            self.signOut()
            self.signInError = "Spotify signed you out. Connect again to keep listening."
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-preview") {
            startPreview()
            return
        }
        #endif
        if auth.isSignedIn && !auth.hasAllScopes {
            // Signed in before a permission was added (2026-10-02: playlist
            // editing). Spotify only grants new scopes at sign-in.
            auth.signOut()
            signInError = "Sign in again so Focused can edit your playlists and library."
        }
        if auth.isSignedIn { startSpotify() }
    }

    var homePlaylists: [Playlist] {
        home.ids.compactMap { id in playlists.first { $0.id == id } }
    }

    // MARK: Sessions

    func signIn(callback: URL) async {
        do {
            try await auth.completeSignIn(callback: callback)
            startSpotify()
        } catch {
            signInError = error.localizedDescription
        }
    }

    /// Whether a playlist is in the library, and so can be shown on Home
    /// (Home only lists library playlists).
    func isInLibrary(_ playlist: Playlist) -> Bool {
        playlists.contains { $0.id == playlist.id }
    }

    func startPreview() { start(DemoMusic(), mode: .preview, scope: "preview") }

    func startSpotify() { start(SpotifyMusic(auth: auth), mode: .spotify, scope: "spotify") }

    private func start(_ music: any MusicService, mode: Mode, scope: String) {
        music.onNotice = { [weak self] in self?.show($0) }
        self.music = music
        deletedIDs = []
        home = HomeSelection(scope: scope)
        self.mode = mode
        playlists = []
        libraryState = .idle
        // The scene is usually already active, so its phase change won't
        // come; connect to Spotify now. Not when iOS launched the app in
        // the background for the sleep timer: RootView connects once it's
        // opened.
        DispatchQueue.main.async { [weak self] in
            guard self?.music === music, UIApplication.shared.applicationState != .background else { return }
            music.appBecameActive()
        }
    }

    func show(_ message: String) { show(Notice(text: message)) }

    func show(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self.notice = nil }
        }
    }

    /// Tapping the notice: opens Spotify if it's that kind, then hides it.
    func tapNotice() {
        if notice?.opensSpotify == true { music?.openSpotify() }
        noticeTask?.cancel()
        notice = nil
    }

    func signOut() {
        sleepTimer.cancel()
        music?.appWillResignActive()
        if mode == .spotify { auth.signOut() }
        music = nil
        playlists = []
        libraryState = .idle
        mode = .signedOut
    }

    // MARK: Library

    /// Removes it from the library and Home right away; puts both back if
    /// Spotify refuses.
    /// Undoing a failure puts back only this playlist, and only in the same
    /// session, so other Home changes made meanwhile survive.
    func delete(_ playlist: Playlist) async {
        guard let music, let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let homeIndex = home.ids.firstIndex(of: playlist.id)
        playlists.remove(at: index)
        home.remove(playlist)
        do {
            try await music.deletePlaylist(playlist)
            guard self.music === music else { return }
            // A refresh that finished meanwhile (or finishes later) may
            // bring it back.
            deletedIDs.insert(playlist.id)
            playlists.removeAll { $0.id == playlist.id }
            home.remove(playlist)
            show(playlist.isOwned ? "Deleted \(playlist.name)" : "Removed \(playlist.name) from your library")
        } catch {
            guard self.music === music else { return }
            if !playlists.contains(where: { $0.id == playlist.id }) {
                playlists.insert(playlist, at: min(index, playlists.count))
            }
            if let homeIndex { home.insert(playlist, at: homeIndex) }
            show(error.localizedDescription)
        }
    }

    /// False if Spotify refused, so the caller can put the song back.
    func remove(_ track: Track, from playlist: Playlist, copies: Int) async -> Bool {
        guard let music else { return false }
        do {
            try await music.remove([track.uri], from: playlist)
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[index].trackCount = max(0, (playlists[index].trackCount ?? copies) - copies)
            }
            return true
        } catch {
            show(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func add(_ track: Track, to playlist: Playlist) async -> Bool {
        guard let music else { return false }
        do {
            try await music.add([track.uri], to: playlist)
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[index].trackCount = (playlists[index].trackCount ?? 0) + 1
            }
            show("Added to \(playlist.name)")
            return true
        } catch {
            show(error.localizedDescription)
            return false
        }
    }

    /// Results are dropped if the session changed while loading (signed
    /// out, or switched to the preview), so one session's library never
    /// lands in another.
    func loadLibrary() async {
        guard let music, libraryState != .loading else { return }
        libraryState = .loading
        let isCurrent = { [weak self] in self?.music === music }
        do {
            let loaded = try await music.loadPlaylists()
            guard isCurrent() else { return }
            playlists = loaded.filter { !deletedIDs.contains($0.id) }
            home.seedIfNeeded(from: playlists, preview: mode == .preview)
            libraryState = .loaded
        } catch SpotifyAuth.AuthError.signedOut {
            // `auth.onExpired` has already returned to sign-in.
        } catch {
            guard isCurrent() else { return }
            libraryState = playlists.isEmpty ? .failed(error.localizedDescription) : .loaded
            show(error.localizedDescription)
        }
    }
}

/// The playlists chosen for Home, in order. Kept on this device only, like
/// the extension's per-profile selection; Spotify's library is untouched.
@Observable
final class HomeSelection {
    private(set) var ids: [String]
    private let key: String
    private let seededKey: String

    init(scope: String) {
        key = "home.\(scope).playlists"
        seededKey = "home.\(scope).seeded"
        ids = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func contains(_ playlist: Playlist) -> Bool { ids.contains(playlist.id) }

    func toggle(_ playlist: Playlist) {
        if let index = ids.firstIndex(of: playlist.id) { ids.remove(at: index) } else { ids.append(playlist.id) }
        save()
    }

    func remove(_ playlist: Playlist) {
        ids.removeAll { $0 == playlist.id }
        save()
    }

    func insert(_ playlist: Playlist, at index: Int) {
        guard !ids.contains(playlist.id) else { return }
        ids.insert(playlist.id, at: min(index, ids.count))
        save()
    }

    func moveToTop(_ playlist: Playlist) {
        ids.removeAll { $0 == playlist.id }
        ids.insert(playlist.id, at: 0)
        save()
    }

    /// First run: "End of 2026" if the library has it (the extension's
    /// default); the preview starts with a handful so layouts have content.
    func seedIfNeeded(from playlists: [Playlist], preview: Bool) {
        guard !UserDefaults.standard.bool(forKey: seededKey), !playlists.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: seededKey)
        if preview {
            ids = playlists.prefix(7).map(\.id)
        } else if let favorite = playlists.first(where: { $0.name.caseInsensitiveCompare("End of 2026") == .orderedSame }) {
            ids = [favorite.id]
        }
        save()
    }

    private func save() {
        UserDefaults.standard.set(ids, forKey: key)
    }
}
