import CryptoKit
import Foundation
import Security

/// Authorization Code with PKCE: no client secret and no backend. The view
/// layer runs the browser step (it owns `webAuthenticationSession`); this
/// type builds the URL, exchanges the code, and keeps tokens fresh in the
/// Keychain.
@Observable
final class SpotifyAuth {
    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        /// Space-separated scopes Spotify granted; nil for tokens saved
        /// before this was recorded.
        var scope: String?
    }

    enum AuthError: LocalizedError {
        case denied(String), unavailable(Int), badResponse, signedOut

        var errorDescription: String? {
            switch self {
            case .denied(let reason): "Spotify declined sign-in (\(reason))."
            case .unavailable: "Spotify's sign-in service didn't answer. Try again in a moment."
            case .badResponse: "Spotify sent an unexpected sign-in response."
            case .signedOut: "Signed out of Spotify."
            }
        }
    }

    private(set) var tokens: Tokens?
    /// Called when Spotify revokes the sign-in mid-session (not on a
    /// user sign-out), so the app can go back to the sign-in screen.
    var onExpired: (() -> Void)?
    /// Bumped by every sign-out; a refresh that started before one must
    /// not store its tokens afterwards.
    private var generation = 0
    private var verifier = ""
    private var state = ""
    private var refreshTask: Task<Tokens, Error>?

    var isSignedIn: Bool { tokens != nil }

    /// Whether this sign-in covers the scopes added after first release.
    /// Checks only those, not every scope: if Spotify ever left one out of
    /// its reply, a full check would sign Noah out on every launch.
    var hasAllScopes: Bool {
        let granted = Set((tokens?.scope ?? "").split(separator: " ").map(String.init))
        return Config.laterScopes.isSubset(of: granted)
    }

    init() {
        tokens = Keychain.load()
    }

    func authorizeURL() -> URL {
        verifier = Self.randomString(64)
        state = Self.randomString(16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: Config.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Config.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: Config.scopes.joined(separator: " ")),
        ]
        return components.url!
    }

    func completeSignIn(callback: URL) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw AuthError.denied(error) }
        guard value("state") == state, let code = value("code") else { throw AuthError.badResponse }
        let tokens = try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.redirectURI,
            "client_id": Config.clientID,
            "code_verifier": verifier,
        ], keepingRefreshToken: nil)
        store(tokens)
    }

    /// A token good for at least another minute, refreshing if needed.
    /// Concurrent callers share one refresh.
    func accessToken() async throws -> String {
        guard let tokens else { throw AuthError.signedOut }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        return try await refresh().accessToken
    }

    /// Callers that arrive mid-refresh share it; a revoked refresh token
    /// reaches all of them as `.signedOut`.
    @discardableResult
    func refresh() async throws -> Tokens {
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens else { throw AuthError.signedOut }
        let started = generation
        let task = Task {
            do {
                return try await requestTokens([
                    "grant_type": "refresh_token",
                    "refresh_token": current.refreshToken,
                    "client_id": Config.clientID,
                ], keepingRefreshToken: current.refreshToken)
            } catch AuthError.denied {
                throw AuthError.signedOut
            }
        }
        refreshTask = task
        // Only this refresh's own slot: after a sign-out a newer one may be
        // running.
        defer { if started == generation { refreshTask = nil } }
        do {
            let fresh = try await task.value
            // Signed out (or in again) while this was in flight.
            guard started == generation else { throw AuthError.signedOut }
            store(fresh)
            return fresh
        } catch AuthError.signedOut where started == generation {
            // Revoked or expired refresh token: start over at sign-in.
            signOut()
            onExpired?()
            throw AuthError.signedOut
        }
    }

    func signOut() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        Keychain.delete()
    }

    /// Takes tokens the sleep timer refreshed while the app was in the
    /// background, if they came from this sign-in's refresh token.
    func adopt(_ fresh: Tokens, refreshedFrom refreshToken: String) {
        guard tokens?.refreshToken == refreshToken else { return }
        store(fresh)
    }

    private func store(_ tokens: Tokens) {
        self.tokens = tokens
        Keychain.save(tokens)
    }

    /// The refresh call, for the sleep timer to send from its background
    /// session; `decodeTokens` reads the reply.
    static func refreshRequest(_ refreshToken: String) -> URLRequest {
        tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Config.clientID,
        ])
    }

    private static func tokenRequest(_ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .formValue) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }

    private func requestTokens(_ form: [String: String], keepingRefreshToken: String?) async throws -> Tokens {
        let (data, response) = try await URLSession.shared.data(for: Self.tokenRequest(form))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.decodeTokens(data, status: status, keepingRefreshToken: keepingRefreshToken, scope: tokens?.scope)
    }

    static func decodeTokens(_ data: Data, status: Int, keepingRefreshToken: String?, scope: String?) throws -> Tokens {
        struct Body: Decodable {
            var access_token: String?
            var refresh_token: String?
            var expires_in: Double?
            var scope: String?
            var error: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        guard (200..<300).contains(status), let body, let access = body.access_token else {
            // Only a rejected grant or client means the sign-in is dead;
            // rate limits and server errors are temporary and keep it.
            if status == 400 || status == 401,
               let error = body?.error, error == "invalid_grant" || error == "invalid_client" {
                throw AuthError.denied(error)
            }
            throw (200..<300).contains(status) ? AuthError.badResponse : AuthError.unavailable(status)
        }
        // Spotify may or may not rotate the refresh token on refresh.
        guard let refresh = body.refresh_token ?? keepingRefreshToken else { throw AuthError.badResponse }
        return Tokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(body.expires_in ?? 3600),
            scope: body.scope ?? scope
        )
    }

    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    static let formValue = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
}

private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.harmonyappai.FocusedSpotify",
        kSecAttrAccount as String: "spotify-tokens",
    ]

    static func load() -> SpotifyAuth.Tokens? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifyAuth.Tokens.self, from: data)
    }

    static func save(_ tokens: SpotifyAuth.Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        delete()
        var item = query
        item[kSecValueData as String] = data
        // This device only: tokens stay out of backups and device transfers.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
