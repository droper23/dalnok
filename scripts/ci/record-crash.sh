#!/usr/bin/env bash
# Process-kill test for recording (ADR-0008 gate 3): SIGKILL a real-time simulated take
# at several points, recover each take from its journal, and verify every recovered
# sample against the generated signal. Also checks that recovery is repeatable and
# leaves the spool untouched. No audio device needed. Power loss is NOT covered.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
cli=.build/debug/dalnok-cli
work=$(mktemp -d "${TMPDIR:-/tmp}/dalnok-record-crash.XXXXXX")
pid=""
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

for delay in 0.05 0.7 2.5; do
  dir="$work/kill-$delay"
  "$cli" simulate-record "$dir" 30 >"$work/log-$delay" 2>&1 &
  pid=$!
  sleep "$delay"
  kill -KILL "$pid"; wait "$pid" 2>/dev/null || true; pid=""
  journal=$(find "$dir" -name '*.dlntake' -print -quit 2>/dev/null || true)
  if [[ -z "$journal" ]]; then echo "kill after ${delay}s: no journal (take had not started)"; continue; fi
  spool="${journal%.dlntake}.dlncap"
  # Killed between the journal and the first capture: no spool yet (it recovers as an empty take).
  sum() { if [[ -f "$spool" ]]; then shasum "$spool" | cut -d' ' -f1; else echo missing; fi; }
  before=$(sum)
  "$cli" recover-takes "$dir"
  "$cli" recover-takes "$dir" >/dev/null  # repeated recovery must not change anything
  after=$(sum)
  [[ "$before" == "$after" ]] || { echo "spool changed by recovery" >&2; exit 1; }
  wav="${journal%.dlntake} (recovered).wav"
  python3 -I - "$wav" "$delay" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read()
assert data[:4] == b'RIFF' and data[8:12] == b'WAVE', 'not a WAV'
assert struct.unpack('<H', data[20:22])[0] == 3, 'not float'
n = struct.unpack('<I', data[40:44])[0] // 4
samples = struct.unpack('<%df' % n, data[44:44 + 4 * n])
# The take starts at frame 0 (no pending seek), so file sample i is generated sample i.
for i, v in enumerate(samples):
    want = ((i * 37) % 2000 - 1000) / 1024.0
    if v != want:
        sys.exit('sample %d: %r != %r' % (i, v, want))
print('kill after %ss: recovered %d frames (%.2f s), all samples exact' % (sys.argv[2], n, n / 48000))
PY
done
echo 'recording process-kill recovery: PASS'
