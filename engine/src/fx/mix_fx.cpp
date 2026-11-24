// Dalnok Limiter, Saturator, Filter, Chorus and Utility (see mix_fx.hpp).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/mix_fx.hpp"

#include <algorithm>
#include <cmath>

// Coefficients use libm (exp, pow, tan, tanh, sin), which neither allocates nor locks.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"

namespace dalnok::fx {
namespace {
constexpr double kPi = 3.14159265358979323846;
using P = BuiltinProcessor::Param;
const char *const kOnOff[] = {"Off", "On"};
const char *const kSatTypes[] = {"Soft", "Hard", "Tube"};
const char *const kFilterTypes[] = {"Low-pass", "High-pass", "Band-pass", "Notch"};
double db(double v) { return std::pow(10.0, v / 20); }

const std::vector<P> &limiterParams() {
    static const std::vector<P> params = {
        {Limiter::kGain, "Gain", "dB", 0, 24, 0, P::Linear},
        {Limiter::kCeiling, "Ceiling", "dB", -12, 0, -0.3, P::Linear},
        {Limiter::kRelease, "Release", "ms", 10, 1000, 100, P::Log},
        {Limiter::kReduction, "Gain Reduction", "dB", 0, 40, 0, P::Linear, nullptr, true},
    };
    return params;
}
const std::vector<P> &saturatorParams() {
    static const std::vector<P> params = {
        {Saturator::kDrive, "Drive", "dB", 0, 36, 6, P::Linear},
        {Saturator::kType, "Type", "", 0, 2, 0, P::Choice, kSatTypes},
        {Saturator::kTone, "Tone", "Hz", 1000, 20000, 20000, P::Log},
        {Saturator::kOutput, "Output", "dB", -36, 12, 0, P::Linear},
        {Saturator::kMix, "Mix", "%", 0, 100, 100, P::Linear},
    };
    return params;
}
const std::vector<P> &filterParams() {
    static const std::vector<P> params = {
        {Filter::kType, "Type", "", 0, 3, 0, P::Choice, kFilterTypes},
        {Filter::kCutoff, "Cutoff", "Hz", 20, 20000, 1000, P::Log},
        {Filter::kResonance, "Resonance", "", 0.5, 20, 0.707, P::Log},
        {Filter::kMix, "Mix", "%", 0, 100, 100, P::Linear},
    };
    return params;
}
const std::vector<P> &chorusParams() {
    static const std::vector<P> params = {
        {Chorus::kRate, "Rate", "Hz", 0.05, 5, 0.6, P::Log},
        {Chorus::kDepth, "Depth", "ms", 0, 10, 3, P::Linear},
        {Chorus::kDelay, "Delay", "ms", 1, 30, 12, P::Linear},
        {Chorus::kMix, "Mix", "%", 0, 100, 50, P::Linear},
    };
    return params;
}
const std::vector<P> &utilityParams() {
    static const std::vector<P> params = {
        {Utility::kGain, "Gain", "dB", -60, 24, 0, P::Linear},
        {Utility::kWidth, "Width", "%", 0, 200, 100, P::Linear},
        {Utility::kMono, "Mono", "", 0, 1, 0, P::Toggle, kOnOff},
        {Utility::kInvertL, "Invert Left", "", 0, 1, 0, P::Toggle, kOnOff},
        {Utility::kInvertR, "Invert Right", "", 0, 1, 0, P::Toggle, kOnOff},
        {Utility::kBalance, "Balance", "", -1, 1, 0, P::Linear},
    };
    return params;
}
} // namespace

// ---- Limiter ----------------------------------------------------------------------------------------------------

Limiter::Limiter(double sampleRate)
    : BuiltinProcessor("limiter", "Dalnok Limiter", limiterParams()), sampleRate_(sampleRate),
      look_(std::max(1, static_cast<int>(std::lround(sampleRate * 0.005)))) {
    const auto n = static_cast<size_t>(look_ + 1);
    delayL_.assign(n, 0.0f);
    delayR_.assign(n, 0.0f);
    need_.assign(n, 1.0f);
    minQ_.assign(n + 1, 0);
}

double Limiter::meter(uint32_t id) const { return id == kReduction ? reductionDb_.load(std::memory_order_relaxed) : 0.0; }

void Limiter::changed() DALNOK_NONBLOCKING {
    drive_ = db(rt(kGain));
    ceiling_ = db(std::min(0.0, rt(kCeiling)));
    releaseCoef_ = 1.0 - std::exp(-1.0 / (std::max(10.0, rt(kRelease)) * 1e-3 * sampleRate_));
}

void Limiter::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    // need_ is a ring of the last n = look + 1 samples' needed gains (this one and the look-ahead behind it); minQ_ is
    // a monotonic queue of ring indices whose front is the window's lowest need (capacity n + 1: full != empty).
    const int n = look_ + 1, q = n + 1;
    double deepest = 1;
    for (int i = 0; i < frames; ++i) {
        const double l = left[i] * drive_, r = right[i] * drive_;
        const double peak = std::max(std::fabs(l), std::fabs(r));
        const float need = static_cast<float>(peak > ceiling_ ? ceiling_ / peak : 1.0);
        // The sample at pos_ (n samples old) leaves the window as this one takes its place.
        if (qHead_ != qTail_ && minQ_[static_cast<size_t>(qHead_)] == pos_) qHead_ = (qHead_ + 1) % q;
        while (qTail_ != qHead_ && need_[static_cast<size_t>(minQ_[static_cast<size_t>((qTail_ + q - 1) % q)])] >= need)
            qTail_ = (qTail_ + q - 1) % q;
        need_[static_cast<size_t>(pos_)] = need;
        minQ_[static_cast<size_t>(qTail_)] = pos_;
        qTail_ = (qTail_ + 1) % q;
        const double windowMin = need_[static_cast<size_t>(minQ_[static_cast<size_t>(qHead_)])];
        // Recover toward 1 with the release, never above what the window needs: every sample stays under the ceiling.
        env_ = std::min(windowMin, env_ + (1.0 - env_) * releaseCoef_);
        delayL_[static_cast<size_t>(pos_)] = static_cast<float>(l);
        delayR_[static_cast<size_t>(pos_)] = static_cast<float>(r);
        const int oldest = (pos_ + 1) % n; // written `look` samples ago: what plays now
        left[i] = static_cast<float>(delayL_[static_cast<size_t>(oldest)] * env_);
        right[i] = static_cast<float>(delayR_[static_cast<size_t>(oldest)] * env_);
        deepest = std::min(deepest, env_);
        pos_ = (pos_ + 1) % n;
    }
    reductionDb_.store(static_cast<float>(-20 * std::log10(std::max(deepest, 1e-5))), std::memory_order_relaxed);
}

// ---- Saturator --------------------------------------------------------------------------------------------------

Saturator::Saturator(double sampleRate) : BuiltinProcessor("saturator", "Dalnok Saturator", saturatorParams()), sampleRate_(sampleRate) {}

void Saturator::changed() DALNOK_NONBLOCKING {
    drive_ = db(rt(kDrive));
    type_ = static_cast<int>(std::lround(rt(kType)));
    out_ = db(rt(kOutput));
    mix_ = std::clamp(rt(kMix) / 100.0, 0.0, 1.0);
    toneCoef_ = 1.0 - std::exp(-2 * kPi * std::min(rt(kTone), sampleRate_ * 0.49) / sampleRate_);
}

void Saturator::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    float *ch[2] = {left, right};
    for (int c = 0; c < 2; ++c)
        for (int i = 0; i < frames; ++i) {
            const double x = ch[c][i], d = x * drive_;
            double y;
            switch (type_) {
            case 1: y = std::clamp(d, -1.0, 1.0); break;                                  // hard clip
            case 2: y = d >= 0 ? std::tanh(d) : std::tanh(d * 0.7) / 0.7 * 0.9; break;  // tube: asymmetric (even harmonics)
            default: y = std::tanh(d); break;                                              // soft
            }
            lp_[c] += toneCoef_ * (y - lp_[c]);
            ch[c][i] = static_cast<float>(x + mix_ * (lp_[c] * out_ - x));
        }
}

// ---- Filter -----------------------------------------------------------------------------------------------------

Filter::Filter(double sampleRate) : BuiltinProcessor("filter", "Dalnok Filter", filterParams()), sampleRate_(sampleRate),
      smooth_(1.0 - std::exp(-1.0 / (0.005 * sampleRate))) {}

void Filter::changed() DALNOK_NONBLOCKING {
    type_ = static_cast<int>(std::lround(rt(kType)));
    target_ = std::clamp(rt(kCutoff), 20.0, sampleRate_ * 0.45);
    if (cutoff_ < 0) cutoff_ = target_;
    k_ = 1.0 / std::max(0.5, rt(kResonance));
    mix_ = std::clamp(rt(kMix) / 100.0, 0.0, 1.0);
}

void Filter::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    for (int i = 0; i < frames; ++i) {
        cutoff_ += smooth_ * (target_ - cutoff_);
        const double g = std::tan(kPi * cutoff_ / sampleRate_);
        const double a1 = 1 / (1 + g * (g + k_)), a2 = g * a1, a3 = g * a2;
        float *ch[2] = {left, right};
        for (int c = 0; c < 2; ++c) {
            const double v0 = ch[c][i];
            const double v3 = v0 - ic2_[c];
            const double v1 = a1 * ic1_[c] + a2 * v3, v2 = ic2_[c] + a2 * ic1_[c] + a3 * v3;
            ic1_[c] = 2 * v1 - ic1_[c];
            ic2_[c] = 2 * v2 - ic2_[c];
            double y;
            switch (type_) {
            case 1: y = v0 - k_ * v1 - v2; break; // high-pass
            case 2: y = v1 * k_; break;           // band-pass (unity at the centre)
            case 3: y = v0 - k_ * v1; break;      // notch
            default: y = v2; break;               // low-pass
            }
            ch[c][i] = static_cast<float>(v0 + mix_ * (y - v0));
        }
    }
}

// ---- Chorus -----------------------------------------------------------------------------------------------------

Chorus::Chorus(double sampleRate) : BuiltinProcessor("chorus", "Dalnok Chorus", chorusParams()), sampleRate_(sampleRate) {
    const auto n = static_cast<size_t>(std::ceil(sampleRate * 0.05)) + 4; // 50 ms: delay + depth at most 40
    line_[0].assign(n, 0.0f);
    line_[1].assign(n, 0.0f);
}

void Chorus::changed() DALNOK_NONBLOCKING {
    inc_ = rt(kRate) / sampleRate_;
    depth_ = rt(kDepth) * 1e-3 * sampleRate_;
    delay_ = rt(kDelay) * 1e-3 * sampleRate_;
    mix_ = std::clamp(rt(kMix) / 100.0, 0.0, 1.0);
}

void Chorus::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    const auto size = static_cast<int64_t>(line_[0].size());
    float *ch[2] = {left, right};
    for (int i = 0; i < frames; ++i) {
        phase_ += inc_;
        if (phase_ >= 1) phase_ -= 1;
        for (int c = 0; c < 2; ++c) {
            // The two sides' delays move in opposite directions (a wide chorus).
            const double mod = std::sin(2 * kPi * (phase_ + (c ? 0.5 : 0.0)));
            const double d = std::clamp(delay_ + depth_ * mod, 1.0, static_cast<double>(size - 2));
            double pos = static_cast<double>(write_) - d;
            while (pos < 0) pos += static_cast<double>(size);
            const auto k = static_cast<int64_t>(pos);
            const double f = pos - static_cast<double>(k);
            const float a = line_[c][static_cast<size_t>(k % size)], b = line_[c][static_cast<size_t>((k + 1) % size)];
            const double wet = a + f * (b - a), dry = ch[c][i];
            line_[c][static_cast<size_t>(write_)] = ch[c][i];
            ch[c][i] = static_cast<float>(dry + mix_ * (0.5 * (dry + wet) - dry)); // 100 %: half dry, half wet
        }
        write_ = (write_ + 1) % size;
    }
}

// ---- Utility ----------------------------------------------------------------------------------------------------

Utility::Utility(double) : BuiltinProcessor("utility", "Dalnok Utility", utilityParams()) {}

void Utility::changed() DALNOK_NONBLOCKING {
    gain_ = rt(kGain) <= -60 ? 0.0 : db(rt(kGain));
    width_ = std::clamp(rt(kWidth) / 100.0, 0.0, 2.0);
    mono_ = rt(kMono) >= 0.5;
    const double b = std::clamp(rt(kBalance), -1.0, 1.0);
    gl_ = (rt(kInvertL) >= 0.5 ? -1.0 : 1.0) * (b > 0 ? 1 - b : 1.0);
    gr_ = (rt(kInvertR) >= 0.5 ? -1.0 : 1.0) * (b < 0 ? 1 + b : 1.0);
}

void Utility::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    const double w = mono_ ? 0.0 : width_;
    for (int i = 0; i < frames; ++i) {
        const double l = left[i] * gl_, r = right[i] * gr_;
        const double mid = 0.5 * (l + r), side = 0.5 * (l - r) * w;
        left[i] = static_cast<float>((mid + side) * gain_);
        right[i] = static_cast<float>((mid - side) * gain_);
    }
}

} // namespace dalnok::fx

#pragma clang diagnostic pop
