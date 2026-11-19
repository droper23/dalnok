#!/usr/bin/env bash
# ADR-0014 / audit A-01: builds the test VST3 and CLAP plug-ins, runs the existing hosting, latency-compensation and
# CLAP suites with every plug-in isolated in dalnok-plughost, then the isolation failure suite (crash and hang
# during processing and while loading, slow initialization loading in the background).
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/dalnok-plugin-isolation.XXXXXX")
trap 'rm -rf "$work"' EXIT
CXX=${CXX:-$(xcrun --find clang++)}
SDK=$(xcrun --show-sdk-path)
dir="$work/DalnokTest.vst3"
mkdir -p "$dir/Contents/MacOS"
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>DalnokTest</string><key>CFBundlePackageType</key><string>BNDL</string><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>' > "$dir/Contents/Info.plist"
"$CXX" -std=c++20 -bundle -isysroot "$SDK" -Iengine/third_party/vst3 tools/dalnok-scan/fixtures/host_vst3.cpp \
  tools/dalnok-scan/vst3_iids.cpp -framework CoreFoundation -o "$dir/Contents/MacOS/DalnokTest"
clap="$work/DalnokTestGain.clap"
mkdir -p "$clap/Contents/MacOS"
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>DalnokTestGain</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>' > "$clap/Contents/Info.plist"
"$CXX" -std=c++20 -bundle -isysroot "$SDK" -Iengine/third_party/clap/include tools/dalnok-scan/fixtures/host_clap.cpp \
  -o "$clap/Contents/MacOS/DalnokTestGain"
swift build --product dalnok-plughost >/dev/null
swift build --build-tests >/dev/null
host="$PWD/.build/debug/dalnok-plughost"
export DALNOK_TEST_VST3="$dir" DALNOK_TEST_CLAP="$clap" DALNOK_PLUGIN_LOAD_TIMEOUT_MS=3000
DALNOK_PLUGIN_HOST="$host" swift test --disable-sandbox --skip-build --filter 'PluginHosting|DelayCompensation|ClapHosting' \
  > "$work/hosting.log" 2>&1 || { grep -E "✘|error" "$work/hosting.log" | head -30; echo 'isolated hosting suites: FAIL' >&2; exit 1; }
grep -E "Test run with" "$work/hosting.log" | tail -1
echo 'isolated hosting suites: PASS'
DALNOK_PLUGIN_HOST="$host" swift test --disable-sandbox --skip-build --filter 'PluginIsolation' > "$work/isolation.log" 2>&1 \
  || { grep -E "✘|↳|error" "$work/isolation.log" | head -30; echo 'plugin isolation: FAIL' >&2; exit 1; }
grep -E "Test run with" "$work/isolation.log" | tail -1
grep -E "SLOWLOAD" "$work/isolation.log" || true
echo 'plugin isolation: PASS'
# DALNOK_ISOLATION_SELFTEST=1: also run the app self-test with these fixtures (slow isolated loading with Stop; needs
# a logged-in GUI session).
if [[ "${DALNOK_ISOLATION_SELFTEST:-0}" == "1" ]]; then
  swift build --product Dalnok >/dev/null
  DALNOK_TEST_VST3="$dir" DALNOK_RECOVERY_DIR="$work/recovery" .build/debug/Dalnok /System/Library/Sounds/Submarine.aiff \
    /System/Library/Sounds/Glass.aiff --selftest "$work/selftest" > "$work/selftest.log" 2>&1 && status=0 || status=$?
  grep -E '^FAIL|MEASURE slow' "$work/selftest.log" || true
  tail -1 "$work/selftest.log"
  [[ $status -eq 0 ]] || exit $status
fi
