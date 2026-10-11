#!/bin/bash
#
# pro2steam-watch.sh - Run pro2steam.sh automatically whenever an NS2 Pro
# Controller (or NSO GameCube controller) is plugged in over USB.
#
# Meant to be run by launchd (install with ./install-agent.sh), but can also
# be run by hand in a terminal.
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POLL_SECONDS=2

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# On macOS 27 the GameController framework claims the controller but never
# creates a GCController for it, so Steam's SDL skips it. Disabling SDL's MFi
# backend makes Steam read it through IOKit instead. Applies to apps launched
# after this point (Steam must be started after login, not before this runs).
launchctl setenv SDL_JOYSTICK_MFI 0

# Optional machine-specific extras (not tracked in git), e.g. launchctl setenv calls.
[ -f "$SCRIPT_DIR/local-env.sh" ] && . "$SCRIPT_DIR/local-env.sh"

# Nintendo VID 0x057E = 1406; NS2 Pro PID 0x2069 = 8297, NSO GameCube PID 0x2073 = 8307
controller_present() {
    ioreg -p IOUSB -l -w0 | grep -q -E '"idProduct" = (8297|8307)$' &&
        ioreg -p IOUSB -l -w0 | grep -q '"idVendor" = 1406$'
}

log "Watching for NS2 Pro Controller..."
was_present=false

while true; do
    if controller_present; then
        if [ "$was_present" = false ]; then
            log "Controller connected - initializing"
            sleep 1  # let USB enumeration settle
            bash "$SCRIPT_DIR/pro2steam.sh" && log "Initialization finished" || log "Initialization failed"
            was_present=true
        fi
    elif [ "$was_present" = true ]; then
        log "Controller disconnected"
        was_present=false
    fi
    sleep "$POLL_SECONDS"
done
