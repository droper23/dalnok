#!/usr/bin/env bash
# ADR-0009 gates 3–4: builds a test VST3 (gain effect + note-driven synth) and runs the hosting tests
# against it: exact gain, bit-exact passthrough, sample-accurate notes, live input, undo, state
# save/reopen, and a missing plugin keeping its state.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/dalnok-plugin-host.XXXXXX")
trap 'rm -rf "$work"' EXIT
CXX=${CXX:-$(xcrun --find clang++)}
dir="$work/DalnokTest.vst3"
mkdir -p "$dir/Contents/MacOS"
cat > "$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DalnokTest</string><key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>
PLIST
"$CXX" -std=c++20 -bundle -isysroot "$(xcrun --show-sdk-path)" -Iengine/third_party/vst3 \
  tools/dalnok-scan/fixtures/host_vst3.cpp tools/dalnok-scan/vst3_iids.cpp -framework CoreFoundation \
  -o "$dir/Contents/MacOS/DalnokTest"
DALNOK_TEST_VST3="$dir" swift test --disable-sandbox --filter 'PluginHosting|DelayCompensation' ${DALNOK_HOST_SANITIZE:+--sanitize=$DALNOK_HOST_SANITIZE} 2>&1 \
  | grep -E "✔|✘|error:|Test run" | tail -8
DALNOK_TEST_VST3="$dir" swift test --disable-sandbox --filter 'PluginHosting|DelayCompensation' ${DALNOK_HOST_SANITIZE:+--sanitize=$DALNOK_HOST_SANITIZE} >/dev/null 2>&1 \
  && echo 'plugin hosting: PASS' || { echo 'plugin hosting: FAIL' >&2; exit 1; }
