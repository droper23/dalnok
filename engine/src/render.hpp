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
    float curL = 0, curR = 0;
    bool primed = false;
    // Instrument voices (audio thread): timeline playback and live MIDI input.
    SynthState play, live;
};

// Raises a meter atomic to `v` if larger. A concurrent reset may be overwritten
// by one stale value; harmless for metering.
inline void raisePeak(std::atomic<float> &a, float v) DALNOK_NONBLOCKING {
    if (v > a.load(std::memory_order_relaxed)) a.store(v, std::memory_order_relaxed);
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

// A note in timeline frames, already clipped to its clip's window.
struct RenderNote {
    int64_t start = 0, end = 0;
    uint8_t pitch = 0, velocity = 0;
};

struct RenderTrack {
    std::shared_ptr<TrackRuntime> runtime;
    std::vector<RenderClip> clips; // z-order: later clips overwrite earlier ones
    bool monoSource = true;        // every clip is mono -> constant-power pan law
    bool instrument = false;       // MIDI track playing the built-in synth
    std::vector<RenderNote> notes; // sorted by start
};

struct RenderState {
    std::vector<RenderTrack> tracks;
    SynthParams synth;
    int32_t liveTrack = -1; // index of the track that plays live MIDI input (-1 = none)
};

constexpr int kMaxBlock = 512; // internal processing chunk (frames)

struct Scratch {
    float trackL[kMaxBlock];
    float trackR[kMaxBlock];
};

// Mixes `frames` (<= kMaxBlock) of `state` at timeline position `pos` into
// left/right (overwritten). If `smooth`, gain changes ramp across the block
// using each TrackRuntime's audio-thread state (live playback only).
// `synths` (offline renders) holds one SynthState per track; nullptr uses the live
// playback voices in each TrackRuntime.
void renderBlock(const RenderState &state, int64_t pos, int frames, float *left, float *right,
                 Scratch &scratch, bool smooth, bool anySolo, SynthState *synths = nullptr) DALNOK_NONBLOCKING;
// Adds live-input instrument voices (independent of the transport) through the track's gain and pan.
void renderLiveInput(const RenderState &state, int frames, float *left, float *right, Scratch &scratch,
                     bool anySolo) DALNOK_NONBLOCKING;

} // namespace dalnok
