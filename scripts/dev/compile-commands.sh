#!/usr/bin/env bash
# Writes compile_commands.json for the C++ engine, DSP and tools (clangd, clang-tidy, IDEs).
# SwiftPM does not emit one: this builds the C/C++ targets in a separate scratch directory with clang's
# -gen-cdb-fragment-path (one fragment per source) and merges the fragments. The normal .build is untouched.
# Usage: scripts/dev/compile-commands.sh [output path, default ./compile_commands.json]
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${1:-compile_commands.json}
scratch=.build/compile-commands
fragments="$scratch/fragments"
rm -rf "$fragments"
mkdir -p "$fragments"
for target in DalnokDSP DalnokEngine dalnok-scan; do
  swift build --scratch-path "$scratch" --target "$target" -Xcc -gen-cdb-fragment-path -Xcc "$PWD/$fragments" >/dev/null
done
python3 - "$fragments" "$out" <<'PY'
import json, os, sys
frag, out = sys.argv[1], sys.argv[2]
entries = {}
for name in sorted(os.listdir(frag)):
    text = open(os.path.join(frag, name)).read().strip().rstrip(',')
    for e in json.loads('[' + text + ']'):
        entries[e['file']] = e  # one entry per source (the newest build wins)
json.dump(list(entries.values()), open(out, 'w'), indent=1)
print(f"{out}: {len(entries)} sources")
PY
