import Foundation
import UIKit

/// Pauses the music after any number of minutes (Noah, 2026-10-03).
///
/// iOS freezes the app soon after the phone locks, so an in-app timer can't
/// be trusted. While the app is open, one does the job; when the app goes
/// to the background, the pause is handed to a background URLSession, which
/// sends it at the end time even if the app is frozen or was closed by the
/// system (not if it's swiped away in the app switcher). Spotify tokens
/// last an hour, so a longer timer first schedules a token refresh in the
/// same session; when that lands, iOS wakes the app for a moment to
/// schedule the next step.
@Observable
final class SleepTimer {
    static let sessionID = "com.harmonyappai.FocusedSpotify.sleep"

    /// When the music pauses; nil when no timer is set. Saved, so the timer
    /// survives the app being closed.
    private(set) var endsAt: Date?

    /// Set by AppModel.
    @ObservationIgnored var music: () -> (any MusicService)? = { nil }
    /// Only Spotify plays on with the app in the background; the preview
    /// is paused when the app is opened again instead.
    @ObservationIgnored var usesSpotify: () -> Bool = { false }

    private let auth: SpotifyAuth
    private let delegate = SessionDelegate()
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var localTimer: Task<Void, Never>?
    @ObservationIgnored private var replies: [Int: Data] = [:]
    @ObservationIgnored private var eventsFinished: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var eventsFinishedEarly = false

    private static let endsAtKey = "sleep.endsAt"
    private static let pauseKind = "pause"
    /// Followed by the refresh token the request uses.
    private static let refreshKind = "refresh:"
    private static let bodyDirectory = URL.applicationSupportDirectory.appending(path: "SleepTimer", directoryHint: .isDirectory)

    init(auth: SpotifyAuth) {
        self.auth = auth
        endsAt = UserDefaults.standard.object(forKey: Self.endsAtKey) as? Date
        delegate.owner = self
        // Reattach to a timer's session, so its events reach this delegate
        // after iOS relaunches the app for them.
        if endsAt != nil { _ = backgroundSession() }
    }

    // MARK: Setting it

    func start(minutes: Int) {
        set(Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func extend(minutes: Int) {
        guard let endsAt else { return start(minutes: minutes) }
        set(endsAt.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func cancel() {
        guard endsAt != nil else { return }
        cancelPendingTasks()
        finish()
    }

    private func set(_ date: Date) {
        endsAt = date
        save()
        startLocalTimer()
    }

    // MARK: App lifecycle (RootView's scene phase)

    func appBecameActive() {
        guard let endsAt else { return }
        // The in-app timer takes over again.
        cancelPendingTasks()
        if endsAt > Date() {
            startLocalTimer()
        } else if !usesSpotify() || Date().timeIntervalSince(endsAt) < 300 {
            // Ended while the app was away. A background pause clears the
            // timer when it lands, so it didn't (or this is the preview,
            // which has none): pause now, unless that was a while ago.
            fire()
        } else {
            finish()
        }
    }

    func appEnteredBackground() {
        localTimer?.cancel()
        guard endsAt != nil, usesSpotify(), let tokens = auth.tokens else { return }
        scheduleNextStep(with: tokens)
    }

    // MARK: In-app timer

    private func startLocalTimer() {
        localTimer?.cancel()
        guard let endsAt else { return }
        localTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, endsAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        if let music = music(), music.nowPlaying?.isPaused == false { music.togglePause() }
        finish()
    }

    private func finish() {
        localTimer?.cancel()
        endsAt = nil
        save()
    }

    private func save() {
        UserDefaults.standard.set(endsAt, forKey: Self.endsAtKey)
    }

    // MARK: Background session

    private func backgroundSession() -> URLSession {
        if let session { return session }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        let made = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
        session = made
        return made
    }

    /// The pause, if the token lasts until the end time; else a refresh
    /// five minutes before the token runs out.
    private func scheduleNextStep(with tokens: SpotifyAuth.Tokens) {
        guard let endsAt else { return }
        if tokens.expiresAt.addingTimeInterval(-120) > endsAt {
            schedulePause(token: tokens.accessToken, at: endsAt)
        } else {
            scheduleRefresh(tokens.refreshToken, at: tokens.expiresAt.addingTimeInterval(-300))
        }
    }

    private func schedulePause(token: String, at date: Date) {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/pause")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        enqueue(request, kind: Self.pauseKind, at: date)
    }

    private func scheduleRefresh(_ refreshToken: String, at date: Date) {
        enqueue(SpotifyAuth.refreshRequest(refreshToken), kind: Self.refreshKind + refreshToken, at: date)
    }

    /// Background sessions only send bodies from files, so the body goes
    /// to one (removed once the timer is over).
    private func enqueue(_ request: URLRequest, kind: String, at date: Date) {
        var request = request
        let body = request.httpBody ?? Data()
        request.httpBody = nil
        var file = Self.bodyDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: Self.bodyDirectory, withIntermediateDirectories: true)
            try body.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        } catch {
            return
        }
        let task = backgroundSession().uploadTask(with: request, fromFile: file)
        task.taskDescription = kind
        task.earliestBeginDate = date > Date() ? date : nil
        task.countOfBytesClientExpectsToSend = Int64(body.count) + 1024
        task.countOfBytesClientExpectsToReceive = 4096
        task.resume()
    }

    /// Pauses, and refreshes that haven't started. A refresh already on the
    /// wire is left to finish, since Spotify may have replaced the refresh
    /// token by now; its reply is still adopted.
    private func cancelPendingTasks() {
        backgroundSession().getAllTasks { tasks in
            let soon = Date().addingTimeInterval(10)
            for task in tasks where task.taskDescription == Self.pauseKind || (task.earliestBeginDate ?? .distantPast) > soon {
                task.cancel()
            }
            DispatchQueue.main.async { self.removeBodiesIfIdle() }
        }
    }

    private func removeBodiesIfIdle() {
        guard endsAt == nil else { return }
        backgroundSession().getAllTasks { tasks in
            guard tasks.allSatisfy({ $0.state == .canceling || $0.state == .completed }) else { return }
            try? FileManager.default.removeItem(at: Self.bodyDirectory)
        }
    }

    // MARK: Session events (on the main queue)

    fileprivate func received(_ data: Data, for task: URLSessionTask) {
        replies[task.taskIdentifier, default: Data()].append(data)
    }

    fileprivate func completed(_ task: URLSessionTask, error: Error?) {
        let data = replies.removeValue(forKey: task.taskIdentifier) ?? Data()
        guard let kind = task.taskDescription, (error as? URLError)?.code != .cancelled else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        // Problems that pass (a dropped connection, Spotify busy) are
        // retried for up to ten minutes past the end.
        let inWindow = endsAt.map { Date() < $0.addingTimeInterval(600) } == true
        let canRetry = inWindow && (error != nil || status == 429 || (500..<600).contains(status))

        if kind == Self.pauseKind {
            if inWindow, status == 401, let tokens = auth.tokens {
                // The token ran out while iOS held the pause back: refresh,
                // and the refresh schedules the pause again.
                scheduleRefresh(tokens.refreshToken, at: Date())
                return
            }
            if canRetry, let tokens = auth.tokens, tokens.expiresAt > Date().addingTimeInterval(90) {
                schedulePause(token: tokens.accessToken, at: Date().addingTimeInterval(30))
                return
            }
            // Paused, or Spotify refused (already paused, no device).
            finish()
            removeBodiesIfIdle()
        } else if kind.hasPrefix(Self.refreshKind) {
            let used = String(kind.dropFirst(Self.refreshKind.count))
            if error == nil, let fresh = try? SpotifyAuth.decodeTokens(data, status: status, keepingRefreshToken: used,
                                                                      scope: auth.tokens?.scope) {
                auth.adopt(fresh, refreshedFrom: used)
                // While the app is open its own timer is in charge. (Read
                // from UIKit: after a relaunch for these events, no scene
                // phase change has come.)
                if UIApplication.shared.applicationState == .background, let tokens = auth.tokens { scheduleNextStep(with: tokens) }
            } else if used != auth.tokens?.refreshToken {
                // An older chain the app has since replaced; leave the timer.
            } else if canRetry {
                scheduleRefresh(used, at: Date().addingTimeInterval(60))
            } else {
                // Spotify rejected the sign-in; the app will ask again.
                finish()
            }
        }
    }

    fileprivate func didFinishEvents() {
        if let eventsFinished {
            self.eventsFinished = nil
            eventsFinished.resume()
        } else {
            eventsFinishedEarly = true
        }
    }

    /// For the scene's `.backgroundTask(.urlSession)`: returns once iOS has
    /// delivered everything it woke the app for.
    @MainActor
    func handleBackgroundEvents() async {
        _ = backgroundSession()
        await withCheckedContinuation { continuation in
            if eventsFinishedEarly {
                eventsFinishedEarly = false
                continuation.resume()
            } else {
                eventsFinished = continuation
            }
        }
    }
}

private final class SessionDelegate: NSObject, URLSessionDataDelegate {
    weak var owner: SleepTimer?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.received(data, for: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.completed(task, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        owner?.didFinishEvents()
    }
}
