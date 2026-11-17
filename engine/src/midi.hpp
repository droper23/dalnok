// Platform-neutral MIDI source discovery and input connection.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
namespace dalnok {
class MidiParser;
struct MidiSourceInfo { int32_t uniqueId = 0; std::string name; };
std::vector<MidiSourceInfo> listMidiSources();
// Connects a source (by unique ID) to a new input port whose receive thread feeds the parser
// published in `slot` (loaded with acquire; that thread is the parser's only producer).
// `client` is created on first use; releasing it closes all ports.
bool connectMidiSource(std::shared_ptr<void> &client, int32_t uniqueId, std::atomic<MidiParser *> *slot, std::string &err);
}
