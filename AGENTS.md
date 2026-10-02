# Focused (iOS) agent guide

Focused is a native SwiftUI remote for Spotify: a quiet Home of playlists Noah picks, plus search, playlists and a player. It is the iOS sibling of the Chrome extension in `../focused-spotify`, which is the reference for product behavior (Home shows only chosen playlists, no recommendations feed, empty search shows nothing until you type, the library opens on "By you").

## How it talks to Spotify

- Sign-in is Authorization Code with PKCE (`Focused/Spotify/SpotifyAuth.swift`). No client secret, no backend. Tokens live in the Keychain. Client ID and scopes are in `Focused/Config.swift`; the dashboard app must list `focusedspotify://callback` and have Web API + iOS enabled.
- The Web API (`SpotifyAPI.swift`) covers library, playlist items, search and player commands. It targets the February 2026 development-mode API: playlist contents via `/playlists/{id}/items` (`items[].item`), only for playlists the user owns or collaborates on (others return metadata only, and the UI says so); search returns at most 10 per type; dev mode allows 5 users and needs Premium.
- Audio always plays in the Spotify app. `SpotifyMusic` drives it through the iOS SDK (App Remote) when connected, else the Web API, else wakes Spotify with `authorizeAndPlayURI`. Keep that fallback order.
- `DemoMusic` is the sample-music preview ("Try with sample music", or the `-preview` launch argument). It exists so designs can be tested without Spotify; keep it working when screens change.

## Design system

- The look is locked in from Noah's on-phone segtest (2026-10-02): Ink palette, SF Rounded, a soft accent glow behind pages, calm 0.35 s easing, a List Home with 88 pt round-cornered art, the wordmark header, airy spacing, a full-width Bar mini player and the Poster full player. It lives in `Focused/Design/Look.swift` and is read from `@Environment(\.look)`. Screens use `look.palette`, `look.font`/`look.display`, `look.artRadius`, `.surface(look, in:)`, `look.animation`; never hard-code colors or fonts.
- Deployment target is iOS 26 (Noah's phone), so iOS 26 APIs (Liquid Glass, MeshGradient) are available without availability checks.

## Segtest

When Noah says "segtest", follow the harmony-ios convention: a temporary in-place comparison using the Debug-only scaffold `Focused/Design/DebugSegtestPanel.swift` (`.segtest(id:corner:)`, `SegtestRow`, `SegtestGroup`). Each segtest's picks are saved under `segtest.pick.<id>.<row>`.

Picks are saved on the phone. Run `scripts/read-segtest.sh [id]` at the start of a follow-up turn instead of asking what he chose. "Lock in everything" locks every row at its saved pick and removes the segtest; locking a specific row removes only that row; unmentioned rows stay. Say which values you locked in.

Files that should exist only in Debug builds start with `Debug`; Release excludes `Debug*`.

## Build and run

```sh
xcodebuild -project Focused.xcodeproj -scheme Focused -destination 'generic/platform=iOS Simulator' build
```

After a user-testable change, run `scripts/run-on-iphone.sh`. It builds, installs and launches on Noah's iPhone. If the phone is unavailable or locked, say so and tell Noah to run from Xcode. Screen flags open the app on the surface under test: `--preview`, `--search`, `--library`, `--playlist`, `--play`, `--now-playing`, `--artist`, `--album`, `--loader`. Add a flag (backed by a Debug launch argument in `MainView.openDebugScreen`) for each new surface Noah tests.

Signing: Harmony Mental Health, LLC team (`4X89BKDS2G`, the paid account), bundle ID `com.harmonyappai.FocusedSpotify`. Development installs last about a year; re-run the script to renew.

Noah tests on his phone. Simulator screenshots are fine for checking layout, but the simulator is shared state. To preset segtest picks there, pass them as launch arguments (`-segtest.pick.<id>.<Row> <Value>`); `simctl defaults write` does not reach the app's preferences.

## Repository

Commit directly to `main`; push only when asked. Regenerate the app icon with `node scripts/make-icon.mjs` (draws the extension's three-bar mark at 1024 px).
