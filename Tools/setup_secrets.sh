#!/bin/bash
#
# Put the credentials the release workflow needs into GitHub Actions secrets.
#
# Run this once now, and again whenever the Developer ID certificate is
# reissued — Apple's expire yearly, and a release job that fails at the signing
# step is usually just this.
#
# It does not touch SPARKLE_PRIVATE_KEY. That key is generated once, lives in
# the login Keychain, and never changes: losing it means no existing install
# can be updated again, because they only accept builds signed by its
# counterpart.
#
# Usage: Tools/setup_secrets.sh <path-to-DeveloperID.p12>
#
# To produce that .p12, in Keychain Access:
#   1. Select the login keychain, then My Certificates.
#   2. Right-click "Developer ID Application: <your name> (TEAMID)" → Export.
#   3. Save as Personal Information Exchange (.p12) and set a password.
#
# Export from Keychain Access rather than the command line because `security
# export` takes every identity in the keychain at once, and the Apple
# Development certificate has no business being in a CI secret.

set -euo pipefail

P12="${1:?usage: setup_secrets.sh <path-to-DeveloperID.p12>}"
REPO="${REPO:-realAndi/betterTextEdit}"

if [[ ! -f "$P12" ]]; then
    echo "error: no .p12 at $P12" >&2
    exit 1
fi

if ! command -v gh >/dev/null; then
    echo "error: the GitHub CLI (gh) is not installed" >&2
    exit 1
fi

echo "Setting secrets on $REPO"
echo

# -s so nothing typed here lands in the terminal scrollback or shell history.
read -rsp "Password you set when exporting the .p12: " P12_PASSWORD; echo
read -rp  "Apple ID (the one that owns the certificate): " APPLE_ID
read -rsp "App-specific password from appleid.apple.com: " APP_PASSWORD; echo

# The team id is already in the certificate's name — no need to ask for
# something that can be read.
TEAM_ID="$(security find-identity -v -p codesigning \
    | grep 'Developer ID Application' \
    | head -1 \
    | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/')"

if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    read -rp "Team ID (10 characters): " TEAM_ID
else
    echo "Team ID, read from the certificate: $TEAM_ID"
fi

echo
# Piped rather than passed as arguments: a command line is visible to every
# other process on the machine while it runs.
base64 -i "$P12" | gh secret set DEVELOPER_ID_CERT_P12 --repo "$REPO"
printf '%s' "$P12_PASSWORD"  | gh secret set DEVELOPER_ID_CERT_PASSWORD --repo "$REPO"
printf '%s' "$APPLE_ID"      | gh secret set APPLE_ID --repo "$REPO"
printf '%s' "$TEAM_ID"       | gh secret set APPLE_TEAM_ID --repo "$REPO"
printf '%s' "$APP_PASSWORD"  | gh secret set APPLE_APP_PASSWORD --repo "$REPO"

echo
echo "Done. Secrets now on $REPO:"
gh secret list --repo "$REPO"
echo
echo "Cut a release with:  git tag v1.0.0 && git push origin v1.0.0"
