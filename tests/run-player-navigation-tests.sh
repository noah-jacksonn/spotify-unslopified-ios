#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
navigation_test_binary="$(mktemp -t spotify-player-navigation-tests)"
trap 'rm -f "$navigation_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Spotify/SpotifyModels.swift \
  Focused/Model/MusicService.swift Focused/Model/DemoMusic.swift \
  tests/PlayerNavigationTests.swift -o "$navigation_test_binary"
"$navigation_test_binary"
