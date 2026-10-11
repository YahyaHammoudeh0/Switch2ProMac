#!/bin/bash
#
# install-agent.sh - Install a per-user LaunchAgent that runs pro2steam-watch.sh
# at login, so the controller is initialized automatically whenever it's plugged in.
#
# Usage: ./install-agent.sh            install (or reinstall) and start the agent
#        ./install-agent.sh uninstall  stop and remove the agent
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.switch2promac.watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/Switch2ProMac.log"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [ "$1" = "uninstall" ]; then
    rm -f "$PLIST"
    echo "Removed $LABEL."
    exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/pro2steam-watch.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed $LABEL. Log: $LOG"
echo "Plug in the controller; it will be initialized within a few seconds."
