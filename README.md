# Spotify Unslopified for iOS

A native Spotify remote with your chosen playlists, search, albums, artists, and a player.

## Queue

- Tap **···** beside any song, including search results, album tracks, artist tracks, playlist tracks, and the current song. Choose **Add to queue**. The same menu retains **Add to playlist**.
- Swipe right to queue any song.
- The list-plus control beside Play adds all loaded album or playlist songs in order. Long-press album covers or your editable Home/library playlists to queue a collection.
- Open **Queue** with the list icon on Home, the mini player, or the full player. It shows **Now playing** and **Next up**, refreshes while open, and supports pull-to-refresh.

Queue additions go to Spotify, without starting or replacing the current song. Bulk additions stop on the first failure and report how many succeeded. Spotify's development-mode API only provides playlist contents for playlists you own or collaborate on, so other playlists cannot be queued as a collection here.

Spotify exposes [queue reading](https://developer.spotify.com/documentation/web-api/reference/get-queue) and [adding tracks/episodes](https://developer.spotify.com/documentation/web-api/reference/add-to-queue). Reordering and removing queue items still require Spotify. The view shows the upcoming items Spotify returns; it does not invent a separate local queue.

## Build and verify

```sh
xcodebuild -project Focused.xcodeproj -scheme Focused -destination 'generic/platform=iOS Simulator' build
scripts/run-on-iphone.sh --queue
tests/run-queue-tests.sh
```

`--preview` uses sample music. Bundle ID, Xcode target, URL scheme, and Keychain identifiers retain their original names so existing installs and Spotify sign-in continue working. The installed app and visible branding are **Spotify Unslopified**.

## Verification (October 7, 2026)

Simulator and signed device builds passed. Installed and launched on Noah's iPhone. Through iPhone Mirroring, verified the new Home name, a real queue read, adding Bags from search while Softly continued playing, and opening Queue from both players. The standalone queue checks cover ordering, duplicate songs, preserving context, Next, and adding with no active preview playback. Album/bulk controls compile; those specific live actions were not exercised.
