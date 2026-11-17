#!/usr/bin/env bash
# GUI-session smoke test: wait for an automatic recovery snapshot, kill only
# the isolated test app, and verify the snapshot can render. Requires a device.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/dalnok-recovery.XXXXXX")
pid=""
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
DALNOK_RECOVERY_DIR="$work/recovery" .build/debug/Dalnok /System/Library/Sounds/Submarine.aiff --no-welcome >"$work/app.log" 2>&1 &
pid=$!
snapshot=""
for _ in {1..60}; do
  if [[ -d "$work/recovery" ]]; then snapshot=$(find "$work/recovery" -name '*.dalnok' -type f -print -quit); fi
  [[ -n "$snapshot" ]] && break
  if ! kill -0 "$pid" 2>/dev/null; then cat "$work/app.log" >&2; exit 1; fi
  sleep 1
done
if [[ -z "$snapshot" ]]; then echo 'automatic snapshot timed out' >&2; exit 1; fi
kill -KILL "$pid"
wait "$pid" 2>/dev/null || true
pid=""
.build/debug/dalnok-cli render-project "$snapshot" "$work/recovered.wav"
echo 'automatic snapshot and process-crash recovery: PASS'
