#!/bin/zsh
# Start NotchDial at login (LaunchAgent). Usage: scripts/login-item.sh [enable|disable]
set -euo pipefail
PLIST=~/Library/LaunchAgents/dev.notchdial.plist
BIN=~/Applications/NotchDial.app/Contents/MacOS/NotchDial

case "${1:-enable}" in
  enable)
    [[ -x $BIN ]] || { echo "Run ./build.sh --install first"; exit 1; }
    cat > $PLIST <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.notchdial</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
    echo "NotchDial will start at login ($PLIST)";;
  disable)
    rm -f $PLIST && echo "Removed $PLIST";;
  *) echo "usage: $0 [enable|disable]"; exit 1;;
esac
