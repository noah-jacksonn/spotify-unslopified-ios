#!/bin/zsh
# Build Focused for a connected iPhone, install it, and launch it — Cmd+R without
# Xcode. Adapted from harmony-ios. Requires the phone to be connected (cable
# or paired Wi-Fi) and unlocked for the install step.
#
# Usage:
#   scripts/run-on-iphone.sh                 build, install, launch
#   scripts/run-on-iphone.sh --preview       launch into the sample-music preview
#   scripts/run-on-iphone.sh --search        open Search
#   scripts/run-on-iphone.sh --lyrics-search open Search with lyrics enabled
#   scripts/run-on-iphone.sh --discover      open Discover
#   scripts/run-on-iphone.sh --discover-home open Home with its Discover entry
#   scripts/run-on-iphone.sh --queue         open the queue
#   scripts/run-on-iphone.sh --library       open All playlists
#   scripts/run-on-iphone.sh --playlist      open the first Home playlist
#   scripts/run-on-iphone.sh --play          start the first Home playlist (mini player)
#   scripts/run-on-iphone.sh --artist        open the first artist a search finds
#   scripts/run-on-iphone.sh --player-artist open the current artist inside the player
#   scripts/run-on-iphone.sh --player-album  open the current album inside the player
#   scripts/run-on-iphone.sh --album         open that artist's first album
#   scripts/run-on-iphone.sh --loader        preview mode, holding Home's loader for 6 s
#   scripts/run-on-iphone.sh --cover         open the first Home playlist's cover full screen
#   scripts/run-on-iphone.sh --lyrics        open full lyrics for the current song
#   scripts/run-on-iphone.sh --live-lyrics   show the current line in the player
#   scripts/run-on-iphone.sh --now-playing   open the full player (starts music)
#   scripts/run-on-iphone.sh --sleep         open the sleep timer
#   scripts/run-on-iphone.sh --console       stream stdout/stderr (combinable)
#
# Screen flags open the app directly on the surface under test, backed by
# Debug launch arguments in RootView. Add one per new surface.
set -e

CONSOLE=0
APP_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --console) CONSOLE=1 ;;
    --preview) APP_ARGS+=(-preview) ;;
    --search) APP_ARGS+=(-openSearch) ;;
    --lyrics-search) APP_ARGS+=(-openLyricsSearch) ;;
    --queue) APP_ARGS+=(-openQueue) ;;
    --daily-five|--discover) APP_ARGS+=(-openDailyFive) ;;
    --discover-home) ;; # Home is the default; keep its normal top alignment.
    --library) APP_ARGS+=(-openLibrary) ;;
    --playlist) APP_ARGS+=(-openPlaylist) ;;
    --play) APP_ARGS+=(-autoplay) ;;
    --artist) APP_ARGS+=(-openArtist) ;;
    --player-artist) APP_ARGS+=(-openPlayerArtist) ;;
    --player-album) APP_ARGS+=(-openPlayerAlbum) ;;
    --album) APP_ARGS+=(-openAlbum) ;;
    --loader) APP_ARGS+=(-preview -slowLoad) ;;
    --cover) APP_ARGS+=(-openPlaylist -openCover) ;;
    --edit-cover) APP_ARGS+=(-openPlaylist -editPlaylistCover) ;;
    --now-playing) APP_ARGS+=(-openNowPlaying) ;;
    --lyrics) APP_ARGS+=(-openLyrics) ;;
    --live-lyrics) APP_ARGS+=(-liveLyrics) ;;
    --sleep) APP_ARGS+=(-openSleepTimer) ;;
    *) echo "✗ Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Optional personal device defaults, never committed.
if [ -f "$PROJECT_DIR/scripts/device.local.sh" ]; then
  source "$PROJECT_DIR/scripts/device.local.sh"
fi
if [ -z "${DEVICE_UDID:-}" ]; then
  echo 'Set DEVICE_UDID to your iPhone ID from: xcrun xctrace list devices' >&2
  echo 'Or select your iPhone in Xcode and press Cmd+R.' >&2
  exit 1
fi
COREDEVICE_ID="${COREDEVICE_ID:-$DEVICE_UDID}"

cd "$PROJECT_DIR"

echo "▸ Building for device…"
# No -derivedDataPath: shares Xcode's own build cache, so Cmd+R in Xcode and
# this script keep each other's builds incremental. pipefail so a failed
# build is never followed by installing the previous one.
setopt pipefail
xcodebuild -project Focused.xcodeproj -scheme Focused \
  -destination "platform=iOS,id=$DEVICE_UDID" \
  -allowProvisioningUpdates \
  build | grep -E "error:|warning: .*deprecated|BUILD" \
  || { echo "✗ Build failed; not installing" >&2; exit 1; }
unsetopt pipefail

APP_PATH="$(xcodebuild -project Focused.xcodeproj -scheme Focused \
  -destination "platform=iOS,id=$DEVICE_UDID" -showBuildSettings 2>/dev/null \
  | awk '$1 == "BUILT_PRODUCTS_DIR" { print $3; exit }')/Focused.app"
if [ ! -d "$APP_PATH" ]; then
  echo "✗ Build product not found at $APP_PATH" >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist")"

echo "▸ Installing on iPhone…"
xcrun devicectl device install app --device "$COREDEVICE_ID" "$APP_PATH"

echo "▸ Launching…"
if [ ${#APP_ARGS[@]} -gt 0 ]; then echo "  (launch arguments: ${APP_ARGS[*]})"; fi
if [ "$CONSOLE" = 1 ]; then
  echo "  (streaming console — Ctrl-C to detach)"
  xcrun devicectl device process launch --terminate-existing --console \
    --device "$COREDEVICE_ID" "$BUNDLE_ID" -- "${APP_ARGS[@]}"
else
  xcrun devicectl device process launch --terminate-existing \
    --device "$COREDEVICE_ID" "$BUNDLE_ID" -- "${APP_ARGS[@]}"
  echo "✓ Running on iPhone (no logs — re-run with --console to stream them)"
fi
