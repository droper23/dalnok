#!/usr/bin/env bash
# Full local verification: build (RT effect violations are errors), engine tests,
# and — when an output device and GUI session exist — live playback smoke test
# plus the app's end-to-end UI self-test.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
if [[ "${DALNOK_SANITIZE:-0}" == "1" ]]; then
  swift test --sanitize=address
  swift test --sanitize=thread
fi
if [[ "${DALNOK_SKIP_LIVE:-0}" != "1" ]]; then
  swift build --product dalnok-cli
  .build/debug/dalnok-cli play /System/Library/Sounds/Submarine.aiff --seconds 2 --churn
  work=$(mktemp -d)
  .build/debug/Dalnok /System/Library/Sounds/Submarine.aiff /System/Library/Sounds/Glass.aiff --selftest "$work" | tail -1
fi
