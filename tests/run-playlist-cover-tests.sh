#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
cover_test_binary="$(mktemp -t playlist-cover-tests)"
trap 'rm -f "$cover_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Model/PlaylistCoverCrop.swift tests/PlaylistCoverTests.swift -o "$cover_test_binary"
"$cover_test_binary"
