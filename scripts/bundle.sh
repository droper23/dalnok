#!/usr/bin/env bash
# Builds a release Dalnok.app bundle in dist/.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Dalnok
swift build -c release --product dalnok-scan
swift build -c release --product dalnok-plughost
APP=dist/Dalnok.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dalnok "$APP/Contents/MacOS/Dalnok"
cp .build/release/dalnok-scan "$APP/Contents/MacOS/dalnok-scan" # plugin scanner (ADR-0009)
cp .build/release/dalnok-plughost "$APP/Contents/MacOS/dalnok-plughost" # out-of-process plug-in host (ADR-0014)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Dalnok</string>
  <key>CFBundleIdentifier</key><string>io.github.droper23.Dalnok</string>
  <key>CFBundleExecutable</key><string>Dalnok</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Dalnok records audio from your input devices.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
