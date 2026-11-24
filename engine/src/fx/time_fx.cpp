// Dalnok Delay, Reverb and Gate (see time_fx.hpp).
//
// Delay:  per channel a 2 s line read with linear interpolation; the delay time glides to a new value over ~50 ms.
//         Feedback passes a one-pole low cut and high cut. Ping-pong feeds the mono input to the left line and
//         crosses the feedback (left -> right -> left). Mix crossfades dry and wet (100 % = wet only).
// Reverb: input (mono sum, low-cut) -> predelay -> 8 delay lines (29.7 to 73.1 ms, scaled by Size from 0.4x to
//         1.6x) mixed by a Householder matrix. Each line has a one-pole damping low-pass and a gain that makes it
//         fall 60 dB in Decay seconds (g = 10^(-3 len / (T60 rate))). Even lines feed the left output, odd lines
//         the right; Width blends toward mono. Mix crossfades dry and wet.
// Gate:   key = the sidechain when connected, else the input. The gate opens when the key's peak reaches Threshold,
//         stays open for Hold after it falls below Threshold - Hysteresis, then closes to Range (dB). Gain glides
//         with Attack (opening) and Release (closing) one-poles.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/time_fx.hpp"

#include <algorithm>
#include <cmath>

// Coefficients use libm (exp, pow, cos), which neither allocates nor locks.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"

namespace dalnok::fx {
namespace {
constexpr double kPi = 3.14159265358979323846;
const char *const kOnOff[] = {"Off", "On"};
using P = BuiltinProcessor::Param;

// One-pole low-pass coefficient for a cutoff (y += c (x - y)).
double onePole(double hz, double rate) { return 1.0 - std::exp(-2 * kPi * std::min(hz, rate * 0.49) / rate); }

const std::vector<P> &delayParams() {
    static const std::vector<P> params = {
        {Delay::kTimeL, "Left Time", "ms", 1, 2000, 375, P::Log},
        {Delay::kTimeR, "Right Time", "ms", 1, 2000, 500, P::Log},
        {Delay::kFeedback, "Feedback", "%", 0, 95, 35, P::Linear},
        {Delay::kPingPong, "Ping Pong", "", 0, 1, 0, P::Toggle, kOnOff},
        {Delay::kLowCut, "Low Cut", "Hz", 20, 2000, 20, P::Log},
        {Delay::kHighCut, "High Cut", "Hz", 500, 20000, 12000, P::Log},
        {Delay::kMix, "Mix", "%", 0, 100, 30, P::Linear},
    };
    return params;
}

const std::vector<P> &reverbParams() {
    static const std::vector<P> params = {
        {Reverb::kPredelay, "Predelay", "ms", 0, 200, 10, P::Linear},
        {Reverb::kDecay, "Decay", "s", 0.1, 20, 2, P::Log},
        {Reverb::kSize, "Size", "%", 0, 100, 60, P::Linear},
        {Reverb::kDamping, "High Cut", "Hz", 1000, 20000, 8000, P::Log},
        {Reverb::kLowCut, "Low Cut", "Hz", 20, 1000, 100, P::Log},
        {Reverb::kWidth, "Width", "%", 0, 100, 100, P::Linear},
        {Reverb::kMix, "Mix", "%", 0, 100, 25, P::Linear},
    };
    return params;
}

const std::vector<P> &gateParams() {
    static const std::vector<P> params = {
        {Gate::kThreshold, "Threshold", "dB", -80, 0, -40, P::Linear},
        {Gate::kRange, "Range", "dB", -100, 0, -100, P::Linear},
        {Gate::kAttack, "Attack", "ms", 0.01, 100, 0.5, P::Log},
        {Gate::kHold, "Hold", "ms", 0, 500, 20, P::Linear},
        {Gate::kRelease, "Release", "ms", 1, 2000, 100, P::Log},
        {Gate::kHysteresis, "Hysteresis", "dB", 0, 12, 3, P::Linear},
        {Gate::kReduction, "Gain Reduction", "dB", 0, 100, 0, P::Linear, nullptr, true},
    };
    return params;
}

constexpr double kReverbMs[Reverb::kLines] = {29.7, 37.1, 41.1, 43.7, 53.3, 59.9, 67.7, 73.1};
} // namespace

// ---- Delay ------------------------------------------------------------------------------------------------------

Delay::Delay(double sampleRate) : BuiltinProcessor("delay", "Dalnok Delay", delayParams()), sampleRate_(sampleRate) {
    const auto n = static_cast<size_t>(std::ceil(sampleRate * 2.0)) + 4;
    line_[0].assign(n, 0.0f);
    line_[1].assign(n, 0.0f);
    smooth_ = 1.0 - std::exp(-1.0 / (0.05 * sampleRate));
}

void Delay::changed() DALNOK_NONBLOCKING {
    const double maxFrames = static_cast<double>(line_[0].size()) - 2;
    target_[0] = std::clamp(rt(kTimeL) * 1e-3 * sampleRate_, 1.0, maxFrames);
    target_[1] = std::clamp(rt(kTimeR) * 1e-3 * sampleRate_, 1.0, maxFrames);
    if (!started_) { time_[0] = target_[0]; time_[1] = target_[1]; started_ = true; }
    feedback_ = std::clamp(rt(kFeedback) / 100.0, 0.0, 0.95);
    pingPong_ = rt(kPingPong) >= 0.5;
    lpCoef_ = onePole(rt(kHighCut), sampleRate_);
    hpCoef_ = onePole(rt(kLowCut), sampleRate_);
    mix_ = std::clamp(rt(kMix) / 100.0, 0.0, 1.0);
}

void Delay::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    const auto size = static_cast<int64_t>(line_[0].size());
    auto read = [&](int ch, double d) {
        double pos = static_cast<double>(write_) - d;
        while (pos < 0) pos += static_cast<double>(size);
        const auto i0 = static_cast<int64_t>(pos);
        const double frac = pos - static_cast<double>(i0);
        const float a = line_[ch][static_cast<size_t>(i0 % size)], b = line_[ch][static_cast<size_t>((i0 + 1) % size)];
        return a + frac * (b - a);
    };
    for (int i = 0; i < frames; ++i) {
        for (int ch = 0; ch < 2; ++ch) time_[ch] += smooth_ * (target_[ch] - time_[ch]);
        const double wet[2] = {read(0, time_[0]), read(1, time_[1])};
        double fb[2];
        for (int ch = 0; ch < 2; ++ch) { // feedback filters: high cut (low-pass) then low cut (input minus its low-pass)
            lp_[ch] += lpCoef_ * (wet[ch] - lp_[ch]);
            hpIn_[ch] += hpCoef_ * (lp_[ch] - hpIn_[ch]);
            fb[ch] = (lp_[ch] - hpIn_[ch]) * feedback_;
        }
        const double dl = left[i], dr = right[i];
        float inL, inR;
        if (pingPong_) {
            inL = static_cast<float>(0.5 * (dl + dr) + fb[1]);
            inR = static_cast<float>(fb[0]);
        } else {
            inL = static_cast<float>(dl + fb[0]);
            inR = static_cast<float>(dr + fb[1]);
        }
        line_[0][static_cast<size_t>(write_)] = inL;
        line_[1][static_cast<size_t>(write_)] = inR;
        write_ = (write_ + 1) % size;
        left[i] = static_cast<float>(dl + mix_ * (wet[0] - dl));
        right[i] = static_cast<float>(dr + mix_ * (wet[1] - dr));
    }
}

// ---- Reverb -----------------------------------------------------------------------------------------------------

Reverb::Reverb(double sampleRate) : BuiltinProcessor("reverb", "Dalnok Reverb", reverbParams()), sampleRate_(sampleRate) {
    for (int k = 0; k < kLines; ++k)
        lines_[static_cast<size_t>(k)].assign(static_cast<size_t>(std::ceil(kReverbMs[k] * 1.6e-3 * sampleRate)) + 2, 0.0f);
    pre_.assign(static_cast<size_t>(std::ceil(0.2 * sampleRate)) + 2, 0.0f);
}

void Reverb::changed() DALNOK_NONBLOCKING {
    const double scale = 0.4 + 1.2 * std::clamp(rt(kSize) / 100.0, 0.0, 1.0);
    const double t60 = std::max(0.1, rt(kDecay));
    for (size_t k = 0; k < kLines; ++k) {
        len_[k] = std::clamp<int64_t>(static_cast<int64_t>(std::lround(kReverbMs[k] * scale * 1e-3 * sampleRate_)), 1,
                                      static_cast<int64_t>(lines_[k].size()) - 1);
        pos_[k] %= len_[k];
        gain_[k] = std::pow(10.0, -3.0 * static_cast<double>(len_[k]) / (t60 * sampleRate_));
    }
    preLen_ = std::clamp<int64_t>(static_cast<int64_t>(std::lround(rt(kPredelay) * 1e-3 * sampleRate_)), 0,
                                  static_cast<int64_t>(pre_.size()) - 1) + 1;
    prePos_ %= preLen_;
    dampCoef_ = onePole(rt(kDamping), sampleRate_);
    hpCoef_ = onePole(rt(kLowCut), sampleRate_);
    width_ = std::clamp(rt(kWidth) / 100.0, 0.0, 1.0);
    mix_ = std::clamp(rt(kMix) / 100.0, 0.0, 1.0);
}

void Reverb::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    for (int i = 0; i < frames; ++i) {
        const double dl = left[i], dr = right[i];
        double in = 0.5 * (dl + dr);
        hpIn_ += hpCoef_ * (in - hpIn_);
        in -= hpIn_;
        // Predelay: a line of preLen_ frames (1 = none).
        const double delayed = preLen_ > 1 ? pre_[static_cast<size_t>(prePos_)] : in;
        pre_[static_cast<size_t>(prePos_)] = static_cast<float>(in);
        prePos_ = (prePos_ + 1) % preLen_;

        double out[kLines], sum = 0;
        for (size_t k = 0; k < kLines; ++k) {
            const double y = lines_[k][static_cast<size_t>(pos_[k])];
            damp_[k] += dampCoef_ * (y - damp_[k]);
            out[k] = damp_[k] * gain_[k];
            sum += out[k];
        }
        const double h = 2.0 / kLines * sum; // Householder: x - 2/N * sum(x), lossless
        double wl = 0, wr = 0;
        for (size_t k = 0; k < kLines; ++k) {
            const double sign = (k & 2) ? -1.0 : 1.0;
            lines_[k][static_cast<size_t>(pos_[k])] = static_cast<float>(out[k] - h + sign * delayed * 0.35);
            pos_[k] = (pos_[k] + 1) % len_[k];
            if (k & 1) wr += sign * out[k]; else wl += sign * out[k];
        }
        wl *= 0.5; wr *= 0.5;
        const double mid = 0.5 * (wl + wr), side = 0.5 * (wl - wr) * width_;
        wl = mid + side; wr = mid - side;
        left[i] = static_cast<float>(dl + mix_ * (wl - dl));
        right[i] = static_cast<float>(dr + mix_ * (wr - dr));
    }
}

// ---- Gate -------------------------------------------------------------------------------------------------------

Gate::Gate(double sampleRate) : BuiltinProcessor("gate", "Dalnok Gate", gateParams()), sampleRate_(sampleRate) {}

double Gate::meter(uint32_t id) const {
    return id == kReduction ? static_cast<double>(reductionDb_.load(std::memory_order_relaxed)) : 0.0;
}

void Gate::changed() DALNOK_NONBLOCKING {
    open_ = std::pow(10.0, rt(kThreshold) / 20.0);
    close_ = std::pow(10.0, (rt(kThreshold) - std::max(0.0, rt(kHysteresis))) / 20.0);
    floor_ = rt(kRange) <= -100 ? 0.0 : std::pow(10.0, rt(kRange) / 20.0);
    attackCoef_ = 1.0 - std::exp(-1.0 / (std::max(0.01, rt(kAttack)) * 1e-3 * sampleRate_));
    releaseCoef_ = 1.0 - std::exp(-1.0 / (std::max(1.0, rt(kRelease)) * 1e-3 * sampleRate_));
    holdFrames_ = static_cast<int64_t>(std::max(0.0, rt(kHold)) * 1e-3 * sampleRate_);
}

void Gate::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    const float *keyL = scL_ ? scL_ : left, *keyR = scL_ ? (scR_ ? scR_ : scL_) : right;
    double lowest = 1;
    for (int i = 0; i < frames; ++i) {
        const double level = std::max(std::fabs(keyL[i]), std::fabs(keyR[i]));
        if (level >= open_) { isOpen_ = true; holdLeft_ = holdFrames_; }
        else if (isOpen_ && level < close_) {
            if (holdLeft_ > 0) --holdLeft_;
            else isOpen_ = false;
        }
        const double target = isOpen_ ? 1.0 : floor_;
        gain_ += (target > gain_ ? attackCoef_ : releaseCoef_) * (target - gain_);
        lowest = std::min(lowest, gain_);
        left[i] = static_cast<float>(left[i] * gain_);
        right[i] = static_cast<float>(right[i] * gain_);
    }
    reductionDb_.store(static_cast<float>(std::min(100.0, -20 * std::log10(std::max(lowest, 1e-5)))), std::memory_order_relaxed);
}

} // namespace dalnok::fx

#pragma clang diagnostic pop
