// Experimental Logic channel-strip mixer settings.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <map>
#include <string>

namespace dalnok::import {
struct LogicMix { float gainDb = 0.0f, pan = 0.0f; bool muted = false, gainClamped = false; };
// Keyed by Envi strip ID. Ambiguous or unrecognised channel records are omitted.
std::map<uint32_t, LogicMix> logicMixer(const std::string &data);
}
