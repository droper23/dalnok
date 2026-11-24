// Immutable render snapshots and the real-time mixing routine.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The control thread compiles the session model into a RenderState and hands
// it to the audio thread through a single atomic slot. The audio thread never
// allocates, frees, or locks; retired snapshots go back through a queue and
// are destroyed on the control thread. See 03 - Architecture/Real-Time Processing.md.
#pragma once

#include "media.hpp"
#include "rt.hpp"
#include "synth.hpp"
#include "plugin_host.hpp"
#include <algorithm>
#include <array>
#include <cmath>

#include <atomic>
#include <memory>
#include <vector>

namespace dalnok {

// Per-track parameters shared between threads. Targets are written by the
// control thread; `cur*` smoothing state is owned by the audio thread.
struct TrackRuntime {
    std::atomic<float> gain{1.0f}; // linear
    std::atomic<float> pan{0.0f};
    std::atomic<bool> muted{false};
    std::atomic<bool> solo{false};
    // Post-fader peak since the meter was last read (audio thread raises, UI resets).
    std::atomic<float> peakL{0.0f}, peakR{0.0f};
    float meterDcL = 0, meterDcR = 0; // DC tracked out of the meter (audio thread; see meterLevel)
    float curL = 0, curR = 0;
    bool primed = false;
    // Instrument voices (audio thread): timeline playback and live MIDI input.
    SynthState play, live;
    // Clip launcher. The control thread posts a request (target slot, or -1 = back to the arrangement)
    // to take effect at `launchAt`; the audio thread switches exactly there and keeps the playing state.
    std::atomic<int64_t> launchAt{-1};
    std::atomic<int32_t> launchTarget{-1};
    std::atomic<int32_t> playingSlot{-1};
    // Automation write (Touch/Latch): while held, the fader/knob value plays instead of the lane.
    std::atomic<bool> holdVolume{false}, holdPan{false}; // what the audio thread plays (-1 = the arrangement); readable by the UI
    std::atomic<int64_t> slotStart{0};    // timeline frame where the playing slot's first loop began (audio thread writes)
    int32_t slotLoops = 0;                // completed loops of the playing slot (audio thread)
};

// Raises a meter atomic to `v` if larger. A concurrent reset may be overwritten
// by one stale value; harmless for metering.
inline void raisePeak(std::atomic<float> &a, float v) DALNOK_NONBLOCKING {
    if (v > a.load(std::memory_order_relaxed)) a.store(v, std::memory_order_relaxed);
}

// One sample's meter level with its DC offset removed, updating the tracked offset `dc` (one pole, about 40 ms at
// 48 kHz, so a cutoff near 4 Hz). A constant offset in a recording is inaudible and must not light the track and
// master meters (or the gain-knob rings that follow them); every audible frequency passes unchanged in level.
// A sample at or over full scale reads as itself: the file (and the converter) clip it, offset or not, so the clip
// lamp must light.
inline float meterLevel(float v, float &dc) DALNOK_NONBLOCKING {
    constexpr float k = 5e-4f;
    dc += k * (v - dc);
    const float a = std::fabs(v);
    return a >= 1.0f ? a : std::fabs(v - dc);
}

// Raises a stereo meter pair (a plug-in's input or output) to the block's peaks.
inline void raisePeaks(std::atomic<float> (&m)[2], const float *l, const float *r, int frames) DALNOK_NONBLOCKING {
    float pl = 0, pr = 0;
    for (int i = 0; i < frames; ++i) { pl = std::max(pl, std::fabs(l[i])); pr = std::max(pr, std::fabs(r[i])); }
    raisePeak(m[0], pl);
    raisePeak(m[1], pr);
}

// Writes a block into a plug-in's display tap (mono). `advance` moves the write position (after the output).
inline void writeTap(std::atomic<float> *buf, std::atomic<uint32_t> &pos, const float *l, const float *r, int frames, bool advance) DALNOK_NONBLOCKING {
    constexpr uint32_t mask = PluginProcessor::Tap::kSize - 1;
    const uint32_t p = pos.load(std::memory_order_relaxed);
    for (int i = 0; i < frames; ++i) buf[(p + static_cast<uint32_t>(i)) & mask].store(0.5f * (l[i] + r[i]), std::memory_order_relaxed);
    if (advance) pos.store(p + static_cast<uint32_t>(frames), std::memory_order_release);
}

// Writes a block of a plug-in's stereo output into its display tap (before the mono write advances the position).
inline void writeTapStereo(PluginProcessor::Tap &tap, const float *l, const float *r, int frames) DALNOK_NONBLOCKING {
    constexpr uint32_t mask = PluginProcessor::Tap::kSize - 1;
    const uint32_t p = tap.pos.load(std::memory_order_relaxed);
    for (int i = 0; i < frames; ++i) {
        tap.outL[(p + static_cast<uint32_t>(i)) & mask].store(l[i], std::memory_order_relaxed);
        tap.outR[(p + static_cast<uint32_t>(i)) & mask].store(r[i], std::memory_order_relaxed);
    }
}

enum FadeCurve : int32_t { kFadeLinear = 0, kFadeEqualPower = 1 };

struct RenderClip {
    std::shared_ptr<const Media> media;
    int64_t start = 0;  // timeline frame
    int64_t offset = 0; // frame within media
    int64_t length = 0; // frames
    int64_t fadeIn = 0, fadeOut = 0; // frames, fadeIn + fadeOut <= length
    int32_t curve = kFadeLinear;
    float gain = 1.0f; // linear clip gain
};

// A controller event in timeline frames (kind 2 = control change, 3 = pitch bend; data as in PluginNote).
struct RenderCC {
    int64_t at = 0;
    uint8_t kind = 2, d1 = 0, d2 = 0;
};

// A note in timeline frames, already clipped to its clip's window.
struct RenderNote {
    int64_t start = 0, end = 0;
    uint8_t pitch = 0, velocity = 0;
};

// A fixed stereo delay (plug-in delay compensation). Processed in place by the thread rendering the snapshot.
struct DelayLine {
    explicit DelayLine(int32_t frames) : l(static_cast<size_t>(frames) + 1, 0.0f), r(l), delay(frames) {}
    std::vector<float> l, r; // capacity delay + 1
    size_t w = 0;
    int32_t delay = 0;
    void process(float *L, float *R, int n) DALNOK_NONBLOCKING {
        const size_t cap = l.size();
        for (int i = 0; i < n; ++i) {
            l[w] = L[i];
            r[w] = R[i];
            const size_t rd = (w + cap - static_cast<size_t>(delay)) % cap;
            L[i] = l[rd];
            R[i] = r[rd];
            w = (w + 1) % cap;
        }
    }
};

// A send into a bus's input (slot = bus index in RenderState::busL/busR).
struct RenderSend {
    int32_t slot = -1;
    float gain = 1.0f; // linear
    std::vector<std::pair<int64_t, float>> autoGain; // automated level (fader taper, like volume); empty: `gain`
    bool pre = false;  // before the fader and pan
    DelayLine *delay = nullptr; // delay compensation on this connection (null = none)
};

// A launcher slot's clip: loops from its start; audio as a clip window, MIDI as notes relative to the loop.
struct RenderSlot {
    int32_t slot = -1;
    int32_t follow = 0;     // follow action after `followLoops` loops: 0 none, 1 next filled slot, 2 stop
    int32_t followLoops = 1;
    int32_t nextSlot = -1;  // the next filled slot on this track (wrapping), for "next"
    int64_t length = 0; // loop length in frames
    bool hasAudio = false;
    bool muted = false;
    RenderClip clip;    // audio (start ignored; placed per loop iteration)
    std::vector<RenderNote> notes, noteEnds; // MIDI, relative to the loop start, sorted by start / by end
};

// Everything a track plays that is derived from its clips. Immutable once built, so snapshots share it: a
// structural edit rebuilds only the tracks whose clips changed (A-04).
struct TrackContent {
    std::vector<RenderSlot> slots;    // launcher clips, sorted by slot
    std::vector<RenderClip> clips;    // z-order: later clips overwrite earlier ones
    std::vector<RenderNote> notes;    // sorted by start
    std::vector<RenderNote> noteEnds; // the same notes sorted by end (plugin note-offs)
    std::vector<RenderCC> controllers; // sorted by time (plug-in instruments only)
    bool stereoClip = false;          // some audio clip has more than one channel
    uint64_t mutedMidiSignature = 0;
};

struct RenderTrack {
    int32_t id = 0; // DalnokTrackId
    std::shared_ptr<TrackRuntime> runtime;
    std::shared_ptr<const TrackContent> content; // never null in a compiled snapshot
    bool bus = false;      // mixes its input slot instead of clips
    int32_t busSlot = -1;  // this bus's input slot
    int32_t output = -1;   // destination bus slot, -1 = master
    std::vector<RenderSend> sends;
    DelayLine *outDelay = nullptr; // delay compensation on the output connection (null = none)
    int32_t scSlot = -1;           // this track is a sidechain source: its pre-fader signal goes to this buffer
    std::vector<std::pair<PluginProcessor *, int32_t>> sidechainFeeds; // plug-ins here that listen to a buffer
    int32_t latency = 0;           // frames added by this track's plug-ins
    std::vector<TrackRuntime *> soloLinks; // tracks upstream and downstream in the routing (solo follows them)
    // Automation (empty = none): volume as fader taper (amplitude^(1/4)), pan -1..1, linear between points.
    std::vector<std::pair<int64_t, float>> volumeAuto, panAuto, muteAuto;
    // Plug-in parameter automation, applied once per block (block-rate) before the plug-in runs.
    struct PluginLane { PluginProcessor *plugin = nullptr; uint32_t param = 0; double lo = 0, hi = 1; std::vector<std::pair<int64_t, float>> pts; };
    std::vector<PluginLane> pluginAuto;
    bool monoSource = true;        // every clip is mono -> constant-power pan law
    uint64_t mutedMidiSignature = 0;
    int32_t inputChannel = -1;     // audio tracks: the device input they monitor (-1 = cannot monitor)
    bool inputStereo = false;      // and the next input as the right side
    bool inputMonitor = false, armed = false; // Input Monitoring on; record-enabled (monitors when armed monitoring is on)
    bool instrument = false;       // MIDI track (built-in synth unless instrumentPlugin is set)
    bool invert = false;           // phase (polarity) inverted before the inserts
    PluginProcessor *instrumentPlugin = nullptr;
    std::vector<PluginProcessor *> inserts;               // processing order
    std::vector<std::shared_ptr<PluginProcessor>> keep;   // keeps instances alive while this snapshot exists
};

// Metronome schedule: tempo segments (quarter-note beats) and meter segments.
struct ClickTempo { double beat, frame, framesPerBeat; };
struct ClickMeter { double beat, step; int32_t num; }; // step: quarter notes per click

// One track's progress through a block in renderBlock. Tracks advance until they wait on an isolated plug-in, so the
// isolated plug-ins of a callback run at the same time; tracks deliver to buses and the master in order.
struct TrackStep {
    uint8_t stage = 0;
    bool any = false, waiting = false, linkedSolo = false;
    int32_t insert = 0; // next insert to run
    float gl = 0, gr = 0;
    const RenderSlot *slot = nullptr;
    PluginProcessor *pending = nullptr; // the isolated plug-in whose block is in flight
};

struct RenderState {
    std::vector<RenderTrack> tracks;
    std::vector<ClickTempo> clickTempo;
    // Bus inputs, kMaxBlock frames per bus. Written only by the thread rendering this snapshot (the audio
    // thread for the live snapshot, the exporting thread for an offline one).
    mutable std::vector<float> busL, busR;
    mutable std::vector<float> scL, scR; // sidechain source signals, kMaxBlock frames each
    // Each track's signal through its chain during a block (kMaxBlock frames per track), and its progress.
    mutable std::vector<float> chainL, chainR;
    mutable std::vector<TrackStep> steps;
    // Plug-in delay compensation: every path to the master is delayed to this many frames, so the
    // timeline is rendered this far ahead of the playhead (and exports pre-roll by it).
    int32_t compensation = 0;
    std::shared_ptr<TrackRuntime> master; // master fader (gain atomic; live smoothing state)
    std::vector<std::shared_ptr<DelayLine>> delayKeep; // keeps the delay lines alive with the snapshot
    std::vector<ClickMeter> clickMeter;
    SynthParams synth;
    int32_t liveTrack = -1; // index of the track that plays live MIDI input (-1 = none)
};

// First metronome click at or after `pos` (INT64_MAX if none); `accent` marks a bar start.
// Plain arithmetic only: this runs on the audio thread.
inline double clickFrameToBeat(const std::vector<ClickTempo> &t, double f) DALNOK_NONBLOCKING {
    size_t i = 0;
    while (i + 1 < t.size() && t[i + 1].frame <= f) ++i;
    return t[i].beat + (f - t[i].frame) / t[i].framesPerBeat;
}
inline double clickBeatToFrame(const std::vector<ClickTempo> &t, double b) DALNOK_NONBLOCKING {
    size_t i = 0;
    while (i + 1 < t.size() && t[i + 1].beat <= b) ++i;
    return t[i].frame + (b - t[i].beat) * t[i].framesPerBeat;
}
inline int64_t nextClick(const RenderState &s, int64_t pos, bool &accent) DALNOK_NONBLOCKING {
    accent = false;
    if (s.clickTempo.empty() || s.clickMeter.empty()) return INT64_MAX;
    const auto &meter = s.clickMeter;
    double q = clickFrameToBeat(s.clickTempo, static_cast<double>(pos) - 0.5);
    for (int guard = 0; guard < 4; ++guard) {
        size_t mi = 0;
        while (mi + 1 < meter.size() && meter[mi + 1].beat <= q + 1e-9) ++mi;
        const double rel = (q - meter[mi].beat) / meter[mi].step;
        int64_t j = rel <= 0 ? 0 : static_cast<int64_t>(rel);
        if (static_cast<double>(j) < rel - 1e-9) ++j;
        double qc = meter[mi].beat + static_cast<double>(j) * meter[mi].step;
        int64_t num = meter[mi].num;
        if (mi + 1 < meter.size() && qc >= meter[mi + 1].beat - 1e-9) { qc = meter[mi + 1].beat; j = 0; num = meter[mi + 1].num; }
        const double exact = clickBeatToFrame(s.clickTempo, qc);
        const int64_t f = exact < 0 ? -1 : static_cast<int64_t>(exact + 0.5);
        if (f >= pos) { accent = j % num == 0; return f; }
        q = qc + 1e-6;
    }
    return INT64_MAX;
}

constexpr int kMaxBlock = 512; // internal processing chunk (frames)

struct Scratch {
    float trackL[kMaxBlock];
    float trackR[kMaxBlock];
    float tmp[kMaxBlock];
    float fadeL[kMaxBlock], fadeR[kMaxBlock]; // a track after its fader and pan
    // Stem export: when set, each track's post-fader signal (what goes to its output) is copied to
    // stemL/R + track index * kMaxBlock every block (silent tracks give silence). Offline only.
    float *stemL = nullptr, *stemR = nullptr;
    size_t stemTracks = 0;
    float edgeL[kMaxBlock], edgeR[kMaxBlock]; // one connection's signal while it is delayed
    PluginNote events[512];
    // Live-input notes for the live track's plugin instrument in this block (set by the live path).
    const PluginNote *liveNotes = nullptr;
    int liveNoteCount = 0;
    // The track playing live input in this callback: the armed instrument track, or the one being auditioned from the
    // piano roll (Engine::previewNote). -1 = none (offline renders).
    int32_t liveTrack = -1;
    // Live callbacks: when every isolated plug-in in this callback must have answered (one shared budget; 0 = none,
    // as for offline renders). Set once per callback by Engine::process.
    uint64_t deadlineNs = 0;
    // Time this callback spent waiting on isolated hosts (ns), so the engine can tell its own work from theirs.
    uint64_t isolatedWaitNs = 0;
    // Live audio input for this sub-block (live callbacks with an input device open; null otherwise): one mono buffer
    // per device input channel, already offset to the sub-block. Monitored tracks add their channel to their source.
    const float *liveInputs[64] = {};
    int liveInputCount = 0;
    bool monitorArmed = false; // armed audio tracks monitor too (Settings: hear armed tracks)
    // Transport stopped with input monitored: renderBlock plays no timeline content and runs only monitored tracks
    // and buses (other tracks stay silent and get their idle call instead).
    bool timelineOff = false;
};

// Whether track `t` adds its device input in this block.
inline bool monitorsInput(const RenderTrack &t, const Scratch &s) DALNOK_NONBLOCKING {
    return t.inputChannel >= 0 && t.inputChannel < s.liveInputCount && s.liveInputs[t.inputChannel] &&
           (t.inputMonitor || (t.armed && s.monitorArmed));
}

// Mixes `frames` (<= kMaxBlock) of `state` at timeline position `pos` into
// left/right (overwritten). If `smooth`, gain changes ramp across the block
// using each TrackRuntime's audio-thread state (live playback only).
// `synths` (offline renders) holds one SynthState per track; nullptr uses the live
// playback voices in each TrackRuntime.
void renderBlock(const RenderState &state, int64_t pos, int frames, float *left, float *right,
                 Scratch &scratch, bool smooth, bool anySolo, SynthState *synths = nullptr) DALNOK_NONBLOCKING;
// While the transport is stopped: gives every plug-in its idle call (parameter flushes), within the callback's budget.
void idlePlugins(const RenderState &state, Scratch &scratch) DALNOK_NONBLOCKING;

} // namespace dalnok
