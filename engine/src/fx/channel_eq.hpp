// Dalnok Channel EQ: an eight-band channel EQ compatible with Logic Pro's Channel EQ settings.
// Parameter ids are the slot numbers of Logic's saved parameter block, so imported settings copy across.
// Peak bands and Gain-Q coupling null against Logic at float precision (04 - Research/Logic Effect Parity.md);
// shelves, cuts and oversampling follow Logic's structure but are not yet verified by render.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "fx/builtin.hpp"

#include <array>

namespace dalnok::fx {

struct Biquad { double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0; };

// Coefficient design (control or audio thread; pure).
std::array<double, 128> channelEqQTable();                  // the Q knob's displayed values
double channelEqQDisplay(double q);                         // snap a stored Q to them
double channelEqCoupleScale(double gainDb, int mode);       // Gain-Q coupling factor
Biquad channelEqPeak(double hz, double gainDb, double q, double sampleRate, bool couple, int mode) DALNOK_NONBLOCKING;
Biquad channelEqShelf(bool high, double hz, double gainDb, double q, double sampleRate) DALNOK_NONBLOCKING;
// Cut filters: `slopeCode` is Logic's code (12 dB/oct = 2, 24 dB/oct = 4). Returns the number of sections written.
int channelEqCut(bool high, double hz, int slopeCode, double q, double sampleRate, std::array<Biquad, 4> &out) DALNOK_NONBLOCKING;

class ChannelEq final : public BuiltinProcessor {
public:
    explicit ChannelEq(double sampleRate);
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;

    enum : uint32_t {
        kLowCutOn = 0, kLowCutFreq, kLowCutSlope, kLowCutQ,
        kLowShelfOn, kLowShelfFreq, kLowShelfGain, kLowShelfQ,
        kPeak1On, kPeak1Freq, kPeak1Gain, kPeak1Q, // peaks 2-4 follow in blocks of four
        kHighShelfOn = 24, kHighShelfFreq, kHighShelfGain, kHighShelfQ,
        kHighCutOn = 28, kHighCutFreq, kHighCutSlope, kHighCutQ,
        kMasterGain = 32, kCouple = 41, kCoupleMode = 42, kOversampling = 43,
    };
    static constexpr int kSections = 14; // 4 + 1 + 4 + 1 + 4

private:
    void changed() DALNOK_NONBLOCKING override;
    double sampleRate_;
    std::array<double, 128> qShown_;
    std::array<Biquad, kSections> coef_{};
    int active_ = 0;
    double gain_ = 1;
    struct State { double x1 = 0, x2 = 0, y1 = 0, y2 = 0; };
    std::array<std::array<State, kSections>, 2> state_{};
};

} // namespace dalnok::fx
