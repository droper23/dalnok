// Dalnok Compressor: a feed-forward stereo-linked compressor with an external sidechain (key) input.
// Its controls cover the set Logic's Compressor exposes (threshold, ratio, knee, attack, release, makeup, auto gain,
// peak/RMS detection, a sidechain filter, mix); its sound is Dalnok's own design and has not yet been measured
// against Logic (04 - Research/Logic Effect Parity.md, Compressor). Parameter ids are Dalnok's own, not Logic slots.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "fx/builtin.hpp"

#include <atomic>

namespace dalnok::fx {

// Static gain computer: gain change in dB (<= 0) for a detector level `x` dB (soft knee of `knee` dB, quadratic).
double compressorCurve(double x, double threshold, double ratio, double knee) DALNOK_NONBLOCKING;

class Compressor final : public BuiltinProcessor {
public:
    explicit Compressor(double sampleRate);
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    bool hasSidechain() const override { return true; }

    enum : uint32_t {
        kThreshold = 0, kRatio, kKnee, kAttack, kRelease, kMakeup, kAutoGain, kDetection,
        kKeyFilter, kKeyFilterFreq, kKeyListen, kMix, kGainReduction,
    };

private:
    void changed() DALNOK_NONBLOCKING override;
    double meter(uint32_t id) const override;

    double sampleRate_;
    // Derived from the parameters on the audio thread.
    double threshold_ = 0, ratio_ = 1, knee_ = 0, attackCoef_ = 0, releaseCoef_ = 0, makeupDb_ = 0, mix_ = 1;
    double rmsCoef_ = 0;
    bool rms_ = false, filter_ = false, listen_ = false;
    double hb0_ = 1, hb1_ = 0, hb2_ = 0, ha1_ = 0, ha2_ = 0; // key high-pass (RBJ, Q = 1/sqrt 2)
    // Running state.
    double gainDb_ = 0, meanSquare_ = 0;
    struct Hp { double x1 = 0, x2 = 0, y1 = 0, y2 = 0; } hp_[2];
    std::atomic<float> reductionDb_{0}; // the block's deepest gain reduction (positive dB), for the meter
};

} // namespace dalnok::fx
