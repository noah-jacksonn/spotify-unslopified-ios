#!/bin/zsh
# Print the segtest picks currently saved on Noah's iPhone.
#
# Every SegtestRow saves its selection to the app's UserDefaults as
# segtest.pick.<segtest id>.<row title> = <segment label> (see
# Focused/Design/DebugSegtestPanel.swift). This copies the app's
# preferences plist off the phone and prints those keys, so the picks can
# be adopted without Noah reporting them.
#
# Usage:
#   scripts/read-segtest.sh            every saved pick
#   scripts/read-segtest.sh <id>       only one segtest's picks
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$PROJECT_DIR/scripts/device.local.sh" ]; then
  source "$PROJECT_DIR/scripts/device.local.sh"
fi
: "${COREDEVICE_ID:=${DEVICE_UDID:-}}"
: "${BUNDLE_ID:?Set BUNDLE_ID to your app's bundle identifier}"
: "${COREDEVICE_ID:?Set COREDEVICE_ID or DEVICE_UDID to your iPhone ID}"
FILTER="segtest.pick.${1:+$1.}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

xcrun devicectl device copy from --device "$COREDEVICE_ID" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source "Library/Preferences/$BUNDLE_ID.plist" \
  --destination "$TMP/prefs.plist" >/dev/null

/usr/bin/python3 -c '
import plistlib, sys
prefix = sys.argv[1]
with open(sys.argv[2], "rb") as source:
    prefs = plistlib.load(source)
picks = sorted((k[len("segtest.pick."):], v) for k, v in prefs.items() if k.startswith(prefix))
if not picks:
    print("No saved segtest picks" + (" for " + prefix[len("segtest.pick."):-1] if prefix != "segtest.pick." else ""))
for key, value in picks:
    test, _, row = key.partition(".")
    print(f"{test} | {row}: {value}")
print("appearance: " + str(prefs.get("appearanceOverride", "system")))
' "$FILTER" "$TMP/prefs.plist"
