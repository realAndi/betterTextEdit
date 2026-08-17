#!/bin/bash
#
# Send something to Apple to be notarised, wait for the verdict, and staple the
# ticket to it.
#
# Notarisation is Apple scanning the signed code and recording its hash as
# known-good. Stapling then attaches the resulting ticket to the file, so
# Gatekeeper can approve it without going online — which matters for a user on
# a bad connection, and for the first launch after Sparkle installs an update.
#
# Run it twice per release: once on the .app, then again on the .dmg built
# around the now-stapled app. Notarising only the image would leave the copy
# the user drags out without a ticket of its own.
#
# Credentials arrive one of two ways.
#
# Locally, set NOTARY_PROFILE to the name of a profile saved once with:
#
#     xcrun notarytool store-credentials betterTextEdit \
#         --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific>
#
# which keeps the password in the login Keychain so it's typed once ever
# rather than once per release.
#
# On CI there's no Keychain to save it in, so the three values come from the
# environment instead — never the command line, since arguments are visible to
# every other process on the machine:
#   APPLE_ID            the Apple ID that owns the Developer ID certificate
#   APPLE_TEAM_ID       the 10-character team identifier
#   APPLE_APP_PASSWORD  an app-specific password from appleid.apple.com
#
# Usage: Tools/notarize.sh <path-to-.app-or-.dmg>

set -euo pipefail

TARGET="${1:?usage: notarize.sh <app-or-dmg>}"

# Built as an array so the password, when there is one, is passed as a single
# argument no matter what characters Apple put in it.
if [[ -n "${NOTARY_PROFILE-}" ]]; then
    CREDENTIALS=(--keychain-profile "$NOTARY_PROFILE")
else
    : "${APPLE_ID:?set NOTARY_PROFILE, or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD}"
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is not set}"
    : "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is not set}"
    CREDENTIALS=(
        --apple-id "$APPLE_ID"
        --team-id "$APPLE_TEAM_ID"
        --password "$APPLE_APP_PASSWORD"
    )
fi

if [[ ! -e "$TARGET" ]]; then
    echo "error: nothing at $TARGET" >&2
    exit 1
fi

# notarytool takes a zip, dmg or pkg — never a bare .app — so an app bundle is
# zipped for submission. The ticket still staples to the original bundle
# afterwards; the zip is only a transport.
SUBMIT="$TARGET"
CLEANUP=""
if [[ "$TARGET" == *.app ]]; then
    SUBMIT="${TMPDIR:-/tmp}/$(basename "$TARGET").zip"
    CLEANUP="$SUBMIT"
    # keepParent so the archive contains the .app itself rather than its guts.
    ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi
trap '[[ -n "$CLEANUP" ]] && rm -f "$CLEANUP"' EXIT

echo "Submitting $(basename "$SUBMIT") to Apple…"

# --wait blocks until Apple has decided. Capturing the JSON rather than letting
# it stream means the submission id is available to fetch the log with, which
# is the only thing that says *why* a rejection happened.
RESULT="$(xcrun notarytool submit "$SUBMIT" \
    "${CREDENTIALS[@]}" \
    --wait --output-format json)" || true

echo "$RESULT"

read_field() {
    printf '%s' "$RESULT" | python3 -c \
        "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || true
}

STATUS="$(read_field status)"
SUBMISSION_ID="$(read_field id)"

if [[ "$STATUS" != "Accepted" ]]; then
    echo "error: notarisation came back '$STATUS'" >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
        echo "--- Apple's log ---" >&2
        xcrun notarytool log "$SUBMISSION_ID" "${CREDENTIALS[@]}" >&2 || true
    fi
    exit 1
fi

echo "Accepted. Stapling the ticket to $(basename "$TARGET")…"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
