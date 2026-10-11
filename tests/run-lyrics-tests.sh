#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
lyrics_test_binary="$(mktemp -t spotify-lyrics-tests)"
trap 'rm -f "$lyrics_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Spotify/SpotifyModels.swift \
  Focused/Model/Lyrics.swift tests/LyricsTests.swift -o "$lyrics_test_binary"
"$lyrics_test_binary"
