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
// One MIDI event for a plug-in instrument. `on` is the kind: 0 note-off and 1 note-on (pitch, velocity); 2 control
// change (pitch = controller 0-127, velocity = value 0-127); 3 pitch bend (pitch = low 7 bits, velocity = high 7 bits;
// 8192 = centre).
enum : uint8_t { kEventNoteOff = 0, kEventNoteOn = 1, kEventControl = 2, kEventPitchBend = 3 };
struct PluginNote {
    int32_t offset;   // frame within the block
    uint8_t on;       // kind (see above)
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
    // What the plug-in declares it is, '|'-separated: VST3 subcategories, CLAP features, Audio Unit tags, or a
    // built-in's category. Empty when it declares nothing.
    virtual std::string categories() const { return {}; }
    virtual const std::string &classId() const = 0; // hex
    // Processes in place: effects read left/right, instruments overwrite them. frames <= kMaxBlock.
    // Calls into plugin code, which cannot be checked for real-time safety (ADR-0009).
    virtual void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING = 0;
    // Split processing, so isolated plug-ins on different tracks run at the same time (ADR-0014): beginProcess
    // starts a block and returns true when the result is still to come, in which case finishProcess must be called
    // later with the same buffers (untouched in between). In-process plug-ins process at once and return false.
    virtual bool beginProcess(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING {
        process(left, right, frames, notes, noteCount);
        return false;
    }
    virtual void finishProcess(float *left, float *right, int frames) DALNOK_NONBLOCKING { (void)left; (void)right; (void)frames; }
    // Peak levels entering and leaving process() since the UI last read them (the render raises, the UI resets).
    std::atomic<float> meterIn[2]{}, meterOut[2]{};
    // Recent mono input and output for displays (spectrum, scope). Created on the main thread the first time the UI
    // asks, never replaced or freed while the processor lives; the render writes it only once it exists.
    struct Tap {
        static constexpr uint32_t kSize = 8192; // power of two
        std::atomic<float> in[kSize]{}, out[kSize]{};      // mono
        std::atomic<float> outL[kSize]{}, outR[kSize]{};   // the output in stereo (goniometer)
        std::atomic<uint32_t> pos{0};
    };
    std::atomic<Tap *> tap{nullptr};
    std::unique_ptr<Tap> tapStorage;
    // Exact magnitude response in dB at `hz` (main thread), for plug-ins that can compute it (built-in EQs).
    virtual bool response(const double *hz, int count, double *db) { (void)hz; (void)count; (void)db; return false; }
    // Opaque plugin state (control thread).
    virtual bool getState(std::string &bytes) = 0;
    // Recovery snapshots (every 30 s while there are unsaved changes): a plug-in may answer with the state it last
    // gave if nothing has changed it since. Isolated plug-ins use this to skip a round trip each.
    virtual bool getStateForSnapshot(std::string &bytes) { return getState(bytes); }
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
    // The callback's shared deadline for isolated plug-ins (CLOCK_UPTIME_RAW ns; 0 = none). Audio thread, before process.
    // `waitSink` (may be null) accumulates the time spent waiting on an isolated host.
    void setDeadline(uint64_t ns, uint64_t *waitSink = nullptr) DALNOK_NONBLOCKING { deadlineNs_ = ns; waitSink_ = waitSink; }
    // Audio thread, while the transport is stopped and `process` is not called: lets a plug-in exchange parameter
    // changes with the host (a CLAP plug-in's request_flush, so edits in its editor reach Dalnok at once).
    virtual void idle() DALNOK_NONBLOCKING {}
protected:
    uint64_t deadlineNs_ = 0;
    uint64_t *waitSink_ = nullptr;
    const float *scL_ = nullptr, *scR_ = nullptr;
    static constexpr int kMaxAuto = 64;
    struct AutoChange { uint32_t id; double value; };
    AutoChange autoQueue_[kMaxAuto]{};
    int autoCount_ = 0;
public:

    // The plugin's own editor (main thread). `parent` is an NSView on macOS. `onResize` is called
    // when the editor asks for a new size.
    // Out-of-process instances (ADR-0014): why the instance stopped working (empty = fine), a control-thread health
    // check that may set it, and whether this instance runs in its own process.
    virtual std::string failure() const { return {}; }
    virtual void poll() {}
    virtual bool isolated() const { return false; }

    virtual bool hasEditor() = 0;
    virtual bool openEditor(void *parent, int32_t &width, int32_t &height, void (*onResize)(void *ctx, int32_t w, int32_t h),
                            void *ctx, std::string &err) = 0;
    virtual void closeEditor() = 0;

    // Isolated instances (ADR-0015): the editor opens in a window owned by the host process instead of `openEditor`.
    // `x`, `y`: the window's top-left in screen coordinates (NaN centers). Main thread.
    struct EditorWindowInfo {
        bool visible = false, open = false;
        double x = 0, y = 0, width = 0, height = 0, contentWidth = 0, contentHeight = 0;
        int64_t windowNumber = 0, level = 0;
        int32_t processId = 0;
    };
    virtual bool showEditorWindow(const std::string &title, double x, double y, std::string &err) {
        (void)title; (void)x; (void)y;
        err = "this plug-in's editor opens inside Dalnok";
        return false;
    }
    virtual bool editorWindow(EditorWindowInfo &out) { (void)out; return false; }
    // A key the isolated editor's window did not use (its window has the keyboard while Dalnok stays active), passed
    // back so Dalnok's own shortcuts still work. Main thread; false when there is none.
    struct EditorKey {
        uint16_t keyCode = 0;
        uint64_t modifiers = 0;       // NSEventModifierFlags
        char characters[16] = {}, charactersIgnoringModifiers[16] = {};
    };
    virtual bool takeEditorKey(EditorKey &out) { (void)out; return false; }
    virtual bool editorSnapshot(const std::string &pngPath) { (void)pngPath; return false; }

    // Isolated instances: the audio device's workgroup for the host's processing thread to join (a Mach send right,
    // copied; 0 = leave), and how the instance is doing. Control thread.
    virtual void shareWorkgroup(uint32_t port) { (void)port; }
    struct IsolationStats {
        uint64_t missedBlocks = 0, budgetSkips = 0;
        bool workgroupJoined = false;
        int32_t workgroupError = 0; // os_workgroup_join's result for the last workgroup offered (0 = joined)
        uint32_t workgroupJoins = 0;
    };
    virtual bool isolationStats(IsolationStats &out) { (void)out; return false; }
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
