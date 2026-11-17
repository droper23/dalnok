// Hosted plugin instances (ADR-0009 stage 3). Created, configured and destroyed on the control
// thread; `process` runs on the audio thread (or an offline render's thread, never both: offline
// renders load their own instances). Format adapters live under platform/ (VST3 first).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "rt.hpp"
#include <cstdint>
#include <memory>
#include <string>

namespace dalnok {

// A note event inside one processing block.
struct PluginNote {
    int32_t offset;   // frame within the block
    uint8_t on;       // 1 = note-on, 0 = note-off
    uint8_t pitch, velocity;
};

class PluginProcessor {
public:
    virtual ~PluginProcessor() = default;
    virtual bool instrument() const = 0;   // has an event input and no audio input
    virtual uint32_t latency() const = 0;  // frames
    virtual const std::string &name() const = 0;
    virtual const std::string &vendor() const = 0;
    virtual const std::string &classId() const = 0; // hex
    // Processes in place: effects read left/right, instruments overwrite them. frames <= kMaxBlock.
    // Calls into plugin code, which cannot be checked for real-time safety (ADR-0009).
    virtual void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING = 0;
    // Opaque plugin state (control thread).
    virtual bool getState(std::string &bytes) = 0;
    virtual bool setState(const std::string &bytes) = 0;
};

// Loads a VST3 bundle in this process. `classId` (32 hex digits) picks a class; empty = the first
// audio processor class. Activated for stereo at `sampleRate` with blocks up to `maxBlock` frames.
std::unique_ptr<PluginProcessor> loadVst3(const std::string &bundle, const std::string &classId, double sampleRate,
                                          int maxBlock, bool offline, std::string &err);

std::string base64Encode(const std::string &bytes);
bool base64Decode(const std::string &text, std::string &bytes);

} // namespace dalnok
