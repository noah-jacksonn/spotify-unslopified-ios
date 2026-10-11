import Foundation

@main
struct SpotifyAuthTests {
    static func main() throws {
        let data = Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8)
        let refreshed = try SpotifyAuth.decodeTokens(data, status: 200, keepingRefreshToken: "previous-refresh",
                                                      scope: "playlist-read-private", accountID: "account-one")
        precondition(refreshed.accountID == "account-one", "Refreshing must preserve Discover's account identity")
        precondition(refreshed.refreshToken == "previous-refresh" && refreshed.scope == "playlist-read-private")
        let rotated = Data(#"{"access_token":"new-access","refresh_token":"rotated","scope":"new-scope"}"#.utf8)
        let background = try SpotifyAuth.decodeTokens(rotated, status: 200, keepingRefreshToken: "previous-refresh",
                                                       scope: "old-scope", accountID: "account-one")
        precondition(background.accountID == "account-one" && background.refreshToken == "rotated")
        precondition(background.scope == "new-scope")
        let signIn = try SpotifyAuth.decodeTokens(rotated, status: 200, keepingRefreshToken: nil, scope: nil)
        precondition(signIn.accountID == nil, "A fresh sign-in has no account identity until fetched")
        print("Spotify auth checks passed: account identity, refresh-token rotation, scopes, and fresh sign-in")
    }
}
