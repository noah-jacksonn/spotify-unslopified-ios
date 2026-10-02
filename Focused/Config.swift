import Foundation

/// Spotify developer app settings. The dashboard app must list
/// `redirectURI` exactly, and have both "Web API" and "iOS" enabled.
enum Config {
    /// developer.spotify.com/dashboard → Focused Spotify → Settings. A
    /// Client ID is public by design; PKCE means no client secret is used.
    static let clientID = "356a1f5dec784635bf89fb4272a86abf"

    static let redirectURI = "focusedspotify://callback"
    static let callbackScheme = "focusedspotify"

    /// `app-remote-control` lets the same token drive the Spotify app through
    /// the iOS SDK; the rest cover the Web API reads and player controls.
    static let scopes = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
        "playlist-modify-private",
        "playlist-modify-public",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "app-remote-control",
    ]

    /// Scopes added after the first sign-ins; a saved sign-in without them
    /// is asked to sign in again (`SpotifyAuth.hasAllScopes`).
    static let laterScopes: Set<String> = ["playlist-modify-private", "playlist-modify-public"]
}
