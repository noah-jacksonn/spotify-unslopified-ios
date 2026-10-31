#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
test_binary="$(mktemp -t focused-shared-folder)"
trap 'rm -f "$test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Model/CoverEdit.swift Focused/Model/SharedMusicFolder.swift tests/SharedMusicFolderTests.swift -o "$test_binary"
"$test_binary"
