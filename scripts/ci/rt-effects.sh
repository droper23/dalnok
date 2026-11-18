#!/usr/bin/env bash
# Verifies real-time effect analysis ([[clang::nonblocking]]) with a compiler
# that supports it, independent of the Xcode version on the machine.
# Fails if any engine source violates the effects OR if the analysis is inert.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
# Homebrew LLVM: the unversioned formula if present, else the newest llvm@N.
if [ -z "${CXX:-}" ]; then
  for p in "$(brew --prefix llvm 2>/dev/null)" $(ls -d "$(brew --prefix)"/opt/llvm@* 2>/dev/null | sort -rV); do
    [ -x "$p/bin/clang++" ] && CXX="$p/bin/clang++" && break
  done
fi
CXX="${CXX:?no Homebrew LLVM found (brew install llvm)}"
SDK="$(xcrun --show-sdk-path)"
flags=(-std=c++20 -fsyntax-only -isysroot "$SDK" -Iengine/include -Iengine/src -Iengine/dsp/include
       -Iengine/third_party/pugixml -Iengine/third_party/signalsmith -Iengine/third_party/vst3 -Iengine/third_party/clap/include -DSIGNALSMITH_USE_ACCELERATE -Werror=function-effects)
"$CXX" --version | head -1
# Every engine source (all subfolders) plus the DSP target.
while IFS= read -r f; do
  "$CXX" "${flags[@]}" "$f"
done < <(find engine/src engine/dsp/src -name '*.cpp' | sort)
echo "engine sources: effect-clean"
neg=$(mktemp -d)/neg.cpp
printf '#include "rt.hpp"\n#include <vector>\nvoid f(std::vector<float>& v) DALNOK_NONBLOCKING { v.push_back(1.f); }\n' > "$neg"
if "$CXX" "${flags[@]}" "$neg" 2>/dev/null; then
  echo "ERROR: allocation inside DALNOK_NONBLOCKING compiled — effect analysis is not active" >&2
  exit 1
fi
echo "negative check: violation correctly rejected"
