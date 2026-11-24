// Dalnok Delay, Reverb and Gate: the stock time-based and gating effects every DAW ships (Logic's Stereo Delay,
// ChromaVerb and Noise Gate; Ableton's Delay, Reverb and Gate cover the same ground). Dalnok's own designs: a
// stereo/ping-pong delay with filtered feedback, an 8-line feedback delay network reverb, and a hysteresis gate with
// hold and an external key input. All memory is allocated in the constructors; `process` never allocates.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "fx/builtin.hpp"

#include <array>
#include <atomic>
#include <vector>

namespace dalnok::fx {

class Delay final : public BuiltinProcessor {
public:
    explicit Delay(double sampleRate);
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    enum : uint32_t { kTimeL = 0, kTimeR, kFeedback, kPingPong, kLowCut, kHighCut, kMix };

private:
    void changed() DALNOK_NONBLOCKING override;
    double sampleRate_;
    std::vector<float> line_[2];
    int64_t write_ = 0;
    double target_[2] = {0, 0}, time_[2] = {0, 0}; // delay in frames: target and smoothed (no zipper on changes)
    double smooth_ = 0, feedback_ = 0, mix_ = 0, lpCoef_ = 0, hpCoef_ = 0;
    bool pingPong_ = false, started_ = false;
    double lp_[2] = {0, 0}, hp_[2] = {0, 0}, hpIn_[2] = {0, 0};
};

class Reverb final : public BuiltinProcessor {
public:
    explicit Reverb(double sampleRate);
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    enum : uint32_t { kPredelay = 0, kDecay, kSize, kDamping, kLowCut, kWidth, kMix };
    static constexpr int kLines = 8;

private:
    void changed() DALNOK_NONBLOCKING override;
    double sampleRate_;
    std::array<std::vector<float>, kLines> lines_;
    std::array<int64_t, kLines> pos_{}, len_{};
    std::array<double, kLines> gain_{}, damp_{};
    std::vector<float> pre_;
    int64_t prePos_ = 0, preLen_ = 1;
    double dampCoef_ = 0, hpCoef_ = 0, hpState_ = 0, hpIn_ = 0, width_ = 1, mix_ = 0;
};

class Gate final : public BuiltinProcessor {
public:
    explicit Gate(double sampleRate);
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    bool hasSidechain() const override { return true; }
    enum : uint32_t { kThreshold = 0, kRange, kAttack, kHold, kRelease, kHysteresis, kReduction };

private:
    void changed() DALNOK_NONBLOCKING override;
    double meter(uint32_t id) const override;
    double sampleRate_;
    double open_ = 0, close_ = 0, floor_ = 0, attackCoef_ = 0, releaseCoef_ = 0;
    int64_t holdFrames_ = 0, holdLeft_ = 0;
    bool isOpen_ = false;
    double gain_ = 0;
    std::atomic<float> reductionDb_{0};
};

} // namespace dalnok::fx
