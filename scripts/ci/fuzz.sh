#!/usr/bin/env bash
# Fuzzes every untrusted document parser (project reader and importers) with libFuzzer + AddressSanitizer
# (audit A-10). Needs Homebrew LLVM (Apple clang ships no libFuzzer runtime).
#   scripts/ci/fuzz.sh [seconds]   default 600; DALNOK_FUZZ_JOBS=N runs N workers in parallel
# Then runs the save/load/save property test over 1,000 random models (DALNOK_PROPERTY_ITERATIONS).
# Seeds are generated here from deterministic fixtures, never from the owner's projects. Crashes are written
# to .build/fuzz/artifacts; the corpus grows in .build/fuzz/corpus (both ignored by git).
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
seconds="${1:-600}"
if [ -z "${CXX:-}" ]; then
  for p in "$(brew --prefix llvm 2>/dev/null)" $(ls -d "$(brew --prefix)"/opt/llvm@* 2>/dev/null | sort -rV); do
    [ -x "$p/bin/clang++" ] && CXX="$p/bin/clang++" && break
  done
fi
CXX="${CXX:?no Homebrew LLVM found (brew install llvm)}"
SDK="$(xcrun --show-sdk-path)"
out=.build/fuzz
mkdir -p "$out/obj" "$out/corpus" "$out/artifacts"
common=(-isysroot "$SDK" -g -O1 -fsanitize=address -fno-omit-frame-pointer -DSIGNALSMITH_USE_ACCELERATE
        -Iengine/include -Iengine/src -Iengine/dsp/include -Iengine/third_party/pugixml
        -Iengine/third_party/signalsmith -Iengine/third_party/vst3 -Iengine/third_party/clap/include)
"$CXX" --version | head -1

# Build (incremental by modification time; any changed header or flag rebuilds everything).
stamp="$out/obj/.stamp"
if [ -f "$stamp" ] && { [ "$0" -nt "$stamp" ] || [ -n "$(find engine -name '*.h' -newer "$stamp" -o -name '*.hpp' -newer "$stamp" -o -name '*.inc' -newer "$stamp" | head -1)" ]; }; then
  rm -f "$out"/obj/*.o
fi
objs=()
while IFS= read -r f; do
  o="$out/obj/$(echo "$f" | tr '/' '_').o"
  objs+=("$o")
  [ "$o" -nt "$f" ] && continue
  case "$f" in
    # Homebrew clang + SDK headers: AppKit and pugixml need <float.h> first; forcing it everywhere breaks <cmath>.
    *.mm) "$CXX" -std=c++20 -fobjc-arc -include float.h -fsanitize=fuzzer-no-link "${common[@]}" -c "$f" -o "$o" ;;
    *pugixml.cpp) "$CXX" -std=c++20 -include float.h -fsanitize=fuzzer-no-link "${common[@]}" -c "$f" -o "$o" ;;
    *) "$CXX" -std=c++20 -fsanitize=fuzzer-no-link "${common[@]}" -c "$f" -o "$o" ;;
  esac
done < <(find engine/src engine/dsp/src -name '*.cpp' -o -name '*.mm' | grep -v '/fx/channel_eq_cuts' | sort; echo engine/third_party/pugixml/pugixml.cpp)
touch "$stamp"
"$CXX" -std=c++20 -fsanitize=fuzzer "${common[@]}" tools/fuzz/fuzz_projects.cpp "${objs[@]}" -o "$out/fuzz_projects" \
  -framework AudioToolbox -framework CoreAudio -framework CoreMIDI -framework CoreFoundation -framework AppKit \
  -framework AVFoundation -framework Accelerate -lz

# Seeds: one generated project per preset (format byte 0), plus small hand-written documents per importer.
seeds="$out/seeds"
rm -rf "$seeds"; mkdir -p "$seeds"
for preset in demo band midi states; do
  dir=$(mktemp -d "${TMPDIR:-/tmp}/dalnok-fuzz-seed.XXXXXX")
  scripts/make-test-project.sh "$dir" "$preset" >/dev/null 2>&1 || true
  for f in "$dir"/*/*.dalnok; do [ -f "$f" ] && { printf '\0'; cat "$f"; } > "$seeds/dalnok-$preset"; done
  rm -rf "$dir"
done
python3 - "$seeds" <<'PY'
import os, sys
seeds = sys.argv[1]
docs = {
    1: '<REAPER_PROJECT 0.1 "7.0" 0\n  TEMPO 120 4 4\n  <TRACK\n    NAME "A"\n    VOLPAN 1 0 -1 -1 1\n    <ITEM\n      POSITION 0\n      LENGTH 1\n      <SOURCE WAVE\n        FILE "a.wav"\n      >\n    >\n  >\n>\n',
    2: '<?xml version="1.0" encoding="UTF-8"?>\n<Ableton MajorVersion="5" MinorVersion="11.0_433"><LiveSet><Tracks><AudioTrack Id="1"><Name><EffectiveName Value="A"/></Name>'
       '<DeviceChain><MainSequencer><Sample><ArrangerAutomation><Events><AudioClip Time="0"><CurrentStart Value="0"/><CurrentEnd Value="4"/>'
       '<SampleRef><FileRef><Path Value="a.wav"/></FileRef></SampleRef></AudioClip></Events></ArrangerAutomation></Sample></MainSequencer></DeviceChain>'
       '</AudioTrack></Tracks><MasterTrack><DeviceChain><Mixer><Tempo><Manual Value="120"/></Tempo></Mixer></DeviceChain></MasterTrack></LiveSet></Ableton>\n',
    4: '<?xml version="1.0" encoding="UTF-8"?>\n<fcpxml version="1.10"><resources><format id="r1" frameDuration="1/48000s"/>'
       '<asset id="r2" name="a" start="0s" duration="1s" hasAudio="1"><media-rep kind="original-media" src="file:///tmp/a.wav"/></asset></resources>'
       '<library><event><project name="P"><sequence format="r1" duration="1s"><spine><asset-clip ref="r2" offset="0s" duration="1s" name="a"/></spine>'
       '</sequence></project></event></library></fcpxml>\n',
    5: '<?xml version="1.0" encoding="UTF-8"?>\n<Project version="1.0"><Transport><Tempo value="120" unit="bpm"/></Transport><Structure>'
       '<Track contentType="audio" id="t1" name="A"><Channel id="c1" role="regular"/></Track></Structure><Arrangement><Lanes>'
       '<Lanes track="t1"><Clips><Clip time="0" duration="2"><Audio><File path="a.wav"/></Audio></Clip></Clips></Lanes></Lanes></Arrangement></Project>\n',
}
for kind, text in docs.items():
    with open(os.path.join(seeds, f'kind{kind}'), 'wb') as f: f.write(bytes([kind]) + text.encode())
PY
# Logic: the generated ProjectData layout from the engine tests (synthesized, not from any real project).
DALNOK_FUZZ_SEED_DIR="$PWD/$seeds" swift test --disable-sandbox --filter LogicImport/parsesFilesRegionsAndPlacements >/dev/null 2>&1 || true
[ -f "$seeds/logic-generated" ] || { echo "fuzz: could not generate the Logic seed" >&2; exit 1; }

# Earlier findings must now pass; replay them, then keep them as regression inputs.
printf 'leak:fuzzer::StartRssThread\n' > "$out/lsan.supp"
export ASAN_OPTIONS=detect_leaks=1 LSAN_OPTIONS="suppressions=$PWD/$out/lsan.supp"
mkdir -p "$out/regressions"
for f in "$out"/artifacts/crash-* "$out"/artifacts/timeout-* "$out"/artifacts/leak-* "$out"/artifacts/oom-*; do
  [ -f "$f" ] || continue
  "$out/fuzz_projects" -timeout=10 -rss_limit_mb=4096 "$f" >/dev/null 2>&1 || { echo "fuzz: $f still fails" >&2; exit 1; }
  mv "$f" "$out/regressions/"
done
[ -z "$(ls "$out/regressions")" ] || "$out/fuzz_projects" -timeout=10 -rss_limit_mb=4096 "$out"/regressions/* >/dev/null 2>&1
echo "fuzzing for ${seconds}s ($(ls "$seeds" | wc -l | tr -d ' ') seeds)"
jobs="${DALNOK_FUZZ_JOBS:-1}"
args=(-max_total_time="$seconds" -timeout=10 -rss_limit_mb=4096 -max_len=262144 -print_final_stats=1
      -artifact_prefix="$out/artifacts/" "$out/corpus" "$seeds")
if [ "$jobs" -gt 1 ]; then args=(-jobs="$jobs" -workers="$jobs" "${args[@]}"); fi
# (lsan.supp: libFuzzer's own RSS-monitor thread is still running at exit; that is not a parser leak.)
"$out/fuzz_projects" "${args[@]}"
if ls "$out/artifacts"/crash-* "$out/artifacts"/timeout-* "$out/artifacts"/leak-* "$out/artifacts"/oom-* >/dev/null 2>&1; then
  echo "fuzz: findings in $out/artifacts" >&2
  exit 1
fi
# Property check: 1,000 random models must survive save -> load -> save unchanged.
DALNOK_PROPERTY_ITERATIONS="${DALNOK_PROPERTY_ITERATIONS:-1000}" swift test --disable-sandbox \
  --filter ProjectParsingRobustness/randomProjectsRoundTripThroughTheWriter
echo "fuzz: clean"
