#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
api_test_binary="$(mktemp -t spotify-api-tests)"
trap 'rm -f "$api_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Spotify/SpotifyModels.swift \
  Focused/Spotify/SpotifyAPI.swift tests/SpotifyAPITests.swift -o "$api_test_binary"
"$api_test_binary"
