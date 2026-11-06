#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
order_test_binary="$(mktemp -t playlist-order-tests)"
trap 'rm -f "$order_test_binary"' EXIT
xcrun swiftc -parse-as-library Focused/Model/PlaylistOrder.swift tests/PlaylistOrderTests.swift -o "$order_test_binary"
"$order_test_binary"
