// Standard MIDI Files (SMF, formats 0 and 1): read into tracks of notes and controller events in beats, and write a
// clip back out. The reader is a parser of untrusted bytes: every length is checked, and sizes are bounded.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace dalnok {

struct SmfNote { double beat, length; uint8_t pitch, velocity, channel; };
struct SmfController { double beat; uint8_t controller; uint16_t value; }; // controller 128 = pitch bend (0-16383)
struct SmfTrack {
    std::string name;
    std::vector<SmfNote> notes;
    std::vector<SmfController> controllers;
};
struct SmfTempo { double beat, bpm; };
struct SmfFile {
    std::vector<SmfTrack> tracks; // only tracks with notes or controllers
    std::vector<SmfTempo> tempo;  // from the file (first at beat 0 when present)
    int32_t meterNum = 4, meterDen = 4;
    double lengthBeats = 0;       // the last event
};

bool parseMidiFile(const std::string &bytes, SmfFile &out, std::string &err);
// One track (format 1: a tempo track, then the notes), 960 ticks per quarter note.
std::string writeMidiFile(const SmfTrack &track, const std::vector<SmfTempo> &tempo, int32_t meterNum, int32_t meterDen);

} // namespace dalnok
