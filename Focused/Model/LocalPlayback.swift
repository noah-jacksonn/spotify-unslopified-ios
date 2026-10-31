import AVFoundation
import MediaPlayer
import Observation
import UIKit

@Observable
final class LocalPlayback: NSObject {
    private(set) var nowPlaying: NowPlaying?
    private(set) var queue: [LocalSong] = []
    private(set) var index = 0
    var onNotice: ((Notice) -> Void)?
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var resumesAfterInterruption = false

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false
        statusObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateState() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in self?.updateState(publish: false) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didFinish),
            name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaReset),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func play(_ songs: [LocalSong], startAt: Int = 0) throws {
        guard songs.indices.contains(startAt) else { return }
        let song = songs[startAt]
        let item = AVPlayerItem(url: song.audioURL)
        try activateAudio()
        registerCommands()
        player.pause()
        queue = songs
        index = startAt
        player.replaceCurrentItem(with: item)
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.pause()
                    self.onNotice?(Notice(text: "Couldn't open this audio file."))
                }
            }
        }
        player.play()
        updateState()
    }

    func pause() {
        resumesAfterInterruption = false
        player.pause()
        updateState()
    }

    func resume() {
        guard player.currentItem != nil else { return }
        do {
            try activateAudio()
            let duration = player.currentItem?.duration.seconds ?? 0
            if duration.isFinite && player.currentTime().seconds >= duration { seek(toMs: 0) }
            player.play()
            updateState()
        } catch { onNotice?(Notice(text: "Couldn't play this song. \(error.localizedDescription)")) }
    }

    func togglePause() { player.timeControlStatus == .paused ? resume() : pause() }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        queue = []
        nowPlaying = nil
        resumesAfterInterruption = false
        for (command, token) in commands { command.removeTarget(token) }
        commands = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func next() {
        guard index + 1 < queue.count else { pause(); return }
        do { try play(queue, startAt: index + 1) }
        catch { pause(); onNotice?(Notice(text: error.localizedDescription)) }
    }

    func previous() {
        if player.currentTime().seconds > 3 || index == 0 { seek(toMs: 0); return }
        do { try play(queue, startAt: index - 1) }
        catch { pause(); onNotice?(Notice(text: error.localizedDescription)) }
    }

    func seek(toMs position: Int) {
        guard player.currentItem != nil, queue.indices.contains(index) else { return }
        let seconds = min(Double(queue[index].durationMs) / 1000, max(0, Double(position) / 1000))
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateState() }
        }
    }

    func enqueue(_ song: LocalSong) throws {
        guard nowPlaying != nil else { try play([song]); return }
        queue.append(song)
    }

    func refresh(songs: [LocalSong]) {
        queue = queue.map { queued in songs.first { $0.id == queued.id } ?? queued }
        updateState()
    }

    private func activateAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func updateState(publish: Bool = true) {
        guard player.currentItem != nil, queue.indices.contains(index) else { return }
        let song = queue[index]
        let rawPosition = player.currentTime().seconds
        let position = rawPosition.isFinite ? max(0, rawPosition) : 0
        let rawDuration = player.currentItem?.duration.seconds ?? 0
        let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : Double(song.durationMs) / 1000
        let isPlaying = player.timeControlStatus == .playing
        nowPlaying = NowPlaying(title: song.title, artist: song.artist, album: song.track.album,
            artwork: Artwork(url: song.artworkURL, seed: nil), trackURI: song.uri,
            contextURI: "suno:library", isPaused: player.rate == 0,
            positionMs: Int(position * 1000), durationMs: Int(duration * 1000), updatedAt: Date(),
            speed: isPlaying ? 1 : 0)
        guard publish else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let url = song.artworkURL, let image = UIImage(contentsOfFile: url.path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func registerCommands() {
        guard commands.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        addCommand(center.playCommand) { $0.resume() }
        addCommand(center.pauseCommand) { $0.pause() }
        addCommand(center.togglePlayPauseCommand) { $0.togglePause() }
        addCommand(center.nextTrackCommand) { $0.next() }
        addCommand(center.previousTrackCommand) { $0.previous() }
        center.changePlaybackPositionCommand.isEnabled = true
        let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let milliseconds = Int(event.positionTime * 1000)
            Task { @MainActor [weak self] in self?.seek(toMs: milliseconds) }
            return .success
        }
        commands.append((center.changePlaybackPositionCommand, token))
    }

    private func addCommand(_ command: MPRemoteCommand, action: @escaping @MainActor (LocalPlayback) -> Void) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in if let self { action(self) } }
            return .success
        }
        commands.append((command, token))
    }

    @objc private func didFinish(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem, player.currentItem === item else { return }
        if index + 1 < queue.count { next() }
        else { updateState() }
    }

    @objc private func interrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            let wasPlaying = player.rate > 0
            pause()
            resumesAfterInterruption = wasPlaying
        } else {
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if resumesAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) { resume() }
            resumesAfterInterruption = false
        }
    }

    @objc private func routeChanged(_ notification: Notification) {
        if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { pause() }
    }

    @objc private func mediaReset() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        nowPlaying?.isPaused = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onNotice?(Notice(text: "Audio was reset. Tap a song to resume."))
    }
}
