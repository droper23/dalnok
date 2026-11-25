// Guitar Studio modules: the catalog (names and knobs) and their DSP. All designs are original: filters,
// waveshapers and delay networks written for Dalnok, not models or captures of commercial equipment.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "rt.hpp"
#include <cstddef>
#include <string>
#include <vector>

namespace dalnok::fx::guitar {

enum Type : int {
    Empty, Gate, Compressor, Boost, Overdrive, Distortion, Fuzz, AmpClean, AmpCrunch, AmpLead, Cabinet, Eq,
    Wah, Chorus, Flanger, Phaser, Tremolo, Vibrato, Delay, Reverb, Spring, TypeCount
};
constexpr int kKnobs = 6;

struct Knob {
    const char *name = nullptr, *units = "";
    double min = 0, max = 1, def = 0;
    enum Curve { Linear, Log, Steps } curve = Linear;
    const char *const *labels = nullptr; // Steps: one label per integer from min to max
};
struct Module {
    const char *name, *category;
    int knobs;
    Knob knob[kKnobs];
};

const Module &module(int type) DALNOK_NONBLOCKING;
const char *const *moduleNames(); // TypeCount entries, for the type parameter's choices
double knobValue(const Knob &, double normalized) DALNOK_NONBLOCKING;
double knobNormalized(const Knob &, double value);
std::string knobText(const Knob &, double normalized);

// RBJ biquad, transposed direct form II, two channels.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1[2]{}, z2[2]{};
    double run(int c, double x) DALNOK_NONBLOCKING {
        const double y = b0 * x + z1[c];
        z1[c] = b1 * x - a1 * y + z2[c];
        z2[c] = b2 * x - a2 * y;
        return y;
    }
    void lowpass(double hz, double q, double rate) DALNOK_NONBLOCKING;
    void highpass(double hz, double q, double rate) DALNOK_NONBLOCKING;
    void peak(double hz, double q, double db, double rate) DALNOK_NONBLOCKING;
    void lowShelf(double hz, double db, double rate) DALNOK_NONBLOCKING;
    void highShelf(double hz, double db, double rate) DALNOK_NONBLOCKING;
    void flush() DALNOK_NONBLOCKING;
};

// A delay line in a slice of the module's preallocated pool. Reads happen before the push of the current sample,
// so `at(d)` is the sample from d pushes ago (d >= 1).
struct Line {
    float *b = nullptr;
    int size = 0, w = 0;
    void push(double x) DALNOK_NONBLOCKING { b[w] = static_cast<float>(x); if (++w == size) w = 0; }
    double at(int d) const DALNOK_NONBLOCKING { int i = w - d; if (i < 0) i += size; return b[i]; }
    double linear(double d) const DALNOK_NONBLOCKING;
    double cubic(double d) const DALNOK_NONBLOCKING;
};

// 4x oversampling for the nonlinear stages: an 8th-order Chebyshev I low-pass (0.1 dB ripple, corner at 0.45 of
// the base rate) interpolates and again decimates. Zero latency (IIR), so the plug-in reports none.
struct Oversampler {
    struct Section { double b0, b1, b2, a1, a2; } sec[4]{};
    double up[2][4][2]{}, down[2][4][2]{};
    void design(double baseRate);
    void clear() DALNOK_NONBLOCKING;
    double filter(double st[4][2], double x) const DALNOK_NONBLOCKING {
        for (int i = 0; i < 4; ++i) {
            const Section &s = sec[i];
            const double y = s.b0 * x + st[i][0];
            st[i][0] = s.b1 * x - s.a1 * y + st[i][1];
            st[i][1] = s.b2 * x - s.a2 * y;
            x = y;
        }
        return x;
    }
    template <class F> double run(int c, double x, F &&shape) DALNOK_NONBLOCKING {
        double out = 0;
        for (int k = 0; k < 4; ++k) out = filter(down[c], shape(filter(up[c], k == 0 ? 4 * x : 0.0)));
        return out;
    }
};

// One slot's processing. `prepare` allocates on the control thread; everything else runs on the audio thread.
class ModuleDsp {
public:
    void prepare(double rate);
    void reset(int type) DALNOK_NONBLOCKING;                           // clears state and lays out buffers
    void update(int type, const double *v, int frames) DALNOK_NONBLOCKING; // knob values in their own units
    void process(int type, double &l, double &r) DALNOK_NONBLOCKING;
    void flush() DALNOK_NONBLOCKING;                                   // denormal guard between chunks

private:
    Line carve(double seconds) DALNOK_NONBLOCKING;
    void processDrive(int type, double &l, double &r) DALNOK_NONBLOCKING;
    void processAmp(int type, double &l, double &r) DALNOK_NONBLOCKING;
    void processReverb(double &l, double &r) DALNOK_NONBLOCKING;
    void processSpring(double &l, double &r) DALNOK_NONBLOCKING;

    double rate_ = 48000;
    std::vector<float> pool_;
    size_t used_ = 0;
    Oversampler os_;
    Biquad bq_[9];
    Line line_[2], fdn_[8], diff_[4], pre_;
    // Generic state, by meaning per module (see guitar_modules.cpp).
    double env_ = 0, gain_ = 1, hold_ = 0, open_ = 0, gr_ = 0;
    double lfo_ = 0, lfo2_ = 0, inc_ = 0, time_ = 0;
    double one_[2]{}, two_[2]{}, three_[2]{}, fb_[2]{}, inter_[2]{};
    double ap_[2][12][4]{};
    double adaa_[2][2][2]{}; // per channel and clipping stage: previous input and antiderivative
    double fdnLp_[8]{}, fdnLen_[8]{}, fdnGain_[8]{}, fdnMod_[8]{};
    double c_[24]{}; // coefficients from `update`
    bool fresh_ = true;
};

} // namespace dalnok::fx::guitar
