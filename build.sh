#!/bin/zsh
# Build NotchDial.app. Pass --install to copy it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/NotchDial.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" Sources/main.swift -o "$APP/Contents/MacOS/NotchDial"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.notchdial</string>
  <key>CFBundleName</key><string>NotchDial</string>
  <key>CFBundleExecutable</key><string>NotchDial</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign -s - --force "$APP" >/dev/null 2>&1
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/NotchDial.app
  cp -R "$APP" ~/Applications/
  echo "Installed ~/Applications/NotchDial.app"
fi
