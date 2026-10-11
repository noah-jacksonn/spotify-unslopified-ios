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

COREDEVICE_ID="BF5B23E2-66F6-5CA2-8075-A22B8907BFEE"  # Noah's iPhone 17 Pro
BUNDLE_ID="com.harmonyappai.FocusedSpotify"
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
