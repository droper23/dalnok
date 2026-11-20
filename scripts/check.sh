#!/usr/bin/env bash
# Full local verification: build (RT effect violations are errors), engine tests,
# and — when an output device and GUI session exist — live playback smoke test
# plus the app's end-to-end UI self-test.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
scripts/ci/tempo-map.sh
scripts/ci/capture-ring.sh
scripts/ci/midi-parser.sh
scripts/ci/duplex-probe.sh
scripts/ci/record-crash.sh
scripts/ci/plugin-scan.sh
scripts/ci/plugin-host.sh
if [[ "${DALNOK_SANITIZE:-0}" == "1" ]]; then
  swift test --sanitize=address
  swift test --sanitize=thread
else
  # Untrusted-file parsers always run under AddressSanitizer (audit A-10); the full sanitizer pass is opt-in.
  swift test --sanitize=address --filter 'ProjectParsingRobustness|ReaperImport|AbletonImport|FcpxmlImport|StemsImport|LogicImport|Dawproject|LogicPluginImport|LogicMixerImport|Persistence'
  DALNOK_CAPTURE_TSAN=1 scripts/ci/capture-ring.sh
  DALNOK_MIDI_TSAN=1 scripts/ci/midi-parser.sh
fi
if [[ "${DALNOK_SKIP_LIVE:-0}" != "1" ]]; then
  swift build --product dalnok-cli
  .build/debug/dalnok-cli play /System/Library/Sounds/Submarine.aiff --seconds 2 --churn
  work=$(mktemp -d)
  .build/debug/Dalnok /System/Library/Sounds/Submarine.aiff /System/Library/Sounds/Glass.aiff --selftest "$work" > "$work/selftest.log" && status=0 || status=$?
  grep -E '^FAIL' "$work/selftest.log" || true
  tail -1 "$work/selftest.log"
  [[ $status -eq 0 ]] || exit $status
fi
