#!/bin/bash
# Builds LidGlass.app, signed with the "LidGlass Local Signing" certificate when
# ./create-signing-identity.sh has made one, and ad-hoc otherwise.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LidGlass.app"
BUNDLE_ID="local.lidglass"
IDENTITY="LidGlass Local Signing"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/LidGlass"

# macOS grants Screen Recording to the signature's designated requirement. With the
# certificate that requirement stays the same across builds. Ad-hoc, it names the exact
# binary and changes with every code change. Keep the old one to tell.
designated_requirement() {
    # Ad-hoc signatures print their implied requirement as a comment.
    codesign -d -r- "$1" 2>&1 | sed -n 's/^\(# \)\{0,1\}designated => //p'
}
OLD_REQUIREMENT="$( [ -d "$APP" ] && designated_requirement "$APP" || true)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LidGlass"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>LidGlass</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>LidGlass</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    SIGNER="$IDENTITY"
else
    SIGNER="-"
    echo "no \"$IDENTITY\" certificate, signing ad-hoc: run ./create-signing-identity.sh to keep permission across rebuilds"
fi
codesign --force --sign "$SIGNER" --identifier "$BUNDLE_ID" "$APP" >/dev/null
echo "built $APP"

NEW_REQUIREMENT="$(designated_requirement "$APP")"
if [ -n "$OLD_REQUIREMENT" ] && [ "$OLD_REQUIREMENT" != "$NEW_REQUIREMENT" ]; then
    # System Settings would keep showing the stale grant as on while it no longer applies.
    # tccutil finds the app through Launch Services, which has not seen the new bundle yet.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null
    echo "signature changed: Screen Recording permission reset, open LidGlass and allow it again"
fi

# `open` only brings a running copy forward, so a running old build would stay the one in use.
if pgrep -f "$APP/Contents/MacOS/LidGlass" >/dev/null; then
    echo "LidGlass is still running the previous build: quit it from the menu bar, then open it again"
fi
