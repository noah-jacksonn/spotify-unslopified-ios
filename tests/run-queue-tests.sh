#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
queue_test_binary="$(mktemp -t spotify-queue-tests)"
trap 'rm -f "$queue_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Spotify/SpotifyModels.swift \
  Focused/Model/MusicService.swift Focused/Model/DemoMusic.swift \
  tests/QueueTests.swift -o "$queue_test_binary"
"$queue_test_binary"
