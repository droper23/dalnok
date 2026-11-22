#!/bin/bash
# Regenerates the README's screenshots, GIFs and videos from the real app, for every theme and version.
#   scripts/dev/readme-media.sh [work-dir]
# Needs: an unlocked screen with Screen Recording allowed for the terminal (tours and plug-in clips are real screen
# recordings), ffmpeg, and nothing else running Dalnok (app runs share one preferences domain, which this script backs up
# and restores). Uses a generated project and built-in or Apple plug-ins only.
# Writes assets/screenshots/*.png|gif and assets/videos/*.mp4. Release Checklist section 4 describes the standard.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
W="${1:-$(mktemp -d -t dalnok-media)}"
mkdir -p "$W"
S="$ROOT/assets/screenshots" V="$ROOT/assets/videos"
mkdir -p "$S" "$V"
command -v ffmpeg >/dev/null || { echo "needs ffmpeg"; exit 1; }

swift build -c release >/dev/null
swift build >/dev/null
scripts/make-test-project.sh "$W/proj" band >/dev/null
PROJ="$W/proj/band" # the project folder (band.dalnok and its Audio Files)
defaults export Dalnok "$W/prefs-backup.plist" 2>/dev/null || true
restore() { [ -f "$W/prefs-backup.plist" ] && defaults import Dalnok "$W/prefs-backup.plist"; }
trap restore EXIT

# theme variant file-stem
VARIANTS=("graphite dark graphite" "warmAnalog dark warm-analog" "prism dark prism-dark" "prism light prism-light"
          "atelier light atelier-light" "atelier dark atelier-dark")

fresh_copy() { local d="$W/work-$1"; rm -rf "${d:?}"; mkdir -p "$d"; cp -R "$PROJ" "$d/"; /bin/ls -d "$d"/band/*.dalnok | head -1; }

# Screen-records one scripted run. mode: tour (whole window) or plugin-ops (device panel only).
record() {
  local theme=$1 variant=$2 mode=$3 out=$4 p
  local log="$W/$theme-$variant-$mode.log"
  p=$(fresh_copy "$theme-$variant-$mode"); rm -f "$out" "$log"
  local envs=(DALNOK_RECOVERY_DIR="$W/recovery" DALNOK_THEME="$theme" DALNOK_VARIANT="$variant" DALNOK_TOUR_FRAMES=0 DALNOK_TOUR_DELAY=2.5)
  [ "$mode" = plugin-ops ] && envs+=(DALNOK_TOUR_MODE=plugin-ops)
  env "${envs[@]}" .build/release/Dalnok "$p" --tour "$W/unused" > "$log" 2>&1 &
  local pid=$! i line dur
  for i in $(seq 1 100); do grep -qE "tour (window|panel):" "$log" && break; /bin/sleep 0.1; done
  if [ "$mode" = plugin-ops ]; then line=$(grep "tour panel:" "$log"); dur=20.6; else line=$(grep "tour window:" "$log"); dur=12.5; fi
  read -r x y w h <<<"$(echo "$line" | awk '{print $3, $4, $5, $6}')"
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
  python3 -c "import Quartz; Quartz.CGWarpMouseCursorPosition((2, 540))" 2>/dev/null || true # no tooltips in the shot
  /bin/sleep 0.8
  screencapture -v -x -V "$dur" -R"$x,$y,$w,$h" "$out"
  wait "$pid" 2>/dev/null || true
}

encode() { # mov stem gif-width
  ffmpeg -v error -y -i "$1" -c:v libx264 -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$V/$2.mp4"
  ffmpeg -v error -y -i "$1" -vf "fps=12,scale=$3:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" "$S/$2.gif"
}

for v in "${VARIANTS[@]}"; do
  set -- $v; theme=$1 variant=$2 stem=$3
  echo "== $stem"
  g="$W/gallery-$stem"; rm -rf "${g:?}"
  DALNOK_RECOVERY_DIR="$W/recovery" DALNOK_THEME=$theme DALNOK_VARIANT=$variant timeout 150 .build/debug/Dalnok "$(fresh_copy "gallery-$stem")" --gallery "$g" >/dev/null 2>&1
  sips -s format png -Z 1800 "$g/00-hero.png" --out "$S/$stem.png" >/dev/null
  sips -Z 1400 "$g/08-piano-roll.png" --out "$S/piano-roll-$stem.png" >/dev/null
  sips -Z 1400 "$g/12-composition-overview.png" --out "$S/overview-$stem.png" >/dev/null
  sips -Z 1400 "$g/05-mixer.png" --out "$S/mixer-$stem.png" >/dev/null
  case $stem in
    prism-dark) sips -Z 1200 "$g/09-settings.png" --out "$S/settings.png" >/dev/null ;;
    prism-light) sips -Z 1400 "$g/10-palette.png" --out "$S/palette.png" >/dev/null ;;
    atelier-light) sips -Z 1400 "$g/07-plugin-browser.png" --out "$S/plugin-browser.png" >/dev/null ;;
  esac
  record "$theme" "$variant" tour "$W/tour-$stem.mov" && encode "$W/tour-$stem.mov" "tour-$stem" 960
  record "$theme" "$variant" plugin-ops "$W/plugins-$stem.mov" && encode "$W/plugins-$stem.mov" "plugins-$stem" 1200
done
echo "done: $S, $V (work files in $W)"
