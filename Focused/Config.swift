import Foundation

/// Spotify developer app settings. The dashboard app must list
/// `redirectURI` exactly, and have both "Web API" and "iOS" enabled.
enum Config {
    /// Supplied by Configuration/Local.xcconfig; public by design (PKCE).
    static let clientID = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""
    static var isConfigured: Bool { clientID.count == 32 && clientID.allSatisfy(\.isHexDigit) }

    static let redirectURI = "focusedspotify://callback"
    static let callbackScheme = "focusedspotify"

    /// `app-remote-control` lets the same token drive the Spotify app through
    /// the iOS SDK; the rest cover the Web API reads and player controls.
    static let scopes = [
        "ugc-image-upload",
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
        "playlist-modify-private",
        "playlist-modify-public",
        // Deleting a playlist = removing it from the library (DELETE /me/library).
        "user-library-modify",
        "user-follow-modify",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "app-remote-control",
    ]

    /// Scopes added after the first sign-ins; a saved sign-in without them
    /// is asked to sign in again (`SpotifyAuth.hasAllScopes`).
    static let laterScopes: Set<String> = [
        "ugc-image-upload", // 2026-10-20: playlist covers
        "playlist-modify-private", "playlist-modify-public", // 2026-10-02: adding/removing songs
        "user-library-modify", "user-follow-modify",          // 2026-10-03: deleting playlists
    ]
}
