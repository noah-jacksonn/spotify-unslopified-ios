#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
auth_test_binary="$(mktemp -t spotify-auth-tests)"
trap 'rm -f "$auth_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Config.swift Focused/Spotify/SpotifyAuth.swift \
  tests/SpotifyAuthTests.swift -o "$auth_test_binary"
"$auth_test_binary"
