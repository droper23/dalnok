#!/usr/bin/env bash
# Creates deterministic test projects (generated audio and MIDI; nothing from real projects).
#
#   scripts/make-test-project.sh <folder> [preset...] [--screenshots] [--open]
#
# Presets: demo (default), band, midi, states (every visual state, including an offline clip),
# large (64 tracks × 30 s; set TRACKS/SECONDS to change). Each preset goes to <folder>/<preset>/.
# --screenshots renders each project in Graphite and Warm Analog to <folder>/<preset>-<theme>.png.
# --open opens the first project in the debug app.
# Environment: RATE (48000), BPM (120), TRACKS (64), SECONDS (30).
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -ge 1 ]] || { sed -n '2,12p' "$0"; exit 2; }
out=$1; shift
presets=(); shots=0; open=0
for a in "$@"; do
  case "$a" in
    --screenshots) shots=1 ;;
    --open) open=1 ;;
    -*) echo "unknown option $a" >&2; exit 2 ;;
    *) presets+=("$a") ;;
  esac
done
[[ ${#presets[@]} -gt 0 ]] || presets=(demo)
swift build --product dalnok-cli >/dev/null
[[ $shots == 1 || $open == 1 ]] && swift build --product Dalnok >/dev/null
mkdir -p "$out"
out=$(cd "$out" && pwd)
first=""
for p in "${presets[@]}"; do
  dir="$out/$p"
  rm -rf "$dir"
  project=$(.build/debug/dalnok-cli make-test-project "$dir" --preset "$p" --rate "${RATE:-48000}" --bpm "${BPM:-120}" \
            --tracks "${TRACKS:-64}" --seconds "${SECONDS:-30}")
  echo "$project"
  first=${first:-$project}
  if [[ $shots == 1 ]]; then
    for theme in graphite warmAnalog; do
      DALNOK_THEME=$theme .build/debug/Dalnok "$project" --no-welcome --snapshot "$out/$p-$theme.png" >/dev/null
      echo "  $out/$p-$theme.png"
    done
  fi
done
if [[ $open == 1 ]]; then .build/debug/Dalnok "$first" --no-welcome & fi
