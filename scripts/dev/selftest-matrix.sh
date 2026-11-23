#!/bin/bash
# The app self-test in every look at 48 and 44.1 kHz, several at once.
#   scripts/dev/selftest-matrix.sh [-j jobs] [-l "graphite:dark prism:light ..."] [-r "48000 44100"] [-o out-dir]
# Each run is its own copy of the app named Dalnok-<n>: a bare executable's preferences domain is its process name, so
# every run has its own preferences (seeded from the developer's "Dalnok" domain, deleted afterwards). Runs can go in
# parallel and never touch the "Dalnok" domain (no backup and restore needed). Recordings and recovery go to the run's
# folder. The binaries are copied once, so building while it runs is safe. Prints one line per run and the FAIL lines; exits non-zero if any run fails.
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
cd "$(dirname "$0")/../.."
JOBS=12
LOOKS="graphite:dark warmAnalog:dark prism:dark prism:light atelier:dark atelier:light"
RATES="48000 44100"
OUT="${TMPDIR:-/tmp}/dalnok-selftest-matrix"
while getopts "j:l:r:o:" o; do case $o in j) JOBS=$OPTARG;; l) LOOKS=$OPTARG;; r) RATES=$OPTARG;; o) OUT=$OPTARG;; *) exit 2;; esac; done

rm -rf "$OUT"; mkdir -p "$OUT/bin"
for f in Dalnok Dalnok_Dalnok.bundle dalnok-plughost dalnok-scan dalnok-cli PackageFrameworks; do
  [ -e ".build/debug/$f" ] && cp -R ".build/debug/$f" "$OUT/bin/"
done
PREFS="$OUT/prefs.plist"; defaults export Dalnok "$PREFS" 2>/dev/null || true

run() { # look:variant rate
  local look=${1%%:*} variant=${1##*:} rate=$2 dir="$OUT/${1%%:*}-${1##*:}-$2"
  local name="Dalnok-$look-$variant-$rate"
  mkdir -p "$dir"
  cp -R "$OUT/bin" "$dir/bin" && mv "$dir/bin/Dalnok" "$dir/bin/$name"
  defaults delete "$name" >/dev/null 2>&1; [ -s "$PREFS" ] && defaults import "$name" "$PREFS"
  local t0=$SECONDS
  env DALNOK_BACKGROUND=1 DALNOK_RECOVERY_DIR="$dir/rec" DALNOK_RECORDINGS_DIR="$dir/recordings" DALNOK_THEME="$look" DALNOK_VARIANT="$variant" \
      DALNOK_SAMPLE_RATE="$rate" caffeinate -du "$dir/bin/$name" /System/Library/Sounds/Submarine.aiff \
      /System/Library/Sounds/Glass.aiff --selftest "$dir" > "$dir/selftest.log" 2>&1
  defaults delete "$name" >/dev/null 2>&1
  printf "%-22s %6s  %s  (%ss)\n" "$look-$variant" "$rate" "$(tail -1 "$dir/selftest.log" | cut -c1-40) pass $(grep -c '^PASS' "$dir/selftest.log")" $((SECONDS - t0))
  grep '^FAIL' "$dir/selftest.log" | sed "s/^/    $look-$variant $rate: /"
}
export -f run; export OUT PREFS

START=$SECONDS
for l in $LOOKS; do for r in $RATES; do echo "$l $r"; done; done | xargs -P "$JOBS" -L 1 bash -c 'run "$0" "$1"' | tee "$OUT/summary.txt"
echo "total $((SECONDS - START))s, $JOBS at a time; logs in $OUT"
! grep -q "FAIL" "$OUT/summary.txt"
