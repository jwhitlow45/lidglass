#!/bin/bash
# Builds LidGlass.app. Screen Recording permission is granted per signed bundle, so the
# ad-hoc signature keeps a stable identifier across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LidGlass.app"
BUNDLE_ID="local.lidglass"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/LidGlass"

# Ad-hoc signatures tie Screen Recording permission to the exact binary, so a grant made
# for an earlier build no longer matches after a code change. Keep the old hash to tell.
OLD_CDHASH="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/{print $2}' || true)"

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
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null
echo "built $APP"

NEW_CDHASH="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/{print $2}')"
if [ -n "$OLD_CDHASH" ] && [ "$OLD_CDHASH" != "$NEW_CDHASH" ]; then
    # System Settings would keep showing the stale grant as on while it no longer applies.
    # tccutil finds the app through Launch Services, which has not seen the new bundle yet.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null
    echo "binary changed: Screen Recording permission reset, reopen LidGlass and allow it again"
fi
