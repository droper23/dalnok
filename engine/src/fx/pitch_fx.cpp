// Dalnok Pitch Correct (see pitch_fx.hpp).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/pitch_fx.hpp"

#include <algorithm>
#include <cmath>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects" // libm and the shifter's process neither allocate nor lock

namespace dalnok::fx {
namespace {
using P = BuiltinProcessor::Param;
const char *const kKeys[] = {"C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"};
const char *const kScales[] = {"Chromatic", "Major", "Minor", "Dorian", "Mixolydian", "Major Pentatonic", "Minor Pentatonic", "Harmonic Minor", "Blues"};
constexpr uint16_t kScaleMasks[] = {0xFFF, 0xAB5, 0x5AD, 0x6AD, 0x6B5, 0x295, 0x4A9, 0x9AD, 0x4E9};

const std::vector<P> &pitchParams() {
    static const std::vector<P> params = {
        {PitchCorrect::kKey, "Key", "", 0, 11, 0, P::Choice, kKeys},
        {PitchCorrect::kScale, "Scale", "", 0, 8, 0, P::Choice, kScales},
        {PitchCorrect::kSpeed, "Speed", "ms", 0, 500, 40, P::Linear},
        {PitchCorrect::kAmount, "Amount", "%", 0, 100, 100, P::Linear},
        {PitchCorrect::kDetected, "Detected Note", "", 0, 127, 0, P::Linear, nullptr, true},
        {PitchCorrect::kCorrection, "Correction", "ct", -600, 600, 0, P::Linear, nullptr, true},
    };
    return params;
}
} // namespace

PitchCorrect::PitchCorrect(double sampleRate)
    : BuiltinProcessor("pitch-correct", "Dalnok Pitch Correct", pitchParams()), sampleRate_(sampleRate),
      shifter_(dalnok_dsp_shifter_create(2, sampleRate)) {
    latency_ = dalnok_dsp_shifter_latency(shifter_);
    ring_.assign(kWindow, 0.0f);
    frame_.assign(kWindow, 0.0f);
    diff_.assign(kWindow / 2, 0.0f);
    raw_.assign(kWindow / 2, 0.0f);
    outL_.assign(4096, 0.0f);
    outR_.assign(4096, 0.0f);
}

PitchCorrect::~PitchCorrect() { dalnok_dsp_shifter_destroy(shifter_); }

double PitchCorrect::meter(uint32_t id) const {
    if (id == kDetected) return detectedNote_.load(std::memory_order_relaxed);
    if (id == kCorrection) return correctionCents_.load(std::memory_order_relaxed);
    return 0;
}

void PitchCorrect::changed() DALNOK_NONBLOCKING {
    key_ = static_cast<int>(std::lround(rt(kKey)));
    scale_ = kScaleMasks[std::clamp(static_cast<int>(std::lround(rt(kScale))), 0, 8)];
    const double ms = rt(kSpeed);
    speedCoef_ = ms < 0.5 ? 1.0 : 1.0 - std::exp(-1.0 / (ms * 1e-3 * sampleRate_)); // per sample, toward the target
    amount_ = std::clamp(rt(kAmount) / 100, 0.0, 1.0);
}

// YIN (de Cheveigné and Kawahara, 2002) on the last kWindow decimated samples: sets target_ (semitones of shift).
void PitchCorrect::detect() DALNOK_NONBLOCKING {
    const double rate = sampleRate_ / kDecim;
    for (int i = 0; i < kWindow; ++i) frame_[static_cast<size_t>(i)] = ring_[static_cast<size_t>((ringPos_ + i) % kWindow)];
    const int maxTau = std::min(kWindow / 2 - 1, static_cast<int>(rate / 70)), minTau = std::max(2, static_cast<int>(rate / 1000));
    double energy = 0;
    for (float v : frame_) energy += static_cast<double>(v) * v;
    if (energy / kWindow < 1e-6) { target_ = 0; detectedNote_.store(0, std::memory_order_relaxed); return; } // silence
    double running = 0;
    int found = -1;
    for (int tau = 1; tau <= maxTau; ++tau) {
        double d = 0;
        for (int i = 0; i < kWindow / 2; ++i) { const double x = frame_[static_cast<size_t>(i)] - frame_[static_cast<size_t>(i + tau)]; d += x * x; }
        running += d;
        raw_[static_cast<size_t>(tau)] = static_cast<float>(d);
        diff_[static_cast<size_t>(tau)] = static_cast<float>(running > 0 ? d * tau / running : 1); // cumulative mean normalized
        if (tau >= minTau && found < 0 && diff_[static_cast<size_t>(tau)] < 0.15f) found = tau;
        if (found >= 0 && tau > found && diff_[static_cast<size_t>(tau)] > diff_[static_cast<size_t>(tau - 1)]) break; // past the dip
    }
    if (found < 0) { target_ = 0; detectedNote_.store(0, std::memory_order_relaxed); return; } // not a pitched sound: leave it
    int best = found;
    while (best + 1 <= maxTau && diff_[static_cast<size_t>(best + 1)] < diff_[static_cast<size_t>(best)]) ++best;
    double tau = best; // parabolic interpolation around the dip, on the raw difference (the normalized one is biased)
    if (best > 1 && best < maxTau) {
        const double a = raw_[static_cast<size_t>(best - 1)], b = raw_[static_cast<size_t>(best)], c = raw_[static_cast<size_t>(best + 1)];
        const double den = a - 2 * b + c;
        if (std::fabs(den) > 1e-12) tau += 0.5 * (a - c) / den;
    }
    const double hz = rate / tau;
    const double note = 69 + 12 * std::log2(hz / 440);
    // The nearest note of the scale (a tie goes down).
    auto inScale = [&](int n) { return ((scale_ >> (((n - key_) % 12 + 12) % 12)) & 1) != 0; };
    double want = note, dist = 1e9;
    for (int n = static_cast<int>(std::floor(note)) - 6; n <= static_cast<int>(std::ceil(note)) + 6; ++n)
        if (inScale(n) && std::fabs(n - note) < dist - 1e-9) { dist = std::fabs(n - note); want = n; }
    target_ = (want - note) * amount_;
    detectedNote_.store(static_cast<float>(note), std::memory_order_relaxed);
}

void PitchCorrect::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    for (int i = 0; i < frames; ++i) {
        // Decimate the mono sum (a one-pole low-pass, then every 4th average) into the detection ring.
        const double m = 0.5 * (left[i] + right[i]);
        lp_ += 0.35 * (m - lp_);
        decimSum_ += lp_;
        if (++decimCount_ == kDecim) {
            ring_[static_cast<size_t>(ringPos_)] = static_cast<float>(decimSum_ / kDecim);
            ringPos_ = (ringPos_ + 1) % kWindow;
            decimSum_ = 0;
            decimCount_ = 0;
            if (++hopCount_ == kHop) { hopCount_ = 0; detect(); }
        }
        current_ += speedCoef_ * (target_ - current_);
    }
    correctionCents_.store(static_cast<float>(current_ * 100), std::memory_order_relaxed);
    if (!shifter_) return;
    // Through the shifter into scratch buffers (sized at construction), one factor per chunk, then back.
    const double factor = std::exp2(current_ / 12);
    for (int done = 0; done < frames;) {
        const int n = std::min(frames - done, static_cast<int>(outL_.size()));
        const float *in[2] = {left + done, right + done};
        float *out[2] = {outL_.data(), outR_.data()};
        dalnok_dsp_shifter_process(shifter_, in, out, n, factor);
        std::copy(outL_.begin(), outL_.begin() + n, left + done);
        std::copy(outR_.begin(), outR_.begin() + n, right + done);
        done += n;
    }
}

} // namespace dalnok::fx

#pragma clang diagnostic pop
