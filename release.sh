#!/bin/bash
# Publishes the version in VERSION as a GitHub release. Installed copies of LidGlass update
# to it, but only if it is signed with the same certificate they were signed with.
set -euo pipefail
cd "$(dirname "$0")"

# One commit, pinned before anything else, is what gets versioned, built, and tagged. HEAD
# can move while the build runs.
COMMIT="$(git rev-parse HEAD)"
VERSION="$(git show "$COMMIT:VERSION" | tr -d '[:space:]')"
TAG="v$VERSION"
REPO="jwhitlow45/lidglass"
# Built apart from build/LidGlass.app, so publishing never replaces the copy in use. That
# copy updates like any installed one.
BUILD_DIR="build/release"
APP="$BUILD_DIR/LidGlass.app"
ARCHIVE="$BUILD_DIR/LidGlass.zip"

# The release is the committed source only, so uncommitted changes would be left out.
if ! git diff --quiet "$COMMIT" --; then
    echo "uncommitted changes: commit them first, the release is built from HEAD"
    exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "release $TAG already exists: bump VERSION first"
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null &&
   [ "$(git rev-parse "$TAG^{commit}")" != "$COMMIT" ]; then
    echo "tag $TAG already points at another commit: bump VERSION first"
    exit 1
fi

# Built from an export of the pinned commit rather than the working copy, so the release
# holds exactly the tagged source: an untracked file cannot slip into the archive.
EXPORT="$(mktemp -d)"
trap 'rm -rf "$EXPORT"' EXIT
git archive "$COMMIT" | tar -x -C "$EXPORT"
(cd "$EXPORT" && LIDGLASS_BUILD_DIR=build/release ./build-app.sh)
mkdir -p "$BUILD_DIR"
rm -rf "$APP"
ditto "$EXPORT/build/release/LidGlass.app" "$APP"

# An ad-hoc signature names no certificate, so no installed copy would accept the update.
if ! codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf"; then
    echo "$APP is not signed with a certificate: run ./create-signing-identity.sh first"
    exit 1
fi

rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    git tag -s "$TAG" -m "LidGlass $VERSION" "$COMMIT"
fi
git push origin "$TAG"
gh release create "$TAG" "$ARCHIVE" --repo "$REPO" --title "LidGlass $VERSION" --generate-notes
