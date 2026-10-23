# Development

Open `Focused.xcodeproj` in Xcode 26 or newer. Dependencies resolve through Swift Package Manager.

For command-line builds:

```sh
xcodebuild -project Focused.xcodeproj -scheme Focused \
  -destination 'generic/platform=iOS Simulator' build
```

For a connected iPhone, configure signing first, then either run from Xcode or use:

```sh
DEVICE_UDID=your_device_id scripts/run-on-iphone.sh --preview
```

Find the ID with `xcrun xctrace list devices`. Optional local defaults go in `scripts/device.local.sh` (ignored by Git). The script reads the bundle identifier from the built app. Run it without `--preview` for Spotify.

Focused checks:

```sh
for check in tests/run-*-tests.sh; do zsh "$check" || exit 1; done
```

The sample-music preview works without Spotify or a network connection. Debug launch arguments include `-preview`, `-openNowPlaying`, `-liveLyrics`, `-openLyrics`, `-openQueue`, and `-openLyricsSearch`.

See [AGENTS.md](../AGENTS.md) for architecture and interaction conventions. Small, focused contributions and reproducible bug reports are welcome. Include the iOS version, screen involved, and steps to reproduce; don't post tokens or account details.

## Third-party services

The MIT license covers this project's code. [Spotify's iOS SDK](https://github.com/spotify/ios-sdk) is a separately licensed dependency. Access to Spotify, LRCLIB, and Genius remains subject to each service's terms and availability.
