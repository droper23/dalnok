// Dalnok Channel EQ (see channel_eq.hpp).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/channel_eq.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>

// Coefficient design runs on the audio thread when parameters or automation change. It calls libm (sin, cos, tan,
// pow, log10), which neither allocates nor locks; the real-time checker cannot see that, so it is allowed here.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"

namespace dalnok::fx {
namespace {
constexpr double kPi = 3.14159265358979323846;

// Normalized frequency is limited below Nyquist, as Logic does (0.49 of the sample rate).
double halfAngle(double hz, double sampleRate) DALNOK_NONBLOCKING { return kPi * std::min(hz / sampleRate, 0.49); }

Biquad normalize(double b0, double b1, double b2, double a0, double a1, double a2) DALNOK_NONBLOCKING {
    return {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

const char *const kOnOff[] = {"Off", "On"};
// Logic stores slope codes; 2 (12 dB/Oct) and 4 (24 dB/Oct) are confirmed, the rest follow 6 dB per code.
const char *const kSlopes[] = {"0", "6 dB/Oct", "12 dB/Oct", "18 dB/Oct", "24 dB/Oct", "30 dB/Oct", "36 dB/Oct", "42 dB/Oct", "48 dB/Oct"};
const char *const kCoupleModes[] = {"Asymmetric Light", "Asymmetric Strong", "Asymmetric Medium", "Light", "Medium", "Strong"};

std::vector<BuiltinProcessor::Param> buildParams() {
    using P = BuiltinProcessor::Param;
    std::vector<P> p;
    static std::deque<std::string> titles; // stable storage; built once (see channelEqParams)
    auto band = [&](uint32_t base, const char *name, double hz, bool on, bool cut, double gainOrSlope, double q) {
        auto title = [&](const char *what) {
            titles.push_back(std::string(name) + " " + what);
            return titles.back().c_str();
        };
        p.push_back({base, title("On/Off"), "", 0, 1, on ? 1.0 : 0.0, P::Toggle, kOnOff});
        p.push_back({base + 1, title("Frequency"), "Hz", 20, 20000, hz, P::Log});
        if (cut) p.push_back({base + 2, title("Slope"), "", 0, 8, gainOrSlope, P::Choice, kSlopes});
        else p.push_back({base + 2, title("Gain"), "dB", -24, 24, gainOrSlope, P::Linear});
        p.push_back({base + 3, title("Q-Factor"), "", 0.1, 100, q, P::Log});
    };
    // Defaults are Logic's default preset.
    band(0, "Low Cut", 20, false, true, 2, 0.71);
    band(4, "Low Shelf", 75, true, false, 0, 1.0);
    band(8, "Peak 1", 100, true, false, 0, 0.6);
    band(12, "Peak 2", 250, true, false, 0, 0.3);
    band(16, "Peak 3", 1040, true, false, 0, 0.41);
    band(20, "Peak 4", 2500, true, false, 0, 0.2);
    band(24, "High Shelf", 7500, true, false, 0, 1.0);
    band(28, "High Cut", 20000, false, true, 4, 0.71);
    p.push_back({ChannelEq::kMasterGain, "Master Gain", "dB", -24, 24, 0, P::Linear});
    p.push_back({ChannelEq::kCouple, "Gain-Q Coupling", "", 0, 1, 1, P::Toggle, kOnOff});
    p.push_back({ChannelEq::kCoupleMode, "Gain-Q Couple Mode", "", -3, 2, -1, P::Choice, kCoupleModes});
    p.push_back({ChannelEq::kOversampling, "Oversampling", "", 0, 1, 0, P::Toggle, kOnOff});
    return p;
}
const std::vector<BuiltinProcessor::Param> &channelEqParams() {
    static const std::vector<BuiltinProcessor::Param> params = buildParams();
    return params;
}

double snapQ(const std::array<double, 128> &shown, double q) DALNOK_NONBLOCKING {
    double best = shown[0], bestDist = std::fabs(shown[0] - q);
    for (double v : shown) if (const double d = std::fabs(v - q); d < bestDist) { best = v; bestDist = d; }
    return best;
}
} // namespace

std::array<double, 128> channelEqQTable() {
    // The Q knob has 128 positions, Q_i = 10^(-1 + 3i/127), shown to two significant digits.
    std::array<double, 128> t{};
    for (int i = 0; i < 128; ++i) {
        char text[32];
        snprintf(text, sizeof text, "%.2g", std::pow(10.0, -1.0 + 3.0 * i / 127.0));
        t[static_cast<size_t>(i)] = std::strtod(text, nullptr);
    }
    return t;
}

double channelEqQDisplay(double q) {
    // A stored value snaps to the nearest shown value; ties go to the lower one.
    return snapQ(channelEqQTable(), q);
}

double channelEqCoupleScale(double gainDb, int mode) {
    double strength = 1, cutFactor = 1;
    switch (mode) {
    case 0: strength = 0.5; break;
    case 2: strength = 2; break;
    case -1: cutFactor = 3; break;
    case -2: strength = 2; cutFactor = 3; break;
    case -3: strength = 0.5; cutFactor = 3; break;
    default: break; // 1 and any other value: medium
    }
    const double s = gainDb >= 0 ? strength : strength * cutFactor, g = std::fabs(gainDb);
    return 1 + s * g * (0.06 + 0.005625 * g);
}

Biquad channelEqPeak(double hz, double gainDb, double q, double sampleRate, bool couple, int mode) DALNOK_NONBLOCKING {
    // q is the already-snapped display value (see changed()); coupling and the 1/300-decade grid apply here.
    const double half = halfAngle(hz, sampleRate), w = 2 * half;
    const double A = std::pow(10.0, std::fabs(gainDb) / 40.0);
    const double k = couple ? channelEqCoupleScale(gainDb, mode) : 1.0;
    const double qGrid = std::pow(10.0, std::round(300.0 * std::log10(q * k)) / 300.0);
    const double qEff = qGrid * half / std::tan(half);
    const double alpha = std::sin(w) * A / (2 * qEff), c = -2 * std::cos(w);
    if (gainDb >= 0) return normalize(1 + alpha * A, c, 1 - alpha * A, 1 + alpha / A, c, 1 - alpha / A);
    return normalize(1 + alpha / A, c, 1 - alpha / A, 1 + alpha * A, c, 1 - alpha * A);
}

Biquad channelEqShelf(bool high, double hz, double gainDb, double q, double sampleRate) DALNOK_NONBLOCKING {
    // RBJ shelf; the slope uses Q limited by a gain-dependent ceiling. Not yet verified against Logic renders.
    const double A = std::pow(10.0, gainDb / 40.0), g = std::fabs(gainDb);
    const double limit = g < 21 ? 6.2 - 0.2 * g : 4.56 - 0.12 * g;
    const double S = std::min(q, limit);
    const double w = 2 * halfAngle(hz, sampleRate), cs = std::cos(w), sn = std::sin(w);
    const double r = std::max(0.0, (A * A + 1) / S - (A - 1) * (A - 1));
    const double t = std::sqrt(r) * sn; // 2·sqrt(A)·alpha
    if (!high)
        return normalize(A * ((A + 1) - (A - 1) * cs + t), 2 * A * ((A - 1) - (A + 1) * cs), A * ((A + 1) - (A - 1) * cs - t),
                         (A + 1) + (A - 1) * cs + t, -2 * ((A - 1) + (A + 1) * cs), (A + 1) + (A - 1) * cs - t);
    return normalize(A * ((A + 1) + (A - 1) * cs + t), -2 * A * ((A - 1) + (A + 1) * cs), A * ((A + 1) + (A - 1) * cs - t),
                     (A + 1) - (A - 1) * cs + t, 2 * ((A - 1) - (A + 1) * cs), (A + 1) - (A - 1) * cs - t);
}

int channelEqCut(bool high, double hz, int slopeCode, double q, double sampleRate, std::array<Biquad, 4> &out) DALNOK_NONBLOCKING {
    // Placeholder until measured: a Butterworth cascade of order = slope code, with the band's Q scaling the
    // most resonant section. Logic uses its own variable-Q tables here.
    const int order = std::clamp(slopeCode, 1, 8);
    const double w = 2 * halfAngle(hz, sampleRate), cs = std::cos(w), sn = std::sin(w);
    int n = 0;
    if (order % 2) {
        const double K = std::tan(w / 2);
        out[static_cast<size_t>(n++)] = high ? normalize(1, -1, 0, 1 + K, K - 1, 0) : normalize(K, K, 0, 1 + K, K - 1, 0);
    }
    for (int k = 1; k <= order / 2 && n < 4; ++k) {
        double sq = 1 / (2 * std::cos((2 * k - 1) * kPi / (2 * order)));
        if (k == 1) sq *= q / 0.70710678118654752;
        const double alpha = sn / (2 * sq);
        out[static_cast<size_t>(n++)] = high ? normalize((1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + alpha, -2 * cs, 1 - alpha)
                                             : normalize((1 - cs) / 2, 1 - cs, (1 - cs) / 2, 1 + alpha, -2 * cs, 1 - alpha);
    }
    return n;
}

ChannelEq::ChannelEq(double sampleRate)
    : BuiltinProcessor("channel-eq", "Dalnok Channel EQ", channelEqParams()), sampleRate_(sampleRate), qShown_(channelEqQTable()) {}

void ChannelEq::changed() DALNOK_NONBLOCKING {
    int n = 0;
    const bool couple = rt(kCouple) >= 0.5;
    const int mode = static_cast<int>(std::lround(rt(kCoupleMode)));
    // The cut bands run first and last, shelves and peaks in between (order does not change an LTI cascade).
    if (rt(kLowCutOn) >= 0.5) {
        std::array<Biquad, 4> s{};
        const int m = channelEqCut(false, rt(kLowCutFreq), static_cast<int>(std::lround(rt(kLowCutSlope))),
                                   snapQ(qShown_, rt(kLowCutQ)), sampleRate_, s);
        for (int i = 0; i < m && n < kSections; ++i) coef_[static_cast<size_t>(n++)] = s[static_cast<size_t>(i)];
    }
    for (uint32_t base : {kLowShelfOn, kHighShelfOn})
        if (rt(base) >= 0.5 && rt(base + 2) != 0)
            coef_[static_cast<size_t>(n++)] = channelEqShelf(base == kHighShelfOn, rt(base + 1), rt(base + 2),
                                                             snapQ(qShown_, rt(base + 3)), sampleRate_);
    for (uint32_t base = kPeak1On; base < kHighShelfOn; base += 4)
        if (rt(base) >= 0.5 && rt(base + 2) != 0)
            coef_[static_cast<size_t>(n++)] = channelEqPeak(rt(base + 1), rt(base + 2), snapQ(qShown_, rt(base + 3)),
                                                            sampleRate_, couple, mode);
    if (rt(kHighCutOn) >= 0.5) {
        std::array<Biquad, 4> s{};
        const int m = channelEqCut(true, rt(kHighCutFreq), static_cast<int>(std::lround(rt(kHighCutSlope))),
                                   snapQ(qShown_, rt(kHighCutQ)), sampleRate_, s);
        for (int i = 0; i < m && n < kSections; ++i) coef_[static_cast<size_t>(n++)] = s[static_cast<size_t>(i)];
    }
    if (n != active_) for (auto &ch : state_) for (auto &st : ch) st = {};
    active_ = n;
    gain_ = std::pow(10.0, rt(kMasterGain) / 20.0);
}

void ChannelEq::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    float *io[2] = {left, right};
    for (int ch = 0; ch < 2; ++ch) {
        float *x = io[ch];
        for (int i = 0; i < frames; ++i) {
            double v = x[i];
            for (int s = 0; s < active_; ++s) {
                const Biquad &c = coef_[static_cast<size_t>(s)];
                State &st = state_[static_cast<size_t>(ch)][static_cast<size_t>(s)];
                const double y = c.b0 * v + c.b1 * st.x1 + c.b2 * st.x2 - c.a1 * st.y1 - c.a2 * st.y2;
                st.x2 = st.x1; st.x1 = v; st.y2 = st.y1; st.y1 = y;
                v = y;
            }
            x[i] = static_cast<float>(v * gain_);
        }
    }
}

} // namespace dalnok::fx

#pragma clang diagnostic pop
