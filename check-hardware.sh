#!/bin/bash
# Says whether this Mac can run LidGlass. It only reads and prints: nothing is installed,
# downloaded, or changed. Meant to be run straight from the web, so it uses only what comes
# with macOS and never needs the command line tools.
set -u

READY=1

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    GOOD="$(tput setaf 2)"; BAD="$(tput setaf 1)"; DIM="$(tput setaf 8)"; OFF="$(tput sgr0)"
else
    GOOD=""; BAD=""; DIM=""; OFF=""
fi

# Marks the line and, on a failure, decides the verdict at the bottom. It has to run in
# this shell rather than inside a substitution, or the verdict would never see the failure.
report() {
    local label="$1" value="$2" passed="$3" note="${4:-}" mark
    if [ "$passed" -eq 1 ]; then
        mark="${GOOD}ok${OFF}"
    else
        mark="${BAD}no${OFF}"
        READY=0
    fi
    printf '  %-18s %-16s %s%s\n' "$label" "$value" "$mark" "$note"
}

printf '\nLidGlass hardware check\n\n'

# Everything below reads Apple-only interfaces, so anything that is not a Mac stops here
# rather than reporting nonsense about a sensor it could never have.
if [ "$(uname -s)" != "Darwin" ]; then
    printf '  %sThis is not a Mac, so LidGlass cannot run here.%s\n\n' "$BAD" "$OFF"
    exit 1
fi

printf '  %-18s %s\n' "Mac" "$(sysctl -n hw.model 2>/dev/null || echo unknown)"

# LidGlass is built for macOS 14 and later, so an older Mac cannot open it at all.
VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
MAJOR="${VERSION%%.*}"
OS_TOO_OLD=0
if [ "${MAJOR:-0}" -ge 14 ] 2>/dev/null; then
    report "macOS" "$VERSION" 1
else
    OS_TOO_OLD=1
    report "macOS" "$VERSION" 0 " (needs 14 or later)"
fi

# The one piece of hardware that cannot be worked around. LidGlass follows the continuous
# lid angle sensor, which reports the hinge angle in degrees as the lid moves. This looks
# for the same device LidGlass itself opens: usage 138 on the sensor usage page, 32.
NO_SENSOR=0
if hidutil list --matching '{"PrimaryUsagePage":32,"PrimaryUsage":138}' 2>/dev/null \
    | awk '$4 == 32 && $5 == 138 { found = 1 } END { exit !found }'; then
    report "Lid angle sensor" "found" 1
else
    NO_SENSOR=1
    report "Lid angle sensor" "not found" 0
fi

printf '\n'
if [ "$READY" -eq 1 ]; then
    printf '%sThis Mac can run LidGlass.%s\n\n' "$GOOD" "$OFF"
    printf 'Install it by running this:\n\n'
    printf '  curl -fsSL https://raw.githubusercontent.com/jwhitlow45/lidglass/main/install.sh | bash\n\n'
    printf '%sOr download it by hand from https://github.com/jwhitlow45/lidglass/releases/latest%s\n\n' "$DIM" "$OFF"
    exit 0
fi

printf '%sThis Mac cannot run LidGlass.%s\n' "$BAD" "$OFF"
if [ "$NO_SENSOR" -eq 1 ]; then
    printf '%sThe glass follows the lid angle sensor, so without one there is nothing to\n' "$DIM"
    printf 'follow. Desktop Macs have no lid at all, and not every MacBook carries the\n'
    printf 'sensor.%s\n' "$OFF"
fi
if [ "$OS_TOO_OLD" -eq 1 ]; then
    printf '%sUpdate to macOS 14 or later, then run this check again.%s\n' "$DIM" "$OFF"
fi
printf '\n'
exit 1
