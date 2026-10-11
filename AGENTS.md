# Spotify Unslopified (iOS) agent guide

Spotify Unslopified is a native SwiftUI remote for Spotify: a quiet Home of playlists Noah picks, plus search, playlists and a player. It is the iOS sibling of the Chrome extension in `../focused-spotify`, which is the reference for product behavior (Home shows only chosen playlists, no recommendations feed, empty search shows nothing until you type, the library opens on "By you").

## How it talks to Spotify

- Sign-in is Authorization Code with PKCE (`Focused/Spotify/SpotifyAuth.swift`). No client secret, no backend. Tokens live in the Keychain. Client ID and scopes are in `Focused/Config.swift`; the dashboard app must list `focusedspotify://callback` and have Web API + iOS enabled.
- The Web API (`SpotifyAPI.swift`) covers library, playlist items, search and player commands. It targets the February 2026 development-mode API: playlist contents via `/playlists/{id}/items` (`items[].item`), only for playlists the user owns or collaborates on (others return metadata only, and the UI says so); search returns at most 10 per type; dev mode allows 5 users and needs Premium.
- Audio always plays in the Spotify app. `SpotifyMusic` drives it through the iOS SDK (App Remote) when connected, else the Web API, else wakes Spotify with `authorizeAndPlayURI`. Keep that fallback order.
- The sleep timer (`SleepTimer.swift`) pauses through a background URLSession, since iOS freezes the app once the phone locks: the pause request is scheduled for the end time, preceded by token refreshes for timers longer than the token's hour. It needs no background mode, but doesn't survive the app being swiped away.
- `DemoMusic` is the sample-music preview ("Try with sample music", or the `-preview` launch argument). It exists so designs can be tested without Spotify; keep it working when screens change.

## Design system

- The look is locked in from Noah's on-phone segtest (2026-10-02): Ink palette, SF Rounded, a soft glow behind pages (colored from the current song's art since 2026-10-03, the accent when nothing plays; `look.glow`), calm 0.35 s easing, a List Home with 88 pt round-cornered art, the wordmark header, airy spacing, a full-width Bar mini player and the Poster full player. It lives in `Focused/Design/Look.swift` and is read from `@Environment(\.look)`. Screens use `look.palette`, `look.font`/`look.display`, `look.artRadius`, `.surface(look, in:)`, `look.animation`; never hard-code colors or fonts.
- Deployment target is iOS 26 (Noah's phone), so iOS 26 APIs (Liquid Glass, MeshGradient) are available without availability checks.

## Segtest

When Noah says "segtest", follow the harmony-ios convention: a temporary in-place comparison using the Debug-only scaffold `Focused/Design/DebugSegtestPanel.swift` (`.segtest(id:corner:)`, `SegtestRow`, `SegtestGroup`). Each segtest's picks are saved under `segtest.pick.<id>.<row>`.

Picks are saved on the phone. Run `scripts/read-segtest.sh [id]` at the start of a follow-up turn instead of asking what he chose. "Lock in everything" locks every row at its saved pick and removes the segtest; locking a specific row removes only that row; unmentioned rows stay. Say which values you locked in.

Files that should exist only in Debug builds start with `Debug`; Release excludes `Debug*`.

## Build and run

```sh
xcodebuild -project Focused.xcodeproj -scheme Focused -destination 'generic/platform=iOS Simulator' build
```

After a user-testable change, run `scripts/run-on-iphone.sh`. It builds, installs and launches on Noah's iPhone. If the phone is unavailable or locked, say so and tell Noah to run from Xcode. Screen flags open the app on the surface under test: `--preview`, `--search`, `--library`, `--playlist`, `--play`, `--now-playing`, `--artist`, `--album`, `--loader`, `--cover`, `--queue`, `--daily-five`, `--lyrics`, `--sleep`. Add a flag (backed by a Debug launch argument in `MainView.openDebugScreen`) for each new surface Noah tests.

Signing: Harmony Mental Health, LLC team (`4X89BKDS2G`, the paid account), bundle ID `com.harmonyappai.FocusedSpotify`. Development installs last about a year; re-run the script to renew.

Noah tests on his phone. Simulator screenshots are fine for checking layout, but the simulator is shared state. To preset segtest picks there, pass them as launch arguments (`-segtest.pick.<id>.<Row> <Value>`); `simctl defaults write` does not reach the app's preferences.

## Repository

Commit directly to `main`; push only when asked. Regenerate the app icon with `node scripts/make-icon.mjs` (draws the extension's three-bar mark at 1024 px).

## Daily Five

- Discover (internally Daily Five) is an opt-in destination below All playlists on Home. Users choose up to five owned/collaborative source playlists; a successful five-song edition stays fixed for the local calendar day. Source changes apply to the next edition.
- `DailyFive.swift` rotates source artists, explores catalog search/releases and credited collaborators, and excludes source songs plus 30 days of prior picks. Do not depend on Spotify's restricted recommendations/related-artists APIs or send Spotify data to an AI service.
- Cache is isolated by Spotify account ID; previous picks stay available if a refresh fails. No background delivery or automatic playlist creation. Users can queue picks or save them to an existing playlist.
- Swipe right to queue on song rows outside the queue. Queue rows have no swipe action: Spotify does not expose removing/reordering existing queue entries, and swiping there must not enqueue duplicates. Playlist removal is a partial swipe left or the context menu; never allow full-swipe deletion. `QueueSwipe.swift` handles non-List rows.
- Test with `tests/run-daily-five-tests.sh` and `tests/run-queue-tests.sh`. `scripts/run-on-iphone.sh --daily-five` opens the feature; `-preview -openDailyFive -dailyFiveSample` supplies a filled Debug preview without changing Spotify preferences.
- Discover's Sleeves entry and Editorial layout are locked in `DiscoverDesign.swift`; the entry is compact (76 pt) with no subtitle. `--discover` opens the page; `--discover-home` shows its entry below All playlists. The instructional footer stays removed.
- Home restores Discover on startup and prepares the current edition for opted-in sources. Its sleeves show recommendation artwork only (saved picks while refreshing, neutral covers before any edition); never substitute source-playlist artwork.
- Keep Home top-aligned, including `--discover-home` launches. A bottom default scroll anchor creates a large gap above short Home lists.
- Artist photos extend behind the navigation bar with the top scroll edge effect hidden. Check both `--artist` and `--player-artist` (inside the player sheet).
- Tapping the full player's song title opens its album; the artist name opens its artist. Preserve exact album metadata in both App Remote and Web API playback states. `--player-album` opens that album inside the player for testing; Back returns to uninterrupted playback.
- Song press-and-hold menus and three-dot menus include See Album when album metadata is available. Route it through the current stack, including the queue and player sheets, so Back returns to the original surface.
- Apply `.songAlbumNavigation(path:)` outside every NavigationStack. Putting that environment action on only the root content hides See Album in pushed destinations.
- Keep the mini player visible on catalog pages pushed inside player or queue sheets. Inside the player, tapping the mini player returns to the existing full player. Album headers use fetched album metadata, with current playback artwork as a temporary fallback for App Remote routes.
- Cover corners use 24% of their size. Header cover zoom transitions must explicitly use the same rounded shape and a clear source background so interactive dismissal never reveals a square behind the cover.

## Lyrics

- The player’s icon-only lyrics button toggles the live line beneath the artist, aligned left. Long-press → Open full lyrics opens the full-screen view; X or dragging down from its header dismisses it. Fetch on demand from LRCLIB’s public `/api/get` endpoint; only song metadata goes to LRCLIB, never Spotify credentials.
- `Lyrics.swift` verifies title, artist and duration before using a match, parses LRC timing, and holds a bounded memory-only cache. Do not substitute a different recording when lyrics are missing.
- `AppModel` owns `LyricsState` so closing the player preserves pending requests, results and its bounded session cache. `LiveLyrics.swift` and `LyricsSheet.swift` share it; cached songs restore synchronously without a loading flash. The live-lyrics toggle persists in `player.showsLiveLyrics`. Stale song lookups cancel and errors support retry. The full view follows playback, supports tapping a timed line to seek, and pauses following when manually scrolled. Plain lyrics, instrumentals, missing results and network errors have separate states.
- Lyric lines use a quick 160 ms ease-out crossfade with stable text identity, plus 100 ms playback sampling. Full-screen highlighting and following use the same fast easing; respect Reduce Motion.
- With live lyrics on, the artwork absorbs spare player height; never put a flexible spacer between the lyric and scrubber. Keep a stable lyric region so the controls don't move as lines change.
- `SampleLyrics.swift` contains original sample words for `DemoMusic`. Test parsing and service behavior with `tests/run-lyrics-tests.sh`; `scripts/run-on-iphone.sh --lyrics` opens full lyrics; `--live-lyrics` opens the player with its live line enabled.
