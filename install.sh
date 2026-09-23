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
    | awk '$1 ~ /^0x/ && $4 == 32 && $5 == 138 { found = 1 } END { exit !found }'; then
    printf '%sThis Mac has no lid angle sensor, so the glass cannot follow the lid. It can\n' "$WARN"
    printf 'still be folded by hand with the slider in Settings. Installing anyway.%s\n\n' "$OFF"
fi

# Where a copy already lives wins, so an update replaces the copy that opens at login
# rather than leaving a second one behind in the other folder. Otherwise /Applications,
# which administrators can write, and a standard account's own Applications folder, which
# needs no password and works the same way.
#
# A folder holding only the backup an interrupted install left behind still counts as the
# folder a copy lives in. Passing over it would strand that copy where nobody would look.
holds_a_copy() {
    [ -d "$1/LidGlass.app" ] || [ -d "$1/.LidGlass.app.previous" ]
}
if holds_a_copy "/Applications" && [ -w "/Applications" ]; then
    TARGET="/Applications"
elif holds_a_copy "$HOME/Applications"; then
    TARGET="$HOME/Applications"
elif [ -w /Applications ]; then
    TARGET="/Applications"
else
    TARGET="$HOME/Applications"
    mkdir -p "$TARGET"
fi
APP="$TARGET/LidGlass.app"

# Claimed and repaired before anything is downloaded, so a run that never gets its archive
# still leaves this folder in a state someone can use.
STAGED="$TARGET/.LidGlass.app.incoming"
PREVIOUS="$TARGET/.LidGlass.app.previous"
# mkdir either creates the lock or fails, with nothing in between, so a second installer
# running at the same time stops here rather than clearing the first one's staged copy or
# its backup out from under it.
LOCK="$TARGET/.LidGlass.install.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -d "$LOCK" ]; then
        stop "Another install is already running in $TARGET. If that is wrong, remove $LOCK and run this again."
    fi
    stop "Could not write to $TARGET, so nothing was changed."
fi
WORK=""
trap 'rmdir "$LOCK" 2>/dev/null || true; rm -rf "${WORK:-}" "${STAGED:-}"' EXIT

# An earlier run stopped between the two renames below, so the only copy there is the one
# it set aside. Putting it back comes before anything is removed, or this run would delete
# the copy that run left behind and a failure here would leave none at all.
if [ -d "$PREVIOUS" ] && [ ! -d "$APP" ]; then
    mv "$PREVIOUS" "$APP" || stop "A copy of LidGlass is sitting at $PREVIOUS from an interrupted install, and could not be put back."
fi
WORK="$(mktemp -d)"

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

# The copy already installed is not touched until the new one is sitting on the same volume,
# ready to take its place, and it goes back if the swap itself fails. Deleting first would
# mean an install that fails halfway leaves no working copy at all.
printf '  Installing into %s\n' "$TARGET"
rm -rf "$STAGED" "$PREVIOUS" || stop "Could not clear an earlier install's leftovers from $TARGET, so nothing was changed."
ditto "$NEW_APP" "$STAGED" || { rm -rf "$STAGED"; stop "Could not write to $TARGET, so nothing was changed."; }

# A running copy has to go before its bundle is replaced underneath it, and a copy that
# will not go has to stop the install rather than have its bundle swapped while it runs.
# Settings are written as they change, so nothing is lost by quitting it. Only this user's
# copy is matched, so a copy running in another account is left alone.
ME="$(id -u)"
if pgrep -x -U "$ME" LidGlass >/dev/null 2>&1; then
    printf '  Quitting the copy that is running\n'
    pkill -x -U "$ME" LidGlass || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x -U "$ME" LidGlass >/dev/null 2>&1 || break
        sleep 0.3
    done
    if pgrep -x -U "$ME" LidGlass >/dev/null 2>&1; then
        stop "LidGlass is still running and would be replaced while it runs. Quit it from the menu bar, then run this again."
    fi
fi

# A copy signed in to another account is not ours to quit, and /Applications is shared, so
# replacing the bundle while someone else runs from it would break it under them.
for RUNNING in $(pgrep -x LidGlass 2>/dev/null || true); do
    case "$(ps -p "$RUNNING" -o comm= 2>/dev/null || true)" in
        "$APP"/*)
            stop "Another account is running LidGlass from $APP. Ask whoever is signed in there to quit it, then run this again."
            ;;
    esac
done

if [ -d "$APP" ]; then
    mv "$APP" "$PREVIOUS" || { rm -rf "$STAGED"; stop "Could not replace the copy in $TARGET, so it was left as it was."; }
    if ! mv "$STAGED" "$APP"; then
        rm -rf "$STAGED"
        if mv "$PREVIOUS" "$APP"; then
            stop "Could not install into $TARGET. The copy that was already there has been put back."
        fi
        stop "Could not install into $TARGET, and the copy that was already there could not be put back either. It is at $PREVIOUS."
    fi
    rm -rf "$PREVIOUS"
else
    mv "$STAGED" "$APP" || { rm -rf "$STAGED"; stop "Could not install into $TARGET."; }
fi

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
printf '%sApple has not notarized it, so macOS cannot check who made it. What was just\n' "$DIM"
printf 'installed came from the releases of %s and nowhere else.%s\n' "$REPO" "$OFF"
printf '%sOn first launch macOS asks for Screen Recording permission, since the glass is your\n' "$DIM"
printf 'own screen redrawn. Allow LidGlass in System Settings > Privacy & Security > Screen &\n'
printf 'System Audio Recording, then quit it from the menu bar and open it again.%s\n\n' "$OFF"
