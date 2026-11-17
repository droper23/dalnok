#!/usr/bin/env bash
# Exercise the recording capture buffer, optionally with ThreadSanitizer.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/dalnok-capture-ring.XXXXXX")
trap 'rm -f "$binary"' EXIT
flags=(-std=c++20 -O1 -g -Wall -Wextra -Werror=function-effects -Iengine/src)
if [[ "${DALNOK_CAPTURE_TSAN:-0}" == "1" ]]; then flags+=(-fsanitize=thread); fi
for test in capture_ring capture_writer capture_spool; do
  "${CXX:-clang++}" "${flags[@]}" "tests/native/$test.cpp" -o "$binary"
  "$binary"
  echo "$test: PASS"
done
