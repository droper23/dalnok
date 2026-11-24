// Loudness metering after ITU-R BS.1770-4 / EBU R128: K-weighted momentary (400 ms), short-term (3 s) and gated
// integrated loudness in LUFS, and true peak (4x oversampled) in dBTP. Stereo, both channels weight 1.
// `process` runs on the audio thread (no allocation, no locks); the results are atomics any thread can read.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "rt.hpp"

#include <array>
#include <atomic>
#include <cstdint>

namespace dalnok {

struct LoudnessReading {
    float momentary, shortTerm, integrated, truePeak; // LUFS / dBTP; -INFINITY when there is nothing yet
    float maxMomentary, maxShortTerm;
};

class LoudnessMeter {
public:
    explicit LoudnessMeter(double sampleRate);
    void process(const float *left, const float *right, int frames) DALNOK_NONBLOCKING;
    void reset();                               // control thread: takes effect at the next `process`
    LoudnessReading reading() const;

private:
    struct Biquad { double b0, b1, b2, a1, a2, x1 = 0, x2 = 0, y1 = 0, y2 = 0; };
    static constexpr int kSub = 30;             // 100 ms sub-blocks kept (3 s)
    static constexpr int kBins = 800;           // integrated-gating histogram: 0.1 LU bins from -70 to +10 LUFS
    static constexpr int kPhases = 4, kTaps = 12; // true-peak interpolator: 4 phases of 12 taps
    void clear() DALNOK_NONBLOCKING;
    void subBlockDone() DALNOK_NONBLOCKING;

    double sampleRate_;
    int64_t subLength_;
    Biquad shelf_[2], highPass_[2];
    double subSum_ = 0;
    int64_t subCount_ = 0;
    std::array<double, kSub> subs_{};          // mean square of each recent 100 ms sub-block
    int subWrite_ = 0, subFilled_ = 0;
    std::array<double, kBins> binEnergy_{};
    std::array<int64_t, kBins> binCount_{};
    std::array<float, kPhases * kTaps> fir_{};
    std::array<float, kTaps> histL_{}, histR_{};
    int histPos_ = 0;
    double peak_ = 0, maxM_ = 0, maxS_ = 0;
    std::atomic<bool> resetPending_{false};
    std::atomic<float> momentary_, shortTerm_, integrated_, truePeak_, maxMomentary_, maxShortTerm_;
};

} // namespace dalnok
