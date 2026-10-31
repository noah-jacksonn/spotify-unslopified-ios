#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
combined_test_binary="$(mktemp -t spotify-combined-music-tests)"
trap 'rm -f "$combined_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Spotify/SpotifyModels.swift \
  Focused/Model/MusicService.swift Focused/Model/DemoMusic.swift \
  Focused/Model/CombinedMusic.swift tests/CombinedMusicTests.swift -o "$combined_test_binary"
"$combined_test_binary"
