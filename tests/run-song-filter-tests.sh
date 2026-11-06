#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
filter_test_binary="$(mktemp -t song-filter-tests)"
trap 'rm -f "$filter_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Model/SongFilter.swift tests/SongFilterTests.swift -o "$filter_test_binary"
"$filter_test_binary"
