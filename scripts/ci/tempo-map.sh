#!/usr/bin/env bash
# Standalone, generated-data tempo conversion checks.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/dalnok-tempo-map.XXXXXX")
trap 'rm -f "$binary"' EXIT
"${CXX:-clang++}" -std=c++20 -O1 -g -Wall -Wextra -Werror -Iengine/src \
  tests/native/tempo_map.cpp engine/src/tempo_map.cpp -o "$binary"
"$binary"
