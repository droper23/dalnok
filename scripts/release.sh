#!/usr/bin/env bash
# Packages a release: builds dist/Dalnok.app (scripts/bundle.sh), zips it as dist/Dalnok-<version>.zip with ditto
# (keeps the bundle's attributes and ad-hoc signature) and prints its SHA-256. Publishing is a separate, manual step
# (gh release create/upload).
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/Dalnok.app/Contents/Info.plist)
ZIP="dist/Dalnok-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent dist/Dalnok.app "$ZIP"
codesign --verify --deep dist/Dalnok.app
echo "packaged $ZIP"
shasum -a 256 "$ZIP"
