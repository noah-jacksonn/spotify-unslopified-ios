import Foundation
import SpotifyiOS
import UIKit

/// Prints which route each play took; `run-on-iphone.sh --console` streams
/// stdout (Logger output wouldn't show there).
private func log(_ message: String) { print("[playback] \(message)") }

/// Spotify-backed music: the Web API for library, search and player
/// commands; the iOS SDK (App Remote) for instant control of and live state
/// from the Spotify app on this phone. Audio always plays in the Spotify
/// app — this app is a remote.
///
/// Playback falls through four routes so a tap always does something:
/// 1. App Remote, when connected (fast, no network round trip).
/// 2. Web API on the active device, or on this phone if Spotify knows it.
/// 3. Reconnect App Remote quietly: works whenever Spotify is still running
///    in the background, even if the Web API no longer lists the phone.
/// 4. Only then wake the Spotify app with the URI (`authorizeAndPlayURI`).
///    It briefly opens Spotify, starts the music and returns here. iOS
///    freezes Spotify a while after it pauses, and only bringing it to the
///    front unfreezes it, so this step can't be removed entirely.
@Observable
final class SpotifyMusic: MusicService {
    private(set) var nowPlaying: NowPlaying?
    var onNotice: ((Notice) -> Void)?

    private let auth: SpotifyAuth
    private let api: SpotifyAPI
    private let remote: SPTAppRemote
    private let remoteDelegate = RemoteDelegate()
    private var isActive = true
    private var pollTask: Task<Void, Never>?
    /// A song to jump to once the woken Spotify app connects, and when it
    /// was asked for: `authorizeAndPlayURI` can only start a context from
    /// its top. Ignored after a minute, so an abandoned wake can't start an
    /// old song later.
    private var pendingStart: (request: PlayRequest, at: Date, id: Int)?
    private var lastImageID: String?
    /// The token the Spotify app hands back after a wake. App Remote
    /// accepts it reliably, so reconnects reuse it until it nears its one-
    /// hour expiry instead of falling back to the Web API token.
    private var remoteToken: (value: String, expires: Date)?
    private var refreshTask: Task<Void, Never>?
    /// Callers of `reconnectRemote` waiting on the connection delegate.
    private var connectWaiters: [CheckedContinuation<Bool, Never>] = []
    private var connectAttempt = 0
    /// Bumped by every play and every pause/skip/seek; a slower route still
    /// finishing an older play checks it before jumping or waking, so the
    /// user's latest action always wins.
    private var playID = 0
    /// Whether this app turned Spotify's shuffle on. The app has no shuffle
    /// toggle, so the next ordinary play turns it back off.
    private var turnedShuffleOn = false
    /// The image the current track uses, so an App Remote art download
    /// lands on whichever track shows it (often the whole album).
    private var currentImageID: String?
    /// Web API covers used when App Remote couldn't supply one, by App
    /// Remote image id, so later songs from the same album reuse them.
    private var fallbackArt: [String: Artwork] = [:]
    /// Spotify's podcast speed objects; setting one means passing it back.
    private var speedOptions: [SPTAppRemotePodcastPlaybackSpeed] = [] {
        didSet { speedValues = speedOptions.map(\.value.doubleValue) }
    }
    private var speedValues: [Double] = []

    /// App Remote's player, when connected.
    private var player: SPTAppRemotePlayerAPI? { remote.isConnected ? remote.playerAPI : nil }

    init(auth: SpotifyAuth) {
        self.auth = auth
        api = SpotifyAPI(auth: auth)
        let configuration = SPTConfiguration(clientID: Config.clientID, redirectURL: URL(string: Config.redirectURI)!)
        remote = SPTAppRemote(configuration: configuration, logLevel: .error)
        remote.delegate = remoteDelegate
        remoteDelegate.owner = self
        startPolling()
    }

    // MARK: Library

    func loadPlaylists() async throws -> [Playlist] { try await api.myPlaylists() }
    func tracks(in playlist: Playlist) async throws -> [Track] { try await api.tracks(inPlaylist: playlist.id) }
    func search(_ query: String) async throws -> SearchResults { try await api.search(query) }

    /// Only the artist lookup is required; a section that fails comes back
    /// empty so the rest of the page still shows.
    func artistPage(_ artist: CatalogItem) async throws -> ArtistPage {
        async let info = api.artist(artist.id)
        async let popular = try? api.popularTracks(for: artist)
        async let albums = try? api.albums(ofArtist: artist.id, group: "album")
        async let singles = try? api.albums(ofArtist: artist.id, group: "single")
        return try await ArtistPage(artist: info, popular: popular ?? [], albums: albums ?? [], singles: singles ?? [])
    }

    func albumPage(_ album: CatalogItem) async throws -> AlbumPage { try await api.album(album.id) }
    func add(_ trackURIs: [String], to playlist: Playlist) async throws {
        try await api.addItems(trackURIs, toPlaylist: playlist.id)
    }
    func deletePlaylist(_ playlist: Playlist) async throws {
        try await api.removeFromLibrary([playlist.uri])
    }
    func remove(_ trackURIs: [String], from playlist: Playlist) async throws {
        try await api.removeItems(trackURIs, fromPlaylist: playlist.id)
    }

    // MARK: Playback

    func play(_ request: PlayRequest) {
        play(request, shuffled: false)
    }

    func shuffle(_ request: PlayRequest) {
        play(request, shuffled: true)
    }

    private func play(_ request: PlayRequest, shuffled: Bool) {
        pendingStart = nil
        playID += 1
        if shuffled || turnedShuffleOn {
            turnedShuffleOn = shuffled
            setShuffle(shuffled, for: playID)
        }
        if let player, let uri = request.singleURI {
            log("play via App Remote")
            player.play(uri) { [weak self] _, error in
                if error != nil { self?.playWithFallbacks(request) }
            }
            return
        }
        playWithFallbacks(request)
    }

    /// Shuffle needs a playing device, which the slower routes take a few
    /// seconds to produce, so this retries until it sticks (or a newer play
    /// takes over).
    private func setShuffle(_ on: Bool, for id: Int) {
        Task {
            for delay in [Duration.milliseconds(800), .seconds(2), .seconds(4)] {
                try? await Task.sleep(for: delay)
                guard id == playID else { return }
                if let player {
                    player.setShuffle(on, callback: nil)
                    return
                }
                if (try? await api.setShuffle(on)) != nil { return }
            }
        }
    }

    /// Each route once, in order, stopping at the first that works:
    /// the active device, this phone (if Spotify still lists it), a quiet
    /// App Remote reconnect, and finally waking the Spotify app.
    private func playWithFallbacks(_ request: PlayRequest) {
        let id = playID
        Task {
            do {
                try await sendPlay(request)
                log("play via Web API")
                refreshSoon()
                return
            } catch let error as SpotifyAPI.APIError where error.isNoActiveDevice {
                // Fall through to the next route.
            } catch {
                report(error)
                return
            }
            guard id == playID else { return }
            if let phone = await thisPhoneID(), id == playID, (try? await sendPlay(request, deviceID: phone)) != nil {
                log("play via Web API on this phone")
                refreshSoon()
            } else if await reconnectRemote(), id == playID, let player {
                log("play via App Remote after a quiet reconnect")
                let started = Date()
                player.play(request.startURI) { _, error in
                    guard id == self.playID else { return }
                    if error != nil {
                        self.wakeSpotify(for: request)
                    } else {
                        self.jumpToStart(of: request, id: id, startedAt: started)
                    }
                }
            } else if id == playID {
                wakeSpotify(for: request)
            }
        }
    }

    /// App Remote and the wake can only start one URI. They start the
    /// chosen song itself (`startURI`), so it's what's heard; this then
    /// re-plays it inside its playlist or album over the Web API, at the
    /// spot it has reached, so the following songs come from the context
    /// and the handover isn't audible (Noah, 2026-10-03: starting the
    /// context's first song and then jumping was). Retried once, since the
    /// phone can take a moment to become the active device.
    private func jumpToStart(of request: PlayRequest, id: Int, startedAt: Date) {
        guard request.singleURI == nil else { return }
        Task {
            // Up to ~10 s: right after a wake the phone can be slow to become
            // the active device, and until this lands the song plays
            // outside its playlist.
            for delay in [Duration.milliseconds(800), .milliseconds(1500), .seconds(3), .seconds(5)] {
                try? await Task.sleep(for: delay)
                guard id == playID else { return }
                if (try? await sendPlay(request, positionMs: heardSoFar(of: request, since: startedAt))) != nil {
                    log("jumped to the chosen song")
                    refreshSoon()
                    return
                }
            }
            log("couldn't jump to the chosen song")
        }
    }

    /// How far into the chosen song playback is: App Remote's position when
    /// it reports that song, else the time since it was started. A request
    /// that names only a position (Home's swipe to shuffle) started the
    /// context's first song instead, so the chosen one starts from the top.
    private func heardSoFar(of request: PlayRequest, since startedAt: Date) -> Int {
        if case .context(_, nil, _) = request { return 0 }
        if let state = nowPlaying, state.trackURI == request.startURI { return state.position(at: Date()) }
        return max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    /// The phone's Spotify, if the Web API lists exactly one phone. With
    /// several (another phone on the account) it can't tell which is this
    /// one, so it skips to the reconnect rather than play on the wrong one.
    private func thisPhoneID() async -> String? {
        let phones = (try? await api.devices())?.filter { $0.type == "Smartphone" && $0.id != nil } ?? []
        return phones.count == 1 ? phones[0].id : nil
    }

    /// Connects App Remote if Spotify is running. Resolves as soon as the
    /// delegate reports success or failure (2 s at most), so a stopped
    /// Spotify falls through to the wake without a fixed wait. Calls that
    /// arrive mid-attempt share it.
    private func reconnectRemote() async -> Bool {
        if remote.isConnected { return true }
        guard auth.isSignedIn else { return false }
        await prepareRemoteToken()
        let connected = await withCheckedContinuation { continuation in
            let joining = !connectWaiters.isEmpty
            connectWaiters.append(continuation)
            guard !joining else { return }
            connectAttempt += 1
            let attempt = connectAttempt
            remote.connect()
            Task {
                try? await Task.sleep(for: .seconds(2))
                // Only this attempt's timeout; a later attempt has its own.
                if attempt == connectAttempt { resolveConnectWaiters(remote.isConnected) }
            }
        }
        if !connected { log("quiet reconnect failed; Spotify isn't running") }
        return connected
    }

    private func resolveConnectWaiters(_ connected: Bool) {
        let waiters = connectWaiters
        connectWaiters = []
        for waiter in waiters { waiter.resume(returning: connected) }
    }

    private func sendPlay(_ request: PlayRequest, positionMs: Int? = nil, deviceID: String? = nil) async throws {
        switch request {
        case let .context(uri, startAt, position):
            try await api.play(contextURI: uri, offsetURI: startAt, offsetPosition: position,
                               positionMs: positionMs, deviceID: deviceID)
        case let .tracks(uris):
            try await api.play(contextURI: nil, uris: uris, positionMs: positionMs, deviceID: deviceID)
        }
    }

    private func wakeSpotify(for request: PlayRequest) {
        log("play by waking the Spotify app (no active device)")
        pendingStart = request.singleURI == nil ? (request, Date(), playID) : nil
        Task {
            if await !remote.authorizeAndPlayURI(request.startURI) {
                onNotice?(Notice(text: "Install the Spotify app to play music."))
            }
        }
    }

    func openSpotify() {
        // "" resumes whatever Spotify last played, then returns here.
        Task { _ = await remote.authorizeAndPlayURI("") }
    }

    func togglePause() {
        playID += 1
        guard var state = nowPlaying else {
            resumeWithFallbacks()
            return
        }
        let pausing = !state.isPaused
        let before = state
        state.rebase()
        state.isPaused = pausing
        nowPlaying = state
        if let player {
            if pausing { player.pause(nil) } else { player.resume(nil) }
        } else if pausing {
            command { try await $0.pause() }
        } else {
            resumeWithFallbacks(revertingTo: before)
        }
    }

    /// Resume over the Web API, else a quiet reconnect, else wake Spotify
    /// (which resumes its last song). Puts the shown state back if all fail.
    private func resumeWithFallbacks(revertingTo previous: NowPlaying? = nil) {
        Task {
            do {
                try await api.resume()
                refreshSoon()
            } catch let error as SpotifyAPI.APIError where error.isNoActiveDevice {
                if await reconnectRemote(), let player {
                    player.resume(nil)
                } else if await !remote.authorizeAndPlayURI("") {
                    if let previous { nowPlaying = previous }
                    onNotice?(Notice(text: "Install the Spotify app to play music."))
                }
            } catch {
                if let previous { nowPlaying = previous }
                report(error)
            }
        }
    }

    func next() {
        playID += 1
        if let player { player.skip(toNext: nil) } else { command { try await $0.next() } }
    }

    func previous() {
        playID += 1
        if let player { player.skip(toPrevious: nil) } else { command { try await $0.previous() } }
    }

    func seek(toMs position: Int) {
        playID += 1
        if var state = nowPlaying {
            state.positionMs = position
            state.updatedAt = Date()
            nowPlaying = state
        }
        if let player { player.seek(toPosition: position, callback: nil) } else { command { try await $0.seek(toMs: position) } }
    }

    private func command(_ action: @escaping (SpotifyAPI) async throws -> Void) {
        Task {
            do { try await action(api) } catch { report(error) }
            refreshSoon()
        }
    }

    /// "No active device" problems become a tap-to-open-Spotify notice.
    private func report(_ error: Error) {
        let noDevice = (error as? SpotifyAPI.APIError)?.isNoActiveDevice == true
        onNotice?(Notice(text: error.localizedDescription, opensSpotify: noDevice))
    }

    // MARK: Podcast speed

    var podcastSpeeds: [Double] { player == nil ? [] : speedValues }

    func setPodcastSpeed(_ value: Double) {
        guard let player else {
            onNotice?(Notice(text: "Changing speed needs the Spotify app running.", opensSpotify: true))
            return
        }
        guard let option = speedOptions.first(where: { $0.value.doubleValue == value }) else { return }
        let before = nowPlaying
        if var state = nowPlaying {
            state.rebase()
            state.speed = value
            nowPlaying = state
        }
        player.setPodcastPlaybackSpeed(option) { [weak self] _, error in
            guard let self, let error else { return }
            if let before, self.nowPlaying?.trackURI == before.trackURI { self.nowPlaying?.speed = before.speed }
            self.report(error)
        }
    }

    // MARK: Lifecycle

    /// The SDK's guidance: connect when foregrounded, disconnect when not.
    /// Connecting only succeeds while the Spotify app is running; otherwise
    /// the Web API poll keeps state current until a play wakes Spotify.
    func appBecameActive() {
        isActive = true
        connectRemote()
        // Read state from the Web API only if App Remote hasn't connected by
        // then (`refreshSoon` re-checks after its delay).
        refreshSoon(after: .milliseconds(1500))
    }

    func appWillResignActive() {
        isActive = false
        if remote.isConnected { remote.disconnect() }
    }

    func handle(url: URL) {
        guard let parameters = remote.authorizationParameters(from: url) else { return }
        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            remoteToken = (token, Date().addingTimeInterval(55 * 60))
            connectRemote()
        } else if let message = parameters[SPTAppRemoteErrorDescriptionKey] {
            onNotice?(Notice(text: message))
        }
    }

    /// Goes through `reconnectRemote`, so foreground connects, wakes and
    /// quiet reconnects share one attempt instead of racing.
    private func connectRemote() {
        Task { _ = await reconnectRemote() }
    }

    /// Prefers the Spotify app's own token while fresh; otherwise our PKCE
    /// token, which also carries the app-remote-control scope.
    private func prepareRemoteToken() async {
        if let remoteToken, remoteToken.expires > Date() {
            remote.connectionParameters.accessToken = remoteToken.value
            return
        }
        let token = try? await auth.accessToken()
        // The woken Spotify app may have handed over its own token meanwhile.
        if let remoteToken, remoteToken.expires > Date() {
            remote.connectionParameters.accessToken = remoteToken.value
        } else {
            remote.connectionParameters.accessToken = token
        }
    }

    fileprivate func remoteConnected() {
        log("App Remote connected")
        resolveConnectWaiters(true)
        remote.playerAPI?.delegate = remoteDelegate
        remote.playerAPI?.subscribe(toPlayerState: nil)
        remote.playerAPI?.getPlayerState { [weak self] result, _ in
            if let state = result as? SPTAppRemotePlayerState { self?.apply(state) }
        }
        // The list is fixed per Spotify install, so it's fetched once.
        if speedOptions.isEmpty {
            remote.playerAPI?.getAvailablePodcastPlaybackSpeeds { [weak self] result, _ in
                self?.speedOptions = result as? [SPTAppRemotePodcastPlaybackSpeed] ?? []
            }
        }
        // A new connection is a fresh chance for covers that failed before.
        lastImageID = nil
        if let pending = pendingStart {
            pendingStart = nil
            if pending.at.timeIntervalSinceNow > -60 {
                jumpToStart(of: pending.request, id: pending.id, startedAt: Date())
            }
        }
    }

    fileprivate func remoteFailed(_ error: Error?) {
        // Usually just "Spotify isn't running"; the token is kept (see
        // `prepareRemoteToken`) because a failure here rarely means it's bad.
        log("App Remote connect failed: \(error?.localizedDescription ?? "unknown")")
        resolveConnectWaiters(false)
        // No live state from App Remote, so read it from the Web API now
        // rather than waiting for the next poll.
        refreshSoon(after: .zero)
    }

    fileprivate func apply(_ state: SPTAppRemotePlayerState) {
        let track = state.track
        let imageID = track.imageIdentifier
        currentImageID = imageID
        var artwork = nowPlaying?.trackURI == track.uri ? nowPlaying?.artwork ?? .none : .none
        if artwork == .none {
            if ImageCache.shared.contains(id: imageID) {
                artwork = .image(id: imageID)
            } else if let fallback = fallbackArt[imageID] {
                artwork = fallback
            } else if lastImageID != imageID {
                lastImageID = imageID
                fetchArtwork(for: track, imageID: imageID)
            }
        }
        setNowPlaying(NowPlaying(
            title: track.name,
            artist: track.artist.name,
            album: track.album.name,
            artwork: artwork,
            trackURI: track.uri,
            contextURI: state.contextURI.absoluteString,
            isPaused: state.isPaused,
            positionMs: state.playbackPosition,
            durationMs: Int(track.duration),
            updatedAt: Date(),
            // Spotify accepts a speed for songs but plays them at 1× anyway.
            speed: NowPlaying.isSpoken(uri: track.uri) && state.playbackSpeed > 0 ? Double(state.playbackSpeed) : 1,
            // Episodes report their show here; only artists have a page.
            artistItem: .spotifyArtist(uri: track.artist.uri, name: track.artist.name)
        ))
    }

    /// Cover from App Remote, else the Web API's art for what's playing: on
    /// 2026-10-03 a song kept a blank cover because one failed App Remote
    /// fetch (common right after Spotify opens) had no fallback. Tried once
    /// per image per connection (`lastImageID`).
    private func fetchArtwork(for track: SPTAppRemoteTrack, imageID: String) {
        Task { [weak self] in
            guard let self else { return }
            if let image = await self.remoteImage(for: track) {
                // Cached even if the song changed meanwhile, for coming back.
                ImageCache.shared.store(image, id: imageID)
                if self.currentImageID == imageID { self.nowPlaying?.artwork = .image(id: imageID) }
                return
            }
            if self.currentImageID == imageID, let state = try? await self.api.playbackState(),
               state.trackURI == track.uri, state.artwork != .none {
                self.fallbackArt[imageID] = state.artwork
                if self.currentImageID == imageID { self.nowPlaying?.artwork = state.artwork }
            } else if self.lastImageID == imageID {
                // Both sources failed: let the next state update try again.
                self.lastImageID = nil
            }
        }
    }

    private func remoteImage(for track: SPTAppRemoteTrack) async -> UIImage? {
        guard let imageAPI = remote.imageAPI else { return nil }
        return await withCheckedContinuation { continuation in
            imageAPI.fetchImage(forItem: track, with: CGSize(width: 640, height: 640)) { result, _ in
                continuation.resume(returning: result as? UIImage)
            }
        }
    }

    /// Skips updates that change nothing visible, so every list showing a
    /// playing indicator doesn't re-render on each poll or position event.
    /// Position counts only when it drifts from what extrapolation shows.
    private func setNowPlaying(_ new: NowPlaying?) {
        if let old = nowPlaying, let new,
           old.trackURI == new.trackURI, old.isPaused == new.isPaused, old.contextURI == new.contextURI,
           old.durationMs == new.durationMs, old.title == new.title, old.speed == new.speed,
           new.artwork == .none || old.artwork == new.artwork,
           abs(old.position(at: new.updatedAt) - new.positionMs) < 1500 {
            return
        }
        nowPlaying = new
    }

    // MARK: Web API state

    /// Only while App Remote is down. Every 5 s while playing (songs end,
    /// other devices take over); every 30 s while paused or idle, when
    /// little can change — development mode's request budget is small.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // `self` is held only for the poll, not across the sleep, so
                // a signed-out session is released (and its loop ends).
                let delay: Duration
                do {
                    guard let self else { return }
                    if self.isActive && !self.remote.isConnected { await self.pollOnce() }
                    delay = .seconds(self.nowPlaying.map { !$0.isPaused } ?? false ? 5 : 30)
                }
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// Coalesced: a burst of commands produces one read, after the last.
    private func refreshSoon(after delay: Duration = .milliseconds(700)) {
        guard !remote.isConnected else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !remote.isConnected else { return }
            await pollOnce()
        }
    }

    /// A successful "nothing playing" (nil) clears the players; a failed
    /// request leaves the last state alone.
    private func pollOnce() async {
        let state: NowPlaying?
        do { state = try await api.playbackState() } catch { return }
        // App Remote connected meanwhile; its state is newer.
        guard !remote.isConnected else { return }
        setNowPlaying(state)
    }

    deinit {
        pollTask?.cancel()
    }
}

/// App Remote's delegates must be NSObjects; this forwards to the model.
private final class RemoteDelegate: NSObject, SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    weak var owner: SpotifyMusic?

    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        MainActor.assumeIsolated { owner?.remoteConnected() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        MainActor.assumeIsolated { owner?.remoteFailed(error) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {}

    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        MainActor.assumeIsolated { owner?.apply(playerState) }
    }
}
