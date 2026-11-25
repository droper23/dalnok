// Dalnok Pitch Correct: automatic pitch correction for a monophonic voice or instrument (Logic's Pitch Correction,
// the everyday use of Flex Pitch; Ableton users reach for an equivalent plug-in). It hears the pitch (YIN, on a 4x
// decimated copy), finds the nearest note of the chosen key and scale, and shifts the audio toward it in real time
// (Signalsmith Stretch); Speed sets how fast it gets there (0 ms: at once, the hard-tuned sound), Amount how far.
// Dalnok's own design.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "fx/builtin.hpp"
#include "dalnok_dsp.h"

#include <atomic>
#include <vector>

namespace dalnok::fx {

class PitchCorrect final : public BuiltinProcessor {
public:
    explicit PitchCorrect(double sampleRate);
    ~PitchCorrect() override;
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    uint32_t latency() const override { return static_cast<uint32_t>(latency_); }
    enum : uint32_t { kKey = 0, kScale, kSpeed, kAmount, kDetected, kCorrection };

private:
    void changed() DALNOK_NONBLOCKING override;
    double meter(uint32_t id) const override;
    void detect() DALNOK_NONBLOCKING;
    double sampleRate_;
    DalnokShifter *shifter_ = nullptr;
    int latency_ = 0;
    // Detection: the input decimated by 4 into a ring; YIN every 64 decimated samples over the last 512.
    static constexpr int kDecim = 4, kWindow = 512, kHop = 64;
    std::vector<float> ring_, frame_, diff_, raw_, outL_, outR_;
    int ringPos_ = 0, decimCount_ = 0, hopCount_ = 0;
    double decimSum_ = 0, lp_ = 0;
    // Correction.
    int key_ = 0;
    uint16_t scale_ = 0xFFF;
    double speedCoef_ = 1, amount_ = 1;
    double target_ = 0, current_ = 0; // semitones of shift: wanted and applied
    std::atomic<float> detectedNote_{0}, correctionCents_{0};
};

} // namespace dalnok::fx
