#!/usr/bin/env bash
# No arguments: validate rejection paths without opening hardware.
# Pass a device name to run a short, silent-output hardware probe.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/dalnok-duplex-probe.XXXXXX")
trap 'rm -f "$binary"' EXIT
"${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror=function-effects -Iengine/src \
  tests/native/duplex_probe.cpp engine/src/platform/macos/coreaudio_device.cpp \
  -framework AudioToolbox -framework CoreAudio -framework CoreFoundation -o "$binary"
"$binary" "$@"
