#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
daily_test_binary="$(mktemp -t spotify-daily-five-tests)"
trap 'rm -f "$daily_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Spotify/SpotifyModels.swift \
  Focused/Model/MusicService.swift Focused/Model/DemoMusic.swift \
  Focused/Model/DailyFive.swift tests/DailyFiveTests.swift -o "$daily_test_binary"
"$daily_test_binary"
