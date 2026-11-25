// Monophonic guitar correction. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "fx/builtin.hpp"
#include <array>
#include <atomic>

namespace dalnok::fx {
class GuitarTune final : public BuiltinProcessor {
public:
    explicit GuitarTune(double sampleRate);
    uint32_t latency() const override { return latency_; }
    void process(float *, float *, int, const PluginNote *, int) DALNOK_NONBLOCKING override;
private:
    void changed() DALNOK_NONBLOCKING override;
    void startDetect() DALNOK_NONBLOCKING;   // at each hop: freezes the window and checks its level
    void detectSome() DALNOK_NONBLOCKING;    // each analysis sample: a few lags of the difference function
    void finishDetect() DALNOK_NONBLOCKING;  // all lags done: pitch, error and the correction target
    double read(int channel, double delay) const DALNOK_NONBLOCKING;
    double meter(uint32_t id) const override;
    double rate_, analysisRate_, span_, smoothing_ = 0, ratio_ = 1, target_ = 1, phase_ = .5;
    double steady_ = 1, steadyStep_;  // 1: no shift under way, the heads are bypassed by one exact tap
    int anchor_ = 0, lag_ = 0, maxLag_ = 0; // the analysis in progress (lag_ 0: none)
    double sum_ = 0;
    double filter_[2]{}, filterCoef_, mix_ = 1;
    int decimation_, decimated_ = 0, count_ = 0, hop_ = 0, write_ = 0;
    uint32_t latency_;
    std::array<float, 2048> history_{};
    std::array<double, 512> difference_{}, normalized_{};
    std::vector<float> delay_[2];
    std::atomic<float> pitch_{0}, cents_{0}, confidence_{0};
};
}
