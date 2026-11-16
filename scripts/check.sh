#!/usr/bin/env bash
# Full local verification: build (warnings are errors for RT effects), unit tests,
# and — when an output device exists — a live playback smoke test.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
if [[ "${ATRIUM_SKIP_LIVE:-0}" != "1" ]]; then
  swift build --product atrium-cli
  .build/debug/atrium-cli play /System/Library/Sounds/Submarine.aiff --seconds 2 --churn
fi
