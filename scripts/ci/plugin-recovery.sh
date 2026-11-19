#!/usr/bin/env bash
# Verify the recovery boundary against plug-ins that crash or hang in initialize.
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/dalnok-plugin-recovery.XXXXXX")
trap 'rm -rf "$work"' EXIT
bundle="$work/Fixture.vst3"
mkdir -p "$bundle/Contents/MacOS"
printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>' > "$bundle/Contents/Info.plist"
"$(xcrun --find clang++)" -std=c++20 -bundle -isysroot "$(xcrun --show-sdk-path)" -Iengine/third_party/vst3 \
  tools/dalnok-scan/fixtures/host_vst3.cpp tools/dalnok-scan/vst3_iids.cpp -framework CoreFoundation -o "$bundle/Contents/MacOS/Fixture"
set +u
sanitize=()
if [[ ${DALNOK_SANITIZE:-0} == 1 ]]; then sanitize=(--sanitize=address); fi
swift test --disable-sandbox "${sanitize[@]}" --filter Persistence/recoveryPluginFixture >"$work/build.log" 2>&1 || { tail -30 "$work/build.log"; exit 1; }
project=$(.build/debug/dalnok-cli make-test-project "$work/project" --preset demo)
python3 - "$project" "$bundle" <<'PY'
import json, sys
path, bundle = sys.argv[1:]
with open(path) as f: doc = json.load(f)
doc['cycle'] = [True, 100, 2000]
doc['tracks'][0]['plugins'] = [{'id': 99, 'format': 'vst3', 'path': bundle, 'class': '44616C6E6F6B546573744761696E3031', 'name': 'Fault fixture', 'state': 'AAABPw=='}]
with open(path, 'w') as f: json.dump(doc, f)
PY
export DALNOK_TEST_RECOVERY_PROJECT="$project"
for mode in crash hang; do
  export DALNOK_TEST_RECOVERY_DIR="$work/$mode" DALNOK_TEST_INIT_FAILURE="$mode" DALNOK_TEST_INIT_MARKER="$work/$mode.init"
  python3 - "$mode" "${sanitize[@]}" <<'PY'
import os, signal, subprocess, sys
mode, *san = sys.argv[1:]
cmd = ['swift', 'test', '--disable-sandbox', '--skip-build', *san, '--filter', 'Persistence/recoveryPluginFixture']
p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
try:
    status = p.wait(timeout=15)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    if mode != 'hang': raise SystemExit('crash fixture timed out')
else:
    if mode != 'crash' or status == 0: raise SystemExit(f'{mode} unexpectedly exited {status}')
PY
  [[ -f "$DALNOK_TEST_INIT_MARKER" ]] || { echo "$mode did not reach initialize" >&2; exit 1; }
  rm "$DALNOK_TEST_INIT_MARKER"
  DALNOK_TEST_RECOVERY_VERIFY=1 swift test --disable-sandbox --skip-build "${sanitize[@]}" --filter Persistence/recoveryPluginFixture >"$work/verify.log" 2>&1 || { cat "$work/verify.log"; exit 1; }
  [[ ! -e "$DALNOK_TEST_INIT_MARKER" ]] || { echo "recovery reinitialized the plug-in" >&2; exit 1; }
  echo "initialization $mode recovery: PASS"
done
