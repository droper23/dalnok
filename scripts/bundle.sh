#!/usr/bin/env bash
# Builds a release Atrium.app bundle in dist/.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Atrium
APP=dist/Atrium.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Atrium "$APP/Contents/MacOS/Atrium"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Atrium</string>
  <key>CFBundleIdentifier</key><string>org.atrium-daw.Atrium</string>
  <key>CFBundleExecutable</key><string>Atrium</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Atrium records audio from your input devices.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
