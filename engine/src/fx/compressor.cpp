// Dalnok Compressor (see compressor.hpp).
//
// Signal flow, per sample:
//   key     = the sidechain input when one is connected, otherwise the input itself; optionally high-passed
//   level   = peak (max |L|, |R|) or RMS (mean of L^2 and R^2 over a 10 ms one-pole window), in dB
//   target  = compressorCurve(level): hard or soft (quadratic) knee
//   gain    = target smoothed in dB with separate attack and release one-poles (coef = exp(-1 / (time * rate)))
//   output  = input * 10^((gain + makeup) / 20), blended with the dry input by Mix; Listen outputs the key instead
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/compressor.hpp"

#include <algorithm>
#include <cmath>

// Coefficients and the per-sample detector use libm (exp, log10, pow, sin, cos), which neither allocates nor locks.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"

namespace dalnok::fx {
namespace {
constexpr double kPi = 3.14159265358979323846;
const char *const kOnOff[] = {"Off", "On"};
const char *const kDetection[] = {"Peak", "RMS"};

const std::vector<BuiltinProcessor::Param> &compressorParams() {
    using P = BuiltinProcessor::Param;
    static const std::vector<P> params = {
        {Compressor::kThreshold, "Threshold", "dB", -60, 0, -20, P::Linear},
        {Compressor::kRatio, "Ratio", ":1", 1, 30, 4, P::Log},
        {Compressor::kKnee, "Knee", "dB", 0, 24, 6, P::Linear},
        {Compressor::kAttack, "Attack", "ms", 0.05, 200, 10, P::Log},
        {Compressor::kRelease, "Release", "ms", 5, 5000, 100, P::Log},
        {Compressor::kMakeup, "Make Up", "dB", -20, 40, 0, P::Linear},
        {Compressor::kAutoGain, "Auto Gain", "", 0, 1, 0, P::Toggle, kOnOff},
        {Compressor::kDetection, "Detection", "", 0, 1, 0, P::Choice, kDetection},
        {Compressor::kKeyFilter, "Side Chain Filter", "", 0, 1, 0, P::Toggle, kOnOff},
        {Compressor::kKeyFilterFreq, "Side Chain Filter Frequency", "Hz", 20, 2000, 100, P::Log},
        {Compressor::kKeyListen, "Side Chain Listen", "", 0, 1, 0, P::Toggle, kOnOff},
        {Compressor::kMix, "Mix", "%", 0, 100, 100, P::Linear},
        {Compressor::kGainReduction, "Gain Reduction", "dB", 0, 60, 0, P::Linear, nullptr, true},
    };
    return params;
}
} // namespace

double compressorCurve(double x, double threshold, double ratio, double knee) DALNOK_NONBLOCKING {
    const double over = x - threshold, slope = 1.0 / ratio - 1.0;
    if (knee > 0 && 2 * std::fabs(over) <= knee) {
        const double d = over + knee / 2;
        return slope * d * d / (2 * knee);
    }
    return over > 0 ? slope * over : 0.0;
}

Compressor::Compressor(double sampleRate)
    : BuiltinProcessor("compressor", "Dalnok Compressor", compressorParams()), sampleRate_(sampleRate) {
    rmsCoef_ = std::exp(-1.0 / (0.010 * sampleRate_));
}

double Compressor::meter(uint32_t id) const {
    return id == kGainReduction ? static_cast<double>(reductionDb_.load(std::memory_order_relaxed)) : 0.0;
}

void Compressor::changed() DALNOK_NONBLOCKING {
    threshold_ = rt(kThreshold);
    ratio_ = std::max(1.0, rt(kRatio));
    knee_ = std::max(0.0, rt(kKnee));
    attackCoef_ = std::exp(-1.0 / (rt(kAttack) * 1e-3 * sampleRate_));
    releaseCoef_ = std::exp(-1.0 / (rt(kRelease) * 1e-3 * sampleRate_));
    // Auto Gain restores a full-scale (0 dB) level: it adds back what the curve takes from 0 dB.
    makeupDb_ = rt(kMakeup) - (rt(kAutoGain) >= 0.5 ? compressorCurve(0, threshold_, ratio_, knee_) : 0.0);
    rms_ = rt(kDetection) >= 0.5;
    filter_ = rt(kKeyFilter) >= 0.5;
    listen_ = rt(kKeyListen) >= 0.5;
    mix_ = std::clamp(rt(kMix) / 100.0, 0.0, 1.0);
    const double w = 2 * kPi * std::min(rt(kKeyFilterFreq) / sampleRate_, 0.49), cw = std::cos(w);
    const double alpha = std::sin(w) / (2 * 0.70710678118654752), a0 = 1 + alpha;
    hb0_ = (1 + cw) / 2 / a0; hb1_ = -(1 + cw) / a0; hb2_ = hb0_;
    ha1_ = -2 * cw / a0; ha2_ = (1 - alpha) / a0;
}

void Compressor::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    const float *keyL = scL_ ? scL_ : left, *keyR = scL_ ? (scR_ ? scR_ : scL_) : right;
    double deepest = 0;
    for (int i = 0; i < frames; ++i) {
        double k[2] = {keyL[i], keyR[i]};
        if (filter_) {
            for (int ch = 0; ch < 2; ++ch) {
                Hp &h = hp_[ch];
                const double y = hb0_ * k[ch] + hb1_ * h.x1 + hb2_ * h.x2 - ha1_ * h.y1 - ha2_ * h.y2;
                h.x2 = h.x1; h.x1 = k[ch]; h.y2 = h.y1; h.y1 = y;
                k[ch] = y;
            }
        }
        double level;
        if (rms_) {
            meanSquare_ = rmsCoef_ * meanSquare_ + (1 - rmsCoef_) * 0.5 * (k[0] * k[0] + k[1] * k[1]);
            level = std::sqrt(meanSquare_);
        } else {
            level = std::max(std::fabs(k[0]), std::fabs(k[1]));
        }
        const double target = compressorCurve(20 * std::log10(std::max(level, 1e-10)), threshold_, ratio_, knee_);
        const double coef = target < gainDb_ ? attackCoef_ : releaseCoef_;
        gainDb_ = coef * gainDb_ + (1 - coef) * target;
        deepest = std::min(deepest, gainDb_);
        if (listen_) {
            left[i] = static_cast<float>(k[0]);
            right[i] = static_cast<float>(k[1]);
            continue;
        }
        const double g = std::pow(10.0, (gainDb_ + makeupDb_) / 20.0);
        const double dl = left[i], dr = right[i];
        left[i] = static_cast<float>(dl + mix_ * (dl * g - dl));
        right[i] = static_cast<float>(dr + mix_ * (dr * g - dr));
    }
    reductionDb_.store(static_cast<float>(-deepest), std::memory_order_relaxed);
}

} // namespace dalnok::fx

#pragma clang diagnostic pop
