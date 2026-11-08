#!/bin/zsh
# Baut SlideOver.app und installiert sie nach ~/Applications
set -e
cd "$(dirname "$0")"
APP=build/SlideOver.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/SlideOver" -framework Cocoa -framework Carbon
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.slideover</string>
  <key>CFBundleName</key><string>SlideOver</string>
  <key>CFBundleExecutable</key><string>SlideOver</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --deep -s - "$APP"
if [[ "$1" == "install" ]]; then
  mkdir -p ~/Applications
  pkill -x SlideOver 2>/dev/null || true
  rm -rf ~/Applications/SlideOver.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/SlideOver.app
  echo "Installiert: ~/Applications/SlideOver.app"
fi
