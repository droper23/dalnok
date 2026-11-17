#!/usr/bin/env bash
# MIDI parser tests; set DALNOK_MIDI_TSAN=1 to enable ThreadSanitizer.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/dalnok-midi-parser.XXXXXX")
trap 'rm -f "$binary"' EXIT
flags=(-std=c++20 -O1 -g -Wall -Wextra -Werror=function-effects -Iengine/src)
if [[ "${DALNOK_MIDI_TSAN:-0}" == "1" ]]; then flags+=(-fsanitize=thread); fi
"${CXX:-clang++}" "${flags[@]}" tests/native/midi_parser.cpp -o "$binary"
"$binary"
echo 'MIDI parser: PASS'
