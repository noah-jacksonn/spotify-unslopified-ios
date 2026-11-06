---
name: import-suno-music
description: Download the user's requested or newly liked Suno songs through their signed-in Chrome session and import them into the shared Spotify Unslopified music folder. Use for requests such as "get my new liked Suno songs" or "import this song from Suno"; not for generating music or adding Spotify catalog tracks.
---

# Import Suno music

One shared folder supplies both Spotify Unslopified for Chrome and the iPhone app. Import the audio and its metadata once; iCloud handles delivery. This skill prepares no releases and does not rebuild either app.

## Destination and existing songs

Noah's established library root is `~/Library/Mobile Documents/com~apple~CloudDocs/Unslopified Music`; its `Suno` subfolder is the default destination. Verify it exists. Honor a different playlist or folder named in the request or shown in the current app settings. Select the parent library in the apps, not the individual playlist subfolder.

Run the read-only inventory before downloading:

```sh
python3 <skill-dir>/scripts/index_library.py --playlist "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Unslopified Music/Suno"
```

Use `known_suno_ids` to skip existing songs in that destination. Source IDs, not titles or creation dates, identify versions. Two songs can share a title; an older song can be newly liked. If metadata is still downloading or corrupt, resolve that ambiguity before treating those files as absent. For unlinked audio, inspect embedded metadata or compare audio hashes when needed; do not identify a song by title alone. An archived destination needs an explicit restore or a different active playlist; do not silently import into it or unarchive it.

## Find and download

Use the available computer-use browser tooling to access the user's existing Chrome session. Inspect its current state and follow that tool's documentation. Reuse a signed-in `suno.com` tab; if necessary, open Suno and let the user sign in. The skill does not grant permission to change security settings, bypass restrictions or extract login tokens.

- **A song link or a particular song:** open that exact song and confirm its identity. If only a title was supplied and several versions match, clarify which one.
- **New liked songs:** inspect the user's Suno library with its thumbs-up/liked filter. Enumerate the full requested set, including pagination or virtual scrolling. Track observed song URLs while scrolling; do not stop at the first already-imported song or use a creation-date cutoff.
- Collect the canonical `https://suno.com/song/<UUID>`, displayed title, creation date and duration when available. Preserve the creator/artist if requested; otherwise the existing library convention is `Suno`.
- Use Suno's own audio Download action. Prefer compressed audio such as MP3/M4A unless another format was requested. Do not purchase upgrades or switch to paid stems/WAV options without authorization.
- A disabled or unavailable Download action is a skipped song, not permission to extract protected media by another route. Do not assume the reason is "remix" unless Suno actually says so.

Snapshot Downloads before each download and associate the completed new file with that exact song. Account for duplicate filenames and unfinished `.crdownload` files. If the mapping is unclear, stop that file's import and resolve it; do not guess by filename order. Inspect a downloaded file's embedded Suno ID, when present, as an additional cross-check.

## Import without losing edits

Immediately before writing, recheck the target inventory. Copy only missing songs into the playlist folder. Never replace an existing audio file or user-edited sidecar. Use exclusive file creation or a no-overwrite publish; on collisions choose a new filename, preferably including the song ID. Preserve the downloaded original.

Create `<exact audio filename>.json` beside each new audio file, using the portable fields:

```json
{
  "title": "Observed song title",
  "artist": "Suno",
  "sourceURL": "https://suno.com/song/<observed UUID>",
  "importedAt": "<current ISO-8601 timestamp>"
}
```

Add `createdAt`, `durationMs`, `lyrics` or `artworkFile` only when actually available. Creation date comes from Suno or trustworthy embedded metadata, not the download's filesystem timestamp. If only the calendar date is visible, preserve that date with an explicit timezone and do not claim an exact source creation time. Do not invent dates, lyrics or artwork. Keep existing playlist covers, order and Home choices intact.

Verify that the copied audio matches the download byte-for-byte and is valid audio (for example with `ffprobe`, if installed). Check the JSON parses and its source ID matches the intended song. Remove only incomplete artifacts created by this run if a copy fails; leave existing files untouched. Re-run the inventory to confirm the newly imported IDs.

## Refresh, lyrics and iCloud

Keep a signed-in Suno tab open. The extension uses saved source links to fill missing timed lyrics; importing plain audio does not identify its Suno source automatically. Refresh the connected imported library through its visible UI when accessible. The extension also checks for missing lyrics periodically; do not duplicate this by harvesting tokens or adding a separate authentication system.

If browser tooling cannot access an extension page, do not bypass that restriction. Finish the file import and report that a manual library refresh is still needed. If permission expired, the explicit Reconnect action is the appropriate recovery; never alter Chrome security settings to suppress its permission prompt.

Check iCloud delivery with the read-only helper, passing the newly written audio and sidecar paths:

```sh
swift <skill-dir>/scripts/cloud_status.swift <audio-path> <sidecar-path>
```

`uploaded: true` confirms upload from this Mac, not download onto the phone. The iPhone app refreshes its selected folder while active and keeps its own downloaded playback copies. If upload is pending, report that honestly; do not announce that the songs are already available offline on iPhone. Do not take over the phone just to test a routine import.

Leave Downloads alone unless cleanup is requested. When authorized, move only this run's verified duplicate downloads to Trash after their matching library copies have uploaded; do not permanently delete or touch unrelated downloads.

Report briefly: imported songs, already-present songs, unavailable downloads, and whether lyrics or iCloud delivery are still pending. An import request is not authorization to change likes, publish songs, share the library, or modify unrelated playlists.
