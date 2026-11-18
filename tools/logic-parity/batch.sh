#!/bin/bash
# batch.sh <run-name> "<ch> <idx=val> ..." ["<ch> ..."]   — patch from base, render all tracks in Logic
# Clean-room measurement loop (see 04 - Research/Logic Effect Parity.md). PARITY_DIR must contain:
#   meas.logicx (a Logic project laid out in Logic), ProjectData.base (its ProjectData with defaults),
#   compiled tools from ax/*.swift and scripts/dev/drive.swift (swiftc -O x.swift -o $PARITY_DIR/x).
# Export dialog click positions assume a 1920x1080 main display; check with screenshots before relying on them.
# Logic's Export All Tracks applies a common "overload protection" scale; bqfit.py removes it using a
# plug-in-free reference track (Audio 10) and renders/bypass (the same export with plug-ins bypassed).
S=${PARITY_DIR:?set PARITY_DIR to the measurement folder}
PD="$S/meas.logicx/Alternatives/000/ProjectData"; run=$1; shift
front() { [ "$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')" = "Logic Pro Creator Studio" ]; }
# 1. close the project if open
if $S/axapp | grep -q 'AXWindow meas.logicx'; then
  osascript -e 'tell application "Logic Pro Creator Studio" to activate'; sleep 1; front || { echo "not front"; exit 1; }
  $S/drive key 13 cmd,opt; sleep 3
  $S/axapp | grep -q 'save the changes' && { $S/axpress alert "Don’t Save"; sleep 3; }
fi
sleep 1; $S/axapp | grep -q 'AXWindow meas.logicx' && { echo "project still open"; exit 1; }
# 2. patch
cp "$S/ProjectData.base" "$PD"
for spec in "$@"; do python3 $S/patch.py "$PD" $spec >/dev/null || exit 1; done
# 3. reopen
open -a "Logic Pro Creator Studio" "$S/meas.logicx"
for i in $(seq 1 30); do sleep 1; $S/axapp | grep -q 'AXWindow meas.logicx' && break; done; sleep 3
$S/axapp | grep -q 'alert' && { $S/axapp | grep AXStaticText | head -3; echo "unexpected alert"; exit 1; }
osascript -e 'tell application "Logic Pro Creator Studio" to activate'; sleep 1; front || { echo "not front"; exit 1; }
# 4. export
mkdir -p "$S/renders/$run"; rm -f "$S/renders/$run"/*.wav
$S/drive key 14 cmd,shift; sleep 2.5
$S/drive key 5 cmd,shift; sleep 1.5; $S/drive type "$S/renders/$run/"; sleep 1; $S/drive key 36; sleep 2
if $S/axdump "Bypass Effect" 60 | grep -q '| 1$'; then $S/drive click 1016 440; sleep 0.8; fi
$S/axdump "Bypass Effect" 60 | grep -q '| 0$' || { echo "bypass state unknown"; exit 1; }
$S/drive click 1476 805
for i in $(seq 1 60); do sleep 3; [ $(/bin/ls "$S/renders/$run" | wc -l) -ge 10 ] && break; done
# wait until sizes stop changing
prev=""; for i in $(seq 1 20); do sleep 3; cur=$(/bin/ls -l "$S/renders/$run" | md5); [ "$cur" = "$prev" ] && break; prev=$cur; done
cd "$S/renders/$run" && for f in *.wav; do case "$f" in *_1.wav) ;; *) mv "$f" "${f%.wav}_1.wav";; esac; done
echo "$run: $(/bin/ls | wc -l) files"
