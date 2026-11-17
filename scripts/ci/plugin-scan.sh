#!/usr/bin/env bash
# ADR-0009 gate 2: builds fake plugins (good, crashing, hanging, noisy VST3; a CLAP; a bundle with no code),
# validates them through dalnok-scan child processes, and checks that every failure is contained and
# classified, good plugins are read correctly, and a second run is served from the cache.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build --product dalnok-scan >/dev/null
swift build --product dalnok-cli >/dev/null
work=$(mktemp -d "${TMPDIR:-/tmp}/dalnok-plugin-scan.XXXXXX")
trap 'rm -rf "$work"' EXIT
CXX=${CXX:-$(xcrun --find clang++)}
CC=${CC:-$(xcrun --find clang)}
inc=(-isysroot "$(xcrun --show-sdk-path)" -Iengine/third_party/vst3 -Iengine/third_party/clap/include)
bundle() { # name ext plist-type source compiler flags...
  local name=$1 ext=$2 dir="$work/plugins/$1.$2"; shift 2
  mkdir -p "$dir/Contents/MacOS"
  cat > "$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string><key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>BNDL</string><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>
PLIST
  [[ $# -gt 0 ]] && "$@" -o "$dir/Contents/MacOS/$name"
  return 0
}
vst=("$CXX" -std=c++20 -bundle "${inc[@]}" tools/dalnok-scan/fixtures/fake_vst3.cpp tools/dalnok-scan/vst3_iids.cpp -framework CoreFoundation)
bundle Good vst3 "${vst[@]}"
bundle Crash vst3 "${vst[@]}" -DFIXTURE_CRASH
bundle Hang vst3 "${vst[@]}" -DFIXTURE_HANG
bundle Noisy vst3 "${vst[@]}" -DFIXTURE_NOISY
bundle NoCode vst3
bundle Synth clap "$CC" -bundle "${inc[@]}" tools/dalnok-scan/fixtures/fake_clap.c

run() { .build/debug/dalnok-cli plugins --validate --folder "$work/plugins" --only-folder --timeout 2 --cache "$work/cache.json" "$@"; }
start=$(date +%s)
out=$(run)
took=$(( $(date +%s) - start ))
echo "$out"
expect() { grep -Eq "$1" <<<"$out" || { echo "FAIL: expected /$1/" >&2; exit 1; }; }
expect '^ok +VST3 +effect +Dalnok Test Gain$'
expect '^ok +VST3 +effect +Noisy|^ok +VST3 +effect +Dalnok Test Gain' # noisy bundle declares the same class
expect '^crashed +VST3 .*Crash.*crashed \(Abort trap'
expect '^timeout +VST3 .*Hang.*did not finish'
expect '^failed +VST3 .*NoCode.*could not be loaded'
expect '^ok +CLAP +instrument +Dalnok Test Synth$'
expect '6 plugins'
[[ $(grep -c '^ok ' <<<"$out") -eq 3 ]] || { echo "FAIL: expected 3 ok plugins" >&2; exit 1; }
[[ $took -le 8 ]] || { echo "FAIL: scan took ${took}s; the hang should cost one 2 s timeout" >&2; exit 1; }
out=$(run)
[[ $(grep -c '(cached)' <<<"$out") -eq 6 ]] || { echo "$out"; echo "FAIL: second run should be fully cached" >&2; exit 1; }
touch "$work/plugins/Good.vst3/Contents/Info.plist" && sleep 1 && touch "$work/plugins/Good.vst3/Contents/Info.plist"
out=$(run)
[[ $(grep -c '(cached)' <<<"$out") -eq 5 ]] || { echo "$out"; echo "FAIL: a changed bundle must be rescanned" >&2; exit 1; }
echo 'plugin scan containment and cache: PASS'
