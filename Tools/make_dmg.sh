#!/bin/bash
#
# Wrap a signed betterTextEdit.app in the disk image that actually ships —
# both to someone clicking Download and to Sparkle installing an update.
#
# The app should already be signed, notarised and stapled by the time it gets
# here, so that a copy dragged out of this image carries its own notarisation
# ticket and opens even on a Mac that's offline.
#
# Usage: Tools/make_dmg.sh <path-to-.app> <output.dmg> [signing-identity]

set -euo pipefail

APP="${1:?usage: make_dmg.sh <app> <dmg> [identity]}"
DMG="${2:?usage: make_dmg.sh <app> <dmg> [identity]}"
IDENTITY="${3-}"

if [[ ! -d "$APP" ]]; then
    echo "error: no app bundle at $APP" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ditto rather than cp -R: it preserves the extended attributes and the code
# signature exactly, where cp can quietly drop metadata that the signature
# covers and invalidate it.
ditto "$APP" "$STAGE/$(basename "$APP")"

# The /Applications shortcut is what makes the mounted window a drag-and-drop
# install rather than a folder with one file in it.
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "betterTextEdit" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG"

# Signing the image too. Notarisation would accept an unsigned one, but a
# signed image is tamper-evident from the moment it's built rather than only
# once Apple has stapled it.
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
