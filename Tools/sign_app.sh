#!/bin/bash
#
# Sign betterTextEdit.app for distribution, from the inside out.
#
# macOS seals a bundle by hashing what's inside it, so signing an outer bundle
# before an inner one leaves the outer seal describing code that no longer
# exists. Sparkle makes this concrete: its framework contains two XPC services,
# a helper tool and a whole nested .app, and each has to be signed — deepest
# first — before the framework is, before the app is.
#
# Xcode does re-sign these during an archive build. This does it again anyway.
# `codesign --force` is idempotent, it costs a second, and it means the
# signature doesn't depend on Xcode continuing to behave that way. The failure
# mode is worth that second: Sparkle refuses to install an update whose helper
# is signed by a different team than the app, so a miss here breaks updating
# for everyone, and only after they've already installed the broken version.
#
# Usage: Tools/sign_app.sh <path-to-.app> <signing-identity>

set -euo pipefail

APP="${1:?usage: sign_app.sh <app> <identity>}"
IDENTITY="${2:?usage: sign_app.sh <app> <identity>}"

if [[ ! -d "$APP" ]]; then
    echo "error: no app bundle at $APP" >&2
    exit 1
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

# --options runtime turns on the hardened runtime, which notarisation requires.
# --timestamp gets a trusted timestamp from Apple, without which the signature
# stops verifying on the day the certificate expires rather than staying valid
# for everything signed while it was live.
sign() {
    echo "  $(basename "$1")"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$1"
}

if [[ -d "$SPARKLE" ]]; then
    echo "Signing Sparkle's helpers…"
    sign "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    sign "$SPARKLE/Versions/B/Autoupdate"
    sign "$SPARKLE/Versions/B/Updater.app"
    sign "$SPARKLE"
else
    echo "warning: no Sparkle.framework in $APP — updating will not work" >&2
fi

echo "Signing the app…"
sign "$APP"

# --deep --strict walks the whole bundle rather than trusting the outer seal,
# so a helper that was missed is caught here rather than by a user.
echo "Verifying…"
codesign --verify --deep --strict --verbose=2 "$APP"

echo
echo "Signed by:"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E '^Authority=|^TeamIdentifier=' || true
