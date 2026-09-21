#!/bin/bash
# Publishes the version in VERSION as a GitHub release. Installed copies of LidGlass update
# to it, but only if it is signed with the same certificate they were signed with.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
REPO="jwhitlow45/lidglass"
# Built apart from build/LidGlass.app, so publishing never replaces the copy in use. That
# copy updates like any installed one.
BUILD_DIR="build/release"
APP="$BUILD_DIR/LidGlass.app"
ARCHIVE="$BUILD_DIR/LidGlass.zip"

# The release is built from the working copy and tagged on HEAD, so they must match.
if ! git diff --quiet HEAD --; then
    echo "uncommitted changes: commit them first, the release is tagged on HEAD"
    exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "release $TAG already exists: bump VERSION first"
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null &&
   [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
    echo "tag $TAG already points at another commit: bump VERSION first"
    exit 1
fi

LIDGLASS_BUILD_DIR="$BUILD_DIR" ./build-app.sh

# An ad-hoc signature names no certificate, so no installed copy would accept the update.
if ! codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf"; then
    echo "$APP is not signed with a certificate: run ./create-signing-identity.sh first"
    exit 1
fi

rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    git tag -s "$TAG" -m "LidGlass $VERSION"
fi
git push origin "$TAG"
gh release create "$TAG" "$ARCHIVE" --repo "$REPO" --title "LidGlass $VERSION" --generate-notes
