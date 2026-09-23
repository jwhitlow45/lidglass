#!/bin/bash
# Installs the latest LidGlass release. Downloads the release archive, replaces any copy
# already installed, and opens it. Uses only what comes with macOS, so it works on a Mac
# with no developer tools.
set -euo pipefail

REPO="jwhitlow45/lidglass"
ARCHIVE_URL="https://github.com/$REPO/releases/latest/download/LidGlass.zip"

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    GOOD="$(tput setaf 2)"; BAD="$(tput setaf 1)"; WARN="$(tput setaf 3)"; DIM="$(tput setaf 8)"; OFF="$(tput sgr0)"
else
    GOOD=""; BAD=""; WARN=""; DIM=""; OFF=""
fi

stop() {
    printf '\n%s%s%s\n\n' "$BAD" "$1" "$OFF"
    exit 1
}

printf '\nInstalling LidGlass\n\n'

[ "$(uname -s)" = "Darwin" ] || stop "This is not a Mac, so LidGlass cannot run here."

# LidGlass is built for macOS 14 and later, so an older Mac cannot open it at all.
VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
if ! [ "${VERSION%%.*}" -ge 14 ] 2>/dev/null; then
    stop "LidGlass needs macOS 14 or later. This Mac is on $VERSION."
fi

# Not fatal: without the sensor the glass can still be driven by the slider in Settings,
# which is worth saying plainly rather than either refusing or pretending all is well.
if ! hidutil list --matching '{"PrimaryUsagePage":32,"PrimaryUsage":138}' 2>/dev/null \
    | awk '$4 == 32 && $5 == 138 { found = 1 } END { exit !found }'; then
    printf '%sThis Mac has no lid angle sensor, so the glass cannot follow the lid. It can\n' "$WARN"
    printf 'still be folded by hand with the slider in Settings. Installing anyway.%s\n\n' "$OFF"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '  Downloading the latest release\n'
curl -fL --progress-bar -o "$WORK/LidGlass.zip" "$ARCHIVE_URL" \
    || stop "Could not download the release from $ARCHIVE_URL"

ditto -x -k "$WORK/LidGlass.zip" "$WORK/expanded" || stop "The downloaded archive would not expand."
NEW_APP="$WORK/expanded/LidGlass.app"
[ -d "$NEW_APP" ] || stop "The downloaded archive does not contain LidGlass.app."

# Catches an archive that arrived damaged. It says the bundle still matches its own
# signature, not who signed it: LidGlass signs itself with a certificate it makes locally,
# which no Mac but the one that made it has any reason to trust.
codesign --verify --strict "$NEW_APP" 2>/dev/null || stop "The downloaded copy is damaged, so nothing was installed."

# /Applications is writable by administrators. A standard account installs into its own
# Applications folder instead, which needs no password and works the same way.
if [ -w /Applications ]; then
    TARGET="/Applications"
else
    TARGET="$HOME/Applications"
    mkdir -p "$TARGET"
fi
APP="$TARGET/LidGlass.app"

# A running copy has to go before its bundle is replaced underneath it. Settings are
# written as they change, so nothing is lost by stopping it here.
if pgrep -x LidGlass >/dev/null 2>&1; then
    printf '  Quitting the copy that is running\n'
    pkill -x LidGlass || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x LidGlass >/dev/null 2>&1 || break
        sleep 0.3
    done
fi

printf '  Installing into %s\n' "$TARGET"
rm -rf "$APP"
ditto "$NEW_APP" "$APP" || stop "Could not install into $TARGET."

# Only asked when there is something to answer for. A copy fetched by this script is not
# quarantined, since that mark comes from browsers rather than from curl, but a copy that
# arrived another way can be. macOS cannot verify LidGlass, so it refuses to open a
# quarantined copy until the mark is gone.
if command -v xattr >/dev/null 2>&1 && xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
    printf '\n%sThis copy is marked as quarantined, so macOS will refuse to open it.\n' "$WARN"
    printf 'LidGlass is not notarized by Apple, so macOS cannot check who made it.%s\n' "$OFF"
    REPLY_TEXT=""
    if [ -r /dev/tty ]; then
        printf 'Remove the quarantine mark so it can open? [y/N] '
        read -r REPLY_TEXT < /dev/tty || REPLY_TEXT=""
    fi
    case "$REPLY_TEXT" in
        [yY]*)
            xattr -dr com.apple.quarantine "$APP"
            printf '%s  Quarantine mark removed%s\n' "$DIM" "$OFF"
            ;;
        *)
            printf '\n%sLeft in place. To open it anyway: try to open LidGlass once, then go to System\n' "$DIM"
            printf 'Settings > Privacy & Security, scroll to Security, and choose Open Anyway.%s\n' "$OFF"
            ;;
    esac
fi

INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
printf '\n%sInstalled LidGlass %s in %s%s\n\n' "$GOOD" "$INSTALLED" "$TARGET" "$OFF"
open "$APP" 2>/dev/null || true

printf 'LidGlass lives in the menu bar, with no window and no Dock icon.\n'
printf '%sOn first launch macOS asks for Screen Recording permission, since the glass is your\n' "$DIM"
printf 'own screen redrawn. Allow LidGlass in System Settings > Privacy & Security > Screen &\n'
printf 'System Audio Recording, then quit it from the menu bar and open it again.%s\n\n' "$OFF"
