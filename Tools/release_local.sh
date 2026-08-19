#!/bin/bash
#
# Cut a complete release from this Mac, without CI.
#
# Does exactly what .github/workflows/release.yml does, in the same order and
# with the same scripts — build, sign, notarise, package, notarise again, sign
# for Sparkle, publish the release and the appcast. The only difference is
# where the credentials come from: the Developer ID certificate and the Sparkle
# key are already in your login Keychain, so the only thing that has to be
# arranged is notarisation.
#
#     xcrun notarytool store-credentials betterTextEdit \
#         --apple-id <you@example.com> --team-id UP8MGDBQ7Q --password <app-specific>
#
# That is asked for once, ever. Afterwards:
#
#     Tools/release_local.sh 1.0.0
#
# The tag is pushed last, once everything else has already succeeded, so a
# failure halfway through leaves no tag claiming a release that doesn't exist.
# The CI workflow notices the release is already published and stands down, so
# the two paths can coexist without racing to publish the same version twice.

set -euo pipefail

VERSION="${1:?usage: release_local.sh <version>, e.g. 1.0.0}"
TAG="v$VERSION"
REPO="${REPO:-realAndi/betterTextEdit}"
NOTARY_PROFILE="${NOTARY_PROFILE:-betterTextEdit}"
export NOTARY_PROFILE

cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# --- Refuse to start unless everything needed is actually present ------------
#
# All of it checked up front rather than discovered three minutes into a build,
# because most of these are one-time setup steps and finding out about them
# individually, slowly, is the worst way to learn them.

say "Checking…"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "'$VERSION' is not MAJOR.MINOR.PATCH"

[[ -z "$(git status --porcelain)" ]] \
    || die "working tree has uncommitted changes; commit or stash them first"

gh auth status >/dev/null 2>&1 \
    || die "not logged in to GitHub; run: gh auth login"

# A published release is the thing that can't be redone — the .dmg is already
# out there and its signature is already recorded in the appcast. An existing
# *tag* is fine, and expected: it may have been pushed ahead of the release, or
# left behind by a run that failed further down.
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
    && die "$TAG is already released on $REPO"

if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    [[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] \
        || die "$TAG already exists but points at a different commit than HEAD.
    This would ship a build that isn't what the tag names. Either check out the
    tag, or move it deliberately with: git tag -f $TAG"
    REUSING_TAG=yes
    echo "  reusing the existing $TAG"
else
    REUSING_TAG=no
fi

IDENTITY="$(security find-identity -v -p codesigning \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/')"
[[ -n "$IDENTITY" ]] \
    || die "no Developer ID Application certificate in the Keychain"

# On a Developer ID certificate the name ends in "(TEAMID)", so the team is
# already known — no need to ask for something that can be read.
TEAM_ID="$(sed -E 's/.*\(([A-Z0-9]{10})\)$/\1/' <<<"$IDENTITY")"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
    || die "could not read a team id out of '$IDENTITY'"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no notarisation profile '$NOTARY_PROFILE'. Create it once with:
    xcrun notarytool store-credentials $NOTARY_PROFILE \\
        --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific>"

grep -q "$VERSION" CHANGELOG.md \
    || echo "  note: CHANGELOG.md has no section for $VERSION; it will ship without notes"

BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "  identity     $IDENTITY"
echo "  version      $VERSION (build $BUILD_NUMBER)"
echo "  repository   $REPO"

# --- Build -------------------------------------------------------------------

ARCHIVE="$WORK/betterTextEdit.xcarchive"
APP="$ARCHIVE/Products/Applications/betterTextEdit.app"
DMG="$WORK/betterTextEdit-$VERSION.dmg"

say "Building ${VERSION}…"
xcodebuild archive \
    -project betterTextEdit.xcodeproj \
    -scheme betterTextEdit \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$ROOT/build/DerivedData" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    | { command -v xcbeautify >/dev/null && xcbeautify || cat; }

say "Signing…"
Tools/sign_app.sh "$APP" "$IDENTITY"

# The app is notarised and stapled before the image is built around it, so a
# copy dragged out carries its own ticket and opens even offline.
say "Notarising the app… (this waits on Apple, usually a minute or two)"
Tools/notarize.sh "$APP"

say "Building the disk image…"
Tools/make_dmg.sh "$APP" "$DMG" "$IDENTITY"

say "Notarising the disk image…"
Tools/notarize.sh "$DMG"

say "Checking it the way a user's Mac will…"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

# --- Sign for Sparkle --------------------------------------------------------

say "Signing the update for Sparkle…"
SIGN_UPDATE="$(find "$ROOT/build/DerivedData/SourcePackages/artifacts" \
    -name sign_update -type f -perm -u+x | head -1)"
[[ -n "$SIGN_UPDATE" ]] || die "could not find Sparkle's sign_update"

# No key file: sign_update reads the private key straight out of the login
# Keychain, so it never touches the disk.
SIGNATURE="$("$SIGN_UPDATE" -p "$DMG")"
LENGTH="$(stat -f%z "$DMG")"
echo "  signature $SIGNATURE"

# --- Publish -----------------------------------------------------------------

say "Publishing the release…"
NOTES="$WORK/notes.md"
python3 - "$VERSION" > "$NOTES" <<'PY'
import sys, pathlib
sys.path.insert(0, "Tools")
from update_appcast import extract_section
text = pathlib.Path("CHANGELOG.md").read_text(encoding="utf-8")
print(extract_section(text, sys.argv[1]) or "See CHANGELOG.md for details.")
PY

# Created here but not pushed until the very end, so a failure earlier leaves
# no tag claiming a release that doesn't exist.
[[ "$REUSING_TAG" == yes ]] || git tag -a "$TAG" -m "betterTextEdit $VERSION"

gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "betterTextEdit $VERSION" \
    --notes-file "$NOTES" \
    --target "$(git rev-parse HEAD)"

say "Publishing the appcast…"
PAGES="$WORK/pages"
mkdir -p "$PAGES"

# Start from what's already published so past releases stay in the feed.
if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    git fetch --depth 1 origin gh-pages
    git archive FETCH_HEAD | tar -x -C "$PAGES"
fi

MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo 26.0)"

python3 Tools/update_appcast.py \
    --appcast "$PAGES/appcast.xml" \
    --short-version "$VERSION" \
    --build "$BUILD_NUMBER" \
    --url "https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")" \
    --length "$LENGTH" \
    --signature "$SIGNATURE" \
    --min-system "$MIN_SYSTEM" \
    --notes CHANGELOG.md

cp Tools/pages_index.html "$PAGES/index.html"

(
    cd "$PAGES"
    git init -q -b gh-pages
    git add -A
    git commit -qm "Publish appcast for $TAG"
    git push -qf "https://github.com/$REPO.git" gh-pages
)

say "Pushing the tag…"
# `gh release create` creates the tag on the remote itself when it isn't there
# yet, so by this point it usually already exists — which is a success, not the
# failure a bare `git push` would print. Only push when the remote genuinely
# lacks it, and fetch it back either way so the local ref matches.
if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
    echo "  already on the remote (created with the release)"
    git fetch -q --tags origin
else
    git push origin "$TAG"
fi

say "Released $VERSION"
echo "  download  https://github.com/$REPO/releases/tag/$TAG"
echo "  feed      https://realandi.github.io/betterTextEdit/appcast.xml"
echo
echo "Existing installs will offer this update within a day."
