# Set up your copy

You only need to do this once. Start with the repo downloaded and `Focused.xcodeproj` open in Xcode.

## 1. Choose your app identity

In Xcode, select the blue **Focused** project → **Focused** target → **Signing & Capabilities**.

- Enable **Automatically manage signing**.
- Select your Apple **Team**. If none appears, add your Apple account in **Xcode → Settings → Accounts**. A free Personal Team works for installing on your own phone, but needs periodic reinstallation.
- Change **Bundle Identifier** to something unique, such as `com.yourname.SpotifyUnslopified`. Copy it for the next step.

## 2. Create your Spotify app

Sign in to the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) with your **Premium** account and create an app.

- **Name / description:** anything you like.
- **Redirect URI:** `focusedspotify://callback` — exactly, with no trailing slash.
- **APIs / SDKs:** select **Web API** and **iOS**.
- **iOS Bundle ID:** the same identifier you chose in Xcode. If this field is on the app's settings page, add it there after creating the app.

In the app's **Settings → Users Management**, add the Spotify name/email you'll sign in with to its allowlist. Copy the app's **Client ID** (not its client secret).

In the downloaded repo's `Configuration` folder, duplicate `Local.example.xcconfig` and rename the copy **`Local.xcconfig`**. Set `SPOTIFY_CLIENT_ID` to your Client ID. You can remove the other two example lines if you've already set your Team and Bundle Identifier in Xcode.

This file is ignored by Git. No client secret is needed.

## 3. Install

1. Install Spotify on your iPhone and sign in.
2. Connect the iPhone to your Mac, unlock it, and accept **Trust** if prompted.
3. Enable **Developer Mode** in iPhone **Settings → Privacy & Security** if Xcode asks (requires a restart).
4. In Xcode's device picker, choose your iPhone. Wait for package downloads, then press **⌘R**.
5. Open **Spotify Unslopified**, tap **Connect Spotify**, and approve Spotify's access screen.

If iOS asks you to trust your developer app, follow the prompt in **Settings → General → VPN & Device Management**. Choose your playlists on Home and you're ready.

## Stuck?

| Symptom | Check |
| --- | --- |
| Missing Client ID message | File is named `Configuration/Local.xcconfig`, the Client ID is pasted without quotes, and you rebuilt. |
| Redirect error | Spotify's redirect is exactly `focusedspotify://callback`. |
| Sign-in works but requests fail / 403 | Your Spotify account is allowlisted, Premium is active, and you're using your own Client ID. |
| Signing error | Your Apple Team is selected and your Bundle Identifier is unique. It must also match Spotify's iOS settings. |
| Playback won't start | Open Spotify on the phone, play a song once, then return here. |
| App stops opening after a few days | Free Apple signing expires; connect the phone and run from Xcode again. |

Spotify limits development apps to [five allowlisted users](https://developer.spotify.com/documentation/web-api/concepts/quota-modes). Everyone building their own copy should create their own developer app.
