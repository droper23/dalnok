// Dalnok Limiter, Saturator, Filter, Chorus and Utility: the stock mixing tools both Logic (Adaptive Limiter,
// ChromaGlow / Overdrive, AutoFilter, Chorus, Gain / Direction Mixer) and Ableton (Limiter, Saturator, Auto Filter,
// Chorus-Ensemble, Utility) ship. Dalnok's own designs; all memory is allocated in the constructors.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "fx/builtin.hpp"

#include <atomic>
#include <vector>

namespace dalnok::fx {

// A look-ahead brickwall limiter: the output never passes the ceiling. The audio is delayed 5 ms (reported as
// latency, so delay compensation lines it up); the gain is the lowest any sample in the look-ahead window needs,
// and recovers with the release time.
class Limiter final : public BuiltinProcessor {
public:
    explicit Limiter(double sampleRate);
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    uint32_t latency() const override { return static_cast<uint32_t>(look_); }
    enum : uint32_t { kGain = 0, kCeiling, kRelease, kReduction };

private:
    void changed() DALNOK_NONBLOCKING override;
    double meter(uint32_t id) const override;
    double sampleRate_;
    int look_;
    std::vector<float> delayL_, delayR_, need_; // the look-ahead: delayed audio and each sample's needed gain
    std::vector<int> minQ_;                      // monotonic queue of indices into need_ (the window's minimum)
    int qHead_ = 0, qTail_ = 0, pos_ = 0;
    double drive_ = 1, ceiling_ = 1, releaseCoef_ = 0, env_ = 1;
    std::atomic<float> reductionDb_{0};
};

class Saturator final : public BuiltinProcessor {
public:
    explicit Saturator(double sampleRate);
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    enum : uint32_t { kDrive = 0, kType, kTone, kOutput, kMix };

private:
    void changed() DALNOK_NONBLOCKING override;
    double sampleRate_;
    double drive_ = 1, out_ = 1, mix_ = 1, toneCoef_ = 1;
    int type_ = 0;
    double lp_[2] = {0, 0};
};

// A state-variable filter (topology-preserving transform): low-pass, high-pass, band-pass or notch, 12 dB/octave,
// with resonance. Cutoff glides (5 ms) so sweeps and automation don't step.
class Filter final : public BuiltinProcessor {
public:
    explicit Filter(double sampleRate);
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    enum : uint32_t { kType = 0, kCutoff, kResonance, kMix };

private:
    void changed() DALNOK_NONBLOCKING override;
    double sampleRate_;
    double target_ = 1000, cutoff_ = -1, smooth_ = 0, k_ = 1.414, mix_ = 1;
    int type_ = 0;
    double ic1_[2] = {0, 0}, ic2_[2] = {0, 0};
};

class Chorus final : public BuiltinProcessor {
public:
    explicit Chorus(double sampleRate);
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    enum : uint32_t { kRate = 0, kDepth, kDelay, kMix };

private:
    void changed() DALNOK_NONBLOCKING override;
    double sampleRate_;
    std::vector<float> line_[2];
    int64_t write_ = 0;
    double phase_ = 0, inc_ = 0, depth_ = 0, delay_ = 0, mix_ = 0;
};

class Utility final : public BuiltinProcessor {
public:
    explicit Utility(double sampleRate);
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    enum : uint32_t { kGain = 0, kWidth, kMono, kInvertL, kInvertR, kBalance };

private:
    void changed() DALNOK_NONBLOCKING override;
    double gain_ = 1, width_ = 1, gl_ = 1, gr_ = 1;
    bool mono_ = false;
};

} // namespace dalnok::fx
