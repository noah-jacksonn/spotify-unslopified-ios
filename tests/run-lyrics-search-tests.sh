#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
lyrics_search_test_binary="$(mktemp -t spotify-lyrics-search-tests)"
trap 'rm -f "$lyrics_search_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Spotify/SpotifyModels.swift \
  Focused/Model/MusicService.swift Focused/Model/DemoMusic.swift \
  Focused/Model/LyricsSearch.swift tests/LyricsSearchTests.swift -o "$lyrics_search_test_binary"
"$lyrics_search_test_binary"
