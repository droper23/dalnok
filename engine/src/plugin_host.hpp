// Hosted plugin instances (ADR-0009 stage 3). Created, configured and destroyed on the control
// thread; `process` runs on the audio thread (or an offline render's thread, never both: offline
// renders load their own instances). Format adapters live under platform/ (VST3 first).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <atomic>
#include "rt.hpp"
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace dalnok {

// A note event inside one processing block.
struct PluginNote {
    int32_t offset;   // frame within the block
    uint8_t on;       // 1 = note-on, 0 = note-off
    uint8_t pitch, velocity;
};

struct PluginParameter {
    uint32_t id = 0;
    std::string title, units, display;
    double value = 0, defaultValue = 0; // normalized 0…1
    int32_t stepCount = 0;
    bool automatable = false, readOnly = false, hidden = false;
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
    // Peak levels entering and leaving process() since the UI last read them (the render raises, the UI resets).
    std::atomic<float> meterIn[2]{}, meterOut[2]{};
    // Opaque plugin state (control thread).
    virtual bool getState(std::string &bytes) = 0;
    virtual bool setState(const std::string &bytes) = 0;
    // Restoring a saved document can differ from loading a preset (notably for Audio Units).
    virtual bool setStateFromDocument(const std::string &bytes) { return setState(bytes); }
    virtual std::string stateError() const { return {}; }

    // Parameters (control thread). Changes reach the audio thread through a bounded queue and are
    // applied at the start of the next block.
    virtual int32_t parameterCount() = 0;
    virtual bool parameter(int32_t index, PluginParameter &out) = 0;
    // The plug-in's text for parameter `id` at any normalized value (printed knob scales). Main thread.
    virtual bool parameterText(uint32_t id, double normalized, std::string &out) { (void)id; (void)normalized; (void)out; return false; }
    virtual bool setParameter(uint32_t id, double normalized) = 0;
    // Parameters changed since load or the last state capture (for offline instances).
    virtual void touchedParameters(std::vector<std::pair<uint32_t, double>> &out) = 0;
    // Incremented whenever the plugin's own editor changes a parameter (any thread).
    virtual uint64_t editCount() const = 0;
    // Automation. `automationRange` (control thread) maps a normalized 0-1 value to the value `automate`
    // takes; `automate` (audio thread, between blocks) queues it for the start of the next process call.
    virtual bool automationRange(uint32_t id, double &lo, double &hi) { (void)id; lo = 0; hi = 1; return true; }
    void automate(uint32_t id, double value) DALNOK_NONBLOCKING {
        if (autoCount_ < kMaxAuto) autoQueue_[autoCount_++] = {id, value};
    }
    // Sidechain: plug-ins with an auxiliary input. `setSidechain` (audio thread, before process) points at
    // this block's sidechain signal (frames long); nullptr feeds silence.
    virtual bool hasSidechain() const { return false; }
    void setSidechain(const float *l, const float *r) DALNOK_NONBLOCKING { scL_ = l; scR_ = r; }
protected:
    const float *scL_ = nullptr, *scR_ = nullptr;
    static constexpr int kMaxAuto = 64;
    struct AutoChange { uint32_t id; double value; };
    AutoChange autoQueue_[kMaxAuto]{};
    int autoCount_ = 0;
public:

    // The plugin's own editor (main thread). `parent` is an NSView on macOS. `onResize` is called
    // when the editor asks for a new size.
    virtual bool hasEditor() = 0;
    virtual bool openEditor(void *parent, int32_t &width, int32_t &height, void (*onResize)(void *ctx, int32_t w, int32_t h),
                            void *ctx, std::string &err) = 0;
    virtual void closeEditor() = 0;
};

// Loads a VST3 bundle in this process. `classId` (32 hex digits) picks a class; empty = the first
// audio processor class. Activated for stereo at `sampleRate` with blocks up to `maxBlock` frames.
std::unique_ptr<PluginProcessor> loadVst3(const std::string &bundle, const std::string &classId, double sampleRate,
                                          int maxBlock, bool offline, std::string &err);

// Loads a registered Audio Unit by "type:subtype:manufacturer" (macOS).
std::unique_ptr<PluginProcessor> loadAudioUnit(const std::string &id, double sampleRate, int maxBlock, std::string &err);
// Loads a .clap bundle in this process; `id` picks a plug-in (empty = the first).
std::unique_ptr<PluginProcessor> loadClap(const std::string &path, const std::string &id, double sampleRate, int maxBlock,
                                          std::string &err);
// Dispatches on format ("vst3" or "clap" bundle path, or "au" identifier).
std::unique_ptr<PluginProcessor> loadPlugin(const std::string &format, const std::string &path, const std::string &classId,
                                            double sampleRate, int maxBlock, bool offline, std::string &err);

std::string base64Encode(const std::string &bytes);
bool base64Decode(const std::string &text, std::string &bytes);

} // namespace dalnok
