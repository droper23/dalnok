// Platform-neutral MIDI source discovery; MIDI I/O and model are separate work.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <string>
#include <vector>
namespace dalnok {
struct MidiSourceInfo { int32_t uniqueId = 0; std::string name; };
std::vector<MidiSourceInfo> listMidiSources();
}
