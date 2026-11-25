// Guitar Studio modules: catalog and DSP. Original designs (see guitar_modules.hpp).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/guitar_modules.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace dalnok::fx::guitar {
namespace {
constexpr double pi = 3.14159265358979323846;
using K = Knob;
const char *const sizes[] = {"1x12", "2x12", "4x12"};
const char *const stageCounts[] = {"4", "6", "8", "12"};
constexpr int stageTable[] = {4, 6, 8, 12};

// Knob names are single words so the device panel groups a module's controls under "<slot> <module>".
const Module catalog[TypeCount] = {
    {"Empty", "", 0, {}},
    {"Noise Gate", "Dynamics", 3,
     {{"Threshold", "dB", -90, -20, -60}, {"Release", "ms", 5, 1000, 120, K::Log}, {"Range", "dB", 0, 90, 70}}},
    {"Compressor", "Dynamics", 6,
     {{"Threshold", "dB", -50, 0, -24}, {"Ratio", ":1", 1, 20, 4, K::Log}, {"Attack", "ms", 0.1, 100, 10, K::Log},
      {"Release", "ms", 20, 1000, 150, K::Log}, {"Makeup", "dB", 0, 24, 6}, {"Mix", "%", 0, 100, 100}}},
    {"Boost", "Drive", 3, {{"Gain", "dB", 0, 24, 8}, {"Tone", "dB", -9, 9, 0}, {"Level", "dB", -24, 6, 0}}},
    {"Overdrive", "Drive", 4,
     {{"Drive", "%", 0, 100, 45}, {"Tone", "%", 0, 100, 50}, {"Level", "dB", -24, 12, 0}, {"Mix", "%", 0, 100, 100}}},
    {"Distortion", "Drive", 4,
     {{"Drive", "%", 0, 100, 55}, {"Tone", "%", 0, 100, 50}, {"Level", "dB", -24, 12, 0}, {"Mix", "%", 0, 100, 100}}},
    {"Fuzz", "Drive", 5,
     {{"Fuzz", "%", 0, 100, 60}, {"Tone", "%", 0, 100, 50}, {"Bias", "%", 0, 100, 20}, {"Level", "dB", -24, 12, 0},
      {"Mix", "%", 0, 100, 100}}},
    {"Amp Clean", "Amp & Cabinet", 6,
     {{"Gain", "%", 0, 100, 35}, {"Bass", "", 0, 10, 5}, {"Middle", "", 0, 10, 5}, {"Treble", "", 0, 10, 5},
      {"Presence", "", 0, 10, 5}, {"Level", "dB", -24, 12, 0}}},
    {"Amp Crunch", "Amp & Cabinet", 6,
     {{"Gain", "%", 0, 100, 45}, {"Bass", "", 0, 10, 5}, {"Middle", "", 0, 10, 6}, {"Treble", "", 0, 10, 5},
      {"Presence", "", 0, 10, 5}, {"Level", "dB", -24, 12, 0}}},
    {"Amp Lead", "Amp & Cabinet", 6,
     {{"Gain", "%", 0, 100, 55}, {"Bass", "", 0, 10, 5}, {"Middle", "", 0, 10, 6}, {"Treble", "", 0, 10, 5},
      {"Presence", "", 0, 10, 5}, {"Level", "dB", -24, 12, 0}}},
    {"Cabinet", "Amp & Cabinet", 6,
     {{"Size", "", 0, 2, 2, K::Steps, sizes}, {"Mic", "%", 0, 100, 30}, {"Distance", "%", 0, 100, 20},
      {"Low-cut", "Hz", 20, 300, 70, K::Log}, {"High-cut", "Hz", 2000, 12000, 7000, K::Log}, {"Mix", "%", 0, 100, 100}}},
    {"EQ", "Filter & EQ", 6,
     {{"Low-cut", "Hz", 20, 400, 20, K::Log}, {"Bass", "dB", -15, 15, 0}, {"Middle", "dB", -15, 15, 0},
      {"Frequency", "Hz", 200, 5000, 800, K::Log}, {"Treble", "dB", -15, 15, 0}, {"High-cut", "Hz", 1500, 20000, 20000, K::Log}}},
    {"Wah", "Filter & EQ", 5,
     {{"Pedal", "%", 0, 100, 50}, {"Auto", "%", 0, 100, 0}, {"Rate", "Hz", 0, 8, 0}, {"Resonance", "%", 0, 100, 60},
      {"Mix", "%", 0, 100, 100}}},
    {"Chorus", "Modulation", 5,
     {{"Rate", "Hz", 0.05, 8, 0.8, K::Log}, {"Depth", "%", 0, 100, 40}, {"Delay", "ms", 5, 30, 12},
      {"Width", "%", 0, 100, 70}, {"Mix", "%", 0, 100, 50}}},
    {"Flanger", "Modulation", 6,
     {{"Rate", "Hz", 0.02, 5, 0.25, K::Log}, {"Depth", "%", 0, 100, 70}, {"Manual", "ms", 0.3, 8, 1.5, K::Log},
      {"Feedback", "%", -95, 95, 50}, {"Width", "%", 0, 100, 50}, {"Mix", "%", 0, 100, 50}}},
    {"Phaser", "Modulation", 6,
     {{"Rate", "Hz", 0.02, 8, 0.5, K::Log}, {"Depth", "%", 0, 100, 70}, {"Stages", "", 0, 3, 1, K::Steps, stageCounts},
      {"Feedback", "%", 0, 90, 40}, {"Width", "%", 0, 100, 50}, {"Mix", "%", 0, 100, 50}}},
    {"Tremolo", "Modulation", 4,
     {{"Rate", "Hz", 0.5, 15, 5, K::Log}, {"Depth", "%", 0, 100, 60}, {"Shape", "%", 0, 100, 0}, {"Stereo", "%", 0, 100, 0}}},
    {"Vibrato", "Modulation", 3, {{"Rate", "Hz", 0.5, 12, 5, K::Log}, {"Depth", "%", 0, 100, 40}, {"Mix", "%", 0, 100, 100}}},
    {"Delay", "Time", 6,
     {{"Time", "ms", 20, 2000, 380, K::Log}, {"Feedback", "%", 0, 95, 35}, {"Tone", "Hz", 800, 16000, 4500, K::Log},
      {"Modulation", "%", 0, 100, 15}, {"Ping-pong", "%", 0, 100, 0}, {"Mix", "%", 0, 100, 30}}},
    {"Reverb", "Time", 6,
     {{"Decay", "s", 0.2, 12, 2, K::Log}, {"Size", "%", 0, 100, 60}, {"Pre-delay", "ms", 0, 200, 15},
      {"Tone", "Hz", 1000, 16000, 6000, K::Log}, {"Modulation", "%", 0, 100, 30}, {"Mix", "%", 0, 100, 25}}},
    {"Spring", "Time", 4,
     {{"Decay", "s", 0.5, 6, 2, K::Log}, {"Tone", "Hz", 1500, 8000, 4000, K::Log}, {"Drip", "%", 0, 100, 50},
      {"Mix", "%", 0, 100, 30}}},
};

const char *const *buildNames() {
    static const char *names[TypeCount];
    for (int i = 0; i < TypeCount; ++i) names[i] = catalog[i].name;
    return names;
}

// Reverb network lengths (ms) before the Size scale; mutually prime-ish so modes spread evenly.
constexpr double fdnMs[8] = {29.7, 37.1, 41.1, 43.7, 53.3, 59.9, 67.7, 73.1};
constexpr double diffMs[4] = {4.77, 3.59, 12.73, 9.31};
constexpr double maxScale = 1.4;

// libm (sin, tan, exp, pow, tanh, log10) is allocation- and lock-free, as in the other built-in effects.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
double db(double v) DALNOK_NONBLOCKING { return std::pow(10.0, v / 20); }
double pole(double hz, double rate) DALNOK_NONBLOCKING { return 1 - std::exp(-2 * pi * std::min(hz, rate * 0.45) / rate); }
double timeCoef(double seconds, double rate) DALNOK_NONBLOCKING { return 1 - std::exp(-1 / (std::max(seconds, 1e-5) * rate)); }
void tiny(double &x) DALNOK_NONBLOCKING { if (std::abs(x) < 1e-30) x = 0; }
#pragma clang diagnostic pop
// Delay and reverb mix: the dry signal stays at full level up to 50 %, then fades; the wet level reaches full at 50 %.
void wetLaw(double mix, double &dry, double &wet) DALNOK_NONBLOCKING {
    dry = std::min(1.0, 2 * (1 - mix));
    wet = std::min(1.0, 2 * mix);
}
} // namespace

const Module &module(int type) DALNOK_NONBLOCKING { return catalog[std::clamp(type, 0, TypeCount - 1)]; }
const char *const *moduleNames() {
    static const char *const *names = buildNames();
    return names;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
double knobValue(const Knob &k, double n) DALNOK_NONBLOCKING {
    n = std::clamp(n, 0.0, 1.0);
    switch (k.curve) {
    case Knob::Log: return k.min * std::pow(k.max / k.min, n);
    case Knob::Steps: return std::round(k.min + n * (k.max - k.min));
    case Knob::Linear: break;
    }
    return k.min + n * (k.max - k.min);
}
#pragma clang diagnostic pop

double knobNormalized(const Knob &k, double v) {
    if (k.max <= k.min) return 0;
    if (k.curve == Knob::Log) return std::clamp(std::log(std::max(v, k.min) / k.min) / std::log(k.max / k.min), 0.0, 1.0);
    return std::clamp((v - k.min) / (k.max - k.min), 0.0, 1.0);
}

std::string knobText(const Knob &k, double n) {
    const double v = knobValue(k, n);
    char t[48];
    const std::string u = k.units;
    if (k.curve == Knob::Steps && k.labels) snprintf(t, sizeof t, "%s", k.labels[static_cast<int>(v - k.min)]);
    else if (u == "Hz" && k.min == 0 && v < 0.01) snprintf(t, sizeof t, "Off");
    else if (u == "Hz" && v >= 1000) snprintf(t, sizeof t, "%.1f kHz", v / 1000);
    else if (u == "Hz") snprintf(t, sizeof t, v < 10 ? "%.2f Hz" : "%.0f Hz", v);
    else if (u == "ms") snprintf(t, sizeof t, v < 10 ? "%.2f ms" : v < 100 ? "%.1f ms" : "%.0f ms", v);
    else if (u == "s") snprintf(t, sizeof t, "%.2f s", v);
    else if (u == "dB") snprintf(t, sizeof t, "%+.1f dB", v);
    else if (u == "%") snprintf(t, sizeof t, "%.0f %%", v);
    else if (u == ":1") snprintf(t, sizeof t, "%.1f:1", v);
    else snprintf(t, sizeof t, "%.1f", v);
    return t;
}


// ---- Filters --------------------------------------------------------------------------------------------------

namespace {
struct Rbj { double cs, sn; };
Rbj rbj(double hz, double rate) DALNOK_NONBLOCKING {
    const double w = 2 * pi * std::clamp(hz, 10.0, rate * 0.45) / rate;
    return {std::cos(w), std::sin(w)};
}
} // namespace

static void setBiquad(Biquad &q, double b0, double b1, double b2, double a0, double a1, double a2) DALNOK_NONBLOCKING {
    q.b0 = b0 / a0; q.b1 = b1 / a0; q.b2 = b2 / a0; q.a1 = a1 / a0; q.a2 = a2 / a0;
}
void Biquad::lowpass(double hz, double q, double rate) DALNOK_NONBLOCKING {
    const auto [cs, sn] = rbj(hz, rate);
    const double al = sn / (2 * q);
    setBiquad(*this, (1 - cs) / 2, 1 - cs, (1 - cs) / 2, 1 + al, -2 * cs, 1 - al);
}
void Biquad::highpass(double hz, double q, double rate) DALNOK_NONBLOCKING {
    const auto [cs, sn] = rbj(hz, rate);
    const double al = sn / (2 * q);
    setBiquad(*this, (1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + al, -2 * cs, 1 - al);
}
void Biquad::peak(double hz, double q, double gainDb, double rate) DALNOK_NONBLOCKING {
    const auto [cs, sn] = rbj(hz, rate);
    const double al = sn / (2 * q), a = std::pow(10.0, gainDb / 40);
    setBiquad(*this, 1 + al * a, -2 * cs, 1 - al * a, 1 + al / a, -2 * cs, 1 - al / a);
}
void Biquad::lowShelf(double hz, double gainDb, double rate) DALNOK_NONBLOCKING {
    const auto [cs, sn] = rbj(hz, rate);
    const double a = std::pow(10.0, gainDb / 40), al = sn / 2 * std::sqrt(2.0), r = 2 * std::sqrt(a) * al;
    setBiquad(*this, a * ((a + 1) - (a - 1) * cs + r), 2 * a * ((a - 1) - (a + 1) * cs), a * ((a + 1) - (a - 1) * cs - r),
              (a + 1) + (a - 1) * cs + r, -2 * ((a - 1) + (a + 1) * cs), (a + 1) + (a - 1) * cs - r);
}
void Biquad::highShelf(double hz, double gainDb, double rate) DALNOK_NONBLOCKING {
    const auto [cs, sn] = rbj(hz, rate);
    const double a = std::pow(10.0, gainDb / 40), al = sn / 2 * std::sqrt(2.0), r = 2 * std::sqrt(a) * al;
    setBiquad(*this, a * ((a + 1) + (a - 1) * cs + r), -2 * a * ((a - 1) + (a + 1) * cs), a * ((a + 1) + (a - 1) * cs - r),
              (a + 1) - (a - 1) * cs + r, 2 * ((a - 1) - (a + 1) * cs), (a + 1) - (a - 1) * cs - r);
}
void Biquad::flush() DALNOK_NONBLOCKING { for (int c = 0; c < 2; ++c) { tiny(z1[c]); tiny(z2[c]); } }

double Line::linear(double d) const DALNOK_NONBLOCKING {
    d = std::clamp(d, 1.0, static_cast<double>(size - 2));
    const int i = static_cast<int>(d);
    const double f = d - i, a = at(i);
    return a + f * (at(i + 1) - a);
}
double Line::cubic(double d) const DALNOK_NONBLOCKING {
    d = std::clamp(d, 2.0, static_cast<double>(size - 3));
    const int i = static_cast<int>(d);
    const double f = d - i, xm = at(i - 1), x0 = at(i), x1 = at(i + 1), x2 = at(i + 2);
    const double c1 = 0.5 * (x1 - xm), c2 = xm - 2.5 * x0 + 2 * x1 - 0.5 * x2, c3 = 0.5 * (x2 - xm) + 1.5 * (x0 - x1);
    return ((c3 * f + c2) * f + c1) * f + x0;
}

void Oversampler::design(double base) {
    // Analog Chebyshev I prototype poles, prewarped, bilinear-transformed one conjugate pair per section. Each
    // section has unity gain at DC, so the passband sits between 0 and +0.1 dB.
    constexpr int order = 8;
    const double fs = 4 * base, eps = std::sqrt(std::pow(10.0, 0.1 / 10) - 1), v = std::asinh(1 / eps) / order;
    const double k = 2 * fs, wc = k * std::tan(pi * 0.45 * base / fs);
    for (int i = 0; i < 4; ++i) {
        const double theta = pi * (2 * i + 1) / (2.0 * order);
        const double re = -wc * std::sinh(v) * std::sin(theta), im = wc * std::cosh(v) * std::cos(theta);
        const double m2 = re * re + im * im, a0 = k * k - 2 * re * k + m2;
        sec[i] = {m2 / a0, 2 * m2 / a0, m2 / a0, (2 * m2 - 2 * k * k) / a0, (k * k + 2 * re * k + m2) / a0};
    }
    clear();
}
void Oversampler::clear() DALNOK_NONBLOCKING {
    for (auto &c : up) for (auto &s : c) s[0] = s[1] = 0;
    for (auto &c : down) for (auto &s : c) s[0] = s[1] = 0;
}

// ---- Slot -------------------------------------------------------------------------------------------------------

void ModuleDsp::prepare(double rate) {
    rate_ = rate;
    // The largest layout is the stereo delay (2 x 2.05 s); every other module needs less.
    pool_.assign(static_cast<size_t>(2 * (2.05 * rate + 16)) + 64, 0.0f);
    os_.design(rate);
}

Line ModuleDsp::carve(double seconds) DALNOK_NONBLOCKING {
    Line l;
    const size_t n = std::min(static_cast<size_t>(seconds * rate_) + 8, pool_.size() - used_);
    l.b = pool_.data() + used_;
    l.size = static_cast<int>(n);
    used_ += n;
    return l;
}

void ModuleDsp::reset(int type) DALNOK_NONBLOCKING {
    std::fill(pool_.begin(), pool_.begin() + static_cast<std::ptrdiff_t>(used_), 0.0f);
    used_ = 0;
    os_.clear();
    for (auto &q : bq_) q = Biquad{};
    env_ = 0; gain_ = 1; hold_ = 0; open_ = 0; gr_ = 0; lfo_ = 0; lfo2_ = 0; inc_ = 0; time_ = 0;
    for (int c = 0; c < 2; ++c) { one_[c] = two_[c] = three_[c] = fb_[c] = inter_[c] = 0; }
    std::memset(ap_, 0, sizeof ap_);
    std::memset(adaa_, 0, sizeof adaa_);
    for (int i = 0; i < 8; ++i) { fdnLp_[i] = 0; fdnMod_[i] = 0; fdnGain_[i] = 0; }
    std::memset(c_, 0, sizeof c_);
    fresh_ = true;
    switch (type) {
    case Chorus: case Vibrato: line_[0] = carve(0.06); line_[1] = carve(0.06); break;
    case Flanger: line_[0] = carve(0.07); line_[1] = carve(0.07); break; // Manual 8 ms x the sweep's 8x = 64 ms
    case Cabinet: line_[0] = carve(0.01); line_[1] = carve(0.01); break;
    case Delay: line_[0] = carve(2.05); line_[1] = carve(2.05); break;
    case Spring: line_[0] = carve(0.06); line_[1] = carve(0.06); break;
    case Reverb:
        pre_ = carve(0.21);
        for (int j = 0; j < 4; ++j) diff_[j] = carve(diffMs[j] * maxScale * 0.001 + 0.001);
        for (int i = 0; i < 8; ++i) fdn_[i] = carve(fdnMs[i] * maxScale * 0.001 + 0.004);
        break;
    default: break;
    }
}

void ModuleDsp::flush() DALNOK_NONBLOCKING {
    for (auto &q : bq_) q.flush();
    for (int c = 0; c < 2; ++c) { tiny(one_[c]); tiny(two_[c]); tiny(three_[c]); tiny(fb_[c]); tiny(inter_[c]); }
    for (auto &c : ap_) for (auto &s : c) for (double &x : s) tiny(x);
    for (double &x : fdnLp_) tiny(x);
    for (auto &c : os_.up) for (auto &s : c) { tiny(s[0]); tiny(s[1]); }
    for (auto &c : os_.down) for (auto &s : c) { tiny(s[0]); tiny(s[1]); }
    tiny(env_); tiny(gr_);
}

namespace {
struct AmpVoice { double inHp, bright, g1lo, g1hi, g2lo, g2hi, interHp, midHz, midOffset, sat, sag, preMid; };
// Clean: one stage and a bright boost that fades as gain rises. Crunch and Lead: two stages with a coupling
// high-pass between them; Lead is tighter (higher high-passes) with a mid push before the gain.
constexpr AmpVoice voices[3] = {
    {70, 5, 0, 26, 0, 0, 20, 450, -3, 1.0, 0.10, 0},
    {100, 2, 8, 30, 0, 14, 180, 650, 0, 1.4, 0.20, 0},
    {150, 0, 16, 38, 8, 28, 320, 750, 1, 1.8, 0.25, 5},
};
double tube(double s) DALNOK_NONBLOCKING { return s >= 0 ? std::tanh(s) : 0.8 * std::tanh(1.25 * s); }
// Antiderivatives for first-order antiderivative anti-aliasing (ADAA): heavy clipping makes near-square waves whose
// highest harmonics would still fold back at 4x; ADAA suppresses them further.
double logcosh(double x) DALNOK_NONBLOCKING { const double a = std::abs(x); return a + std::log1p(std::exp(-2 * a)) - 0.6931471805599453; }
double tubeAnti(double s) DALNOK_NONBLOCKING { return s >= 0 ? logcosh(s) : 0.64 * logcosh(1.25 * s); }
double asym(double s) DALNOK_NONBLOCKING { return s >= 0 ? std::tanh(s) : 0.9 * std::tanh(s / 0.9); }
double asymAnti(double s) DALNOK_NONBLOCKING { return s >= 0 ? logcosh(s) : 0.81 * logcosh(s / 0.9); }
double clip(double s) DALNOK_NONBLOCKING { return std::clamp(s, -1.0, 1.0); }
double clipAnti(double s) DALNOK_NONBLOCKING { return std::abs(s) <= 1 ? 0.5 * s * s : std::abs(s) - 0.5; }
template <class F, class A> double adaa(double x, double *st, F f, A anti) DALNOK_NONBLOCKING {
    const double fx = anti(x), d = x - st[0];
    const double y = std::abs(d) > 1e-5 ? (fx - st[1]) / d : f(0.5 * (x + st[0]));
    st[0] = x; st[1] = fx;
    return y;
}
} // namespace

void ModuleDsp::update(int type, const double *v, int frames) DALNOK_NONBLOCKING {
    const double r = rate_;
    switch (type) {
    case Gate:
        c_[0] = db(v[0]); c_[1] = c_[0] * 0.5; c_[2] = timeCoef(v[1] * 0.001 / 5, r); c_[3] = -v[2];
        c_[4] = timeCoef(0.0005, r); c_[5] = timeCoef(0.03, r); c_[6] = 0.015 * r;
        break;
    case Compressor:
        c_[0] = v[0]; c_[1] = 1 - 1 / v[1]; c_[2] = timeCoef(v[2] * 0.001, r); c_[3] = timeCoef(v[3] * 0.001, r);
        c_[4] = db(v[4]); c_[5] = v[5] * 0.01; c_[6] = 6;
        break;
    case Boost:
        c_[0] = db(v[0]); c_[1] = db(v[2]);
        bq_[0].highShelf(1000, v[1] / 2, r); bq_[1].lowShelf(1000, -v[1] / 2, r);
        break;
    case Overdrive:
        c_[0] = db(4 + v[0] * 0.36); c_[1] = pole(720, r); c_[2] = pole(600 * std::pow(10.0, v[1] / 100), r);
        c_[3] = db(v[2]) * 0.5; c_[4] = v[3] * 0.01; c_[5] = pole(25, r);
        bq_[0].lowpass(6500, 0.707, r);
        break;
    case Distortion:
        c_[0] = db(10 + v[0] * 0.45); c_[1] = pole(160, r); c_[3] = db(v[2]) * 0.45; c_[4] = v[3] * 0.01; c_[5] = pole(25, r);
        bq_[0].peak(900, 0.8, 5, r); bq_[1].lowpass(1000 * std::pow(10.0, v[1] / 100), 0.707, r); bq_[2].lowpass(8000, 0.707, r);
        break;
    case Fuzz: {
        const double b = v[2] * 0.01;
        c_[0] = db(18 + v[0] * 0.4); c_[1] = 0.6 * b; c_[2] = 0.25 * b; c_[3] = db(v[3]) * 0.45; c_[4] = v[4] * 0.01;
        c_[5] = pole(25, r); c_[6] = v[1] * 0.01; c_[7] = pole(450, r); c_[8] = pole(1100, r);
        const double o = c_[1], g = c_[2];
        c_[9] = std::tanh(o > g ? o - g : o < -g ? o + g : 0);
        bq_[0].lowpass(7000, 0.707, r);
        break;
    }
    case AmpClean: case AmpCrunch: case AmpLead: {
        const AmpVoice &a = voices[type - AmpClean];
        const double g = v[0] * 0.01;
        c_[0] = db(a.g1lo + (a.g1hi - a.g1lo) * g); c_[1] = db(a.g2lo + (a.g2hi - a.g2lo) * g);
        c_[2] = 1 - std::exp(-2 * pi * a.interHp / (4 * r)); c_[3] = a.sat; c_[4] = a.sag; c_[5] = db(v[5]) * 0.55;
        c_[6] = pole(20, r); c_[7] = timeCoef(0.02, r); c_[8] = type == AmpClean ? 0 : 1;
        bq_[0].highpass(a.inHp, 0.707, r);
        bq_[1].highShelf(2500, a.bright * (1 - g), r);
        bq_[2].peak(800, 0.9, a.preMid, r);
        bq_[3].lowShelf(110, (v[1] - 5) * 2.4, r);
        bq_[4].peak(a.midHz, 0.7, (v[2] - 5) * 2.4 + a.midOffset, r);
        bq_[5].highShelf(2800, (v[3] - 5) * 2.4, r);
        bq_[6].highShelf(4500, (v[4] - 5) * 1.8, r);
        bq_[7].lowpass(9000, 0.707, r);
        break;
    }
    case Cabinet: {
        const int s = static_cast<int>(v[0]);
        const double m = v[1] * 0.01, dist = v[2] * 0.01;
        constexpr double resHz[] = {110, 95, 80}, resQ[] = {1.0, 1.1, 1.4}, lmHz[] = {200, 380, 140}, lmDb[] = {1.5, -2, 3};
        constexpr double boxHz[] = {900, 600, 480}, boxDb[] = {-3, -4, -5}, breakup[] = {6200, 5600, 5000};
        bq_[0].highpass(resHz[s], resQ[s], r);
        bq_[1].highpass(v[3], 0.707, r);
        bq_[2].peak(lmHz[s], 1.0, lmDb[s], r);
        bq_[3].peak(boxHz[s], 2.0, boxDb[s], r);
        bq_[4].peak(2600, 1.4, 5 - 9 * m, r);
        const double fc = std::min(v[4], breakup[s] * (1 - 0.45 * m));
        bq_[5].lowpass(fc, 0.9, r); bq_[6].lowpass(fc * 1.35, 0.6, r); bq_[8].lowpass(fc * 1.9, 0.7, r);
        bq_[7].lowShelf(180, (1 - 2 * dist) * 3, r);
        c_[0] = dist * 0.45; c_[1] = 0.0013 * r * (1 + 0.2 * s); c_[2] = 0.0021 * r * (1 + 0.2 * s); c_[3] = v[5] * 0.01;
        break;
    }
    case Eq:
        bq_[0].highpass(v[0], 0.707, r); bq_[1].lowShelf(120, v[1], r); bq_[2].peak(v[3], 0.9, v[2], r);
        bq_[3].highShelf(3200, v[4], r); bq_[4].lowpass(v[5], 0.707, r);
        break;
    case Wah: {
        c_[5] = timeCoef(0.002, r); c_[6] = timeCoef(0.15, r); c_[4] = v[4] * 0.01;
        double pos = v[0] * 0.01 + v[1] * 0.01 * std::min(1.0, env_ * 6);
        if (v[2] > 0.01) {
            pos += 0.45 * std::sin(lfo_);
            lfo_ = std::fmod(lfo_ + 2 * pi * v[2] * frames / r, 2 * pi);
        }
        pos = std::clamp(pos, 0.0, 1.0);
        const double f = 350 * std::pow(2400.0 / 350, pos), q = 1.5 + v[3] * 0.08;
        const double g = std::tan(pi * f / r), k = 1 / q;
        c_[0] = 1 / (1 + g * (g + k)); c_[1] = g * c_[0]; c_[2] = g * c_[1]; c_[3] = k;
        break;
    }
    case Chorus:
        inc_ = 2 * pi * v[0] / r; c_[0] = v[2] * 0.001 * r; c_[1] = v[1] * 0.01 * 0.004 * r; c_[2] = v[3] * 0.01 * pi / 2;
        c_[3] = v[4] * 0.01;
        break;
    case Vibrato: {
        const double a = v[1] * 0.01 * 0.0025 * r * std::min(1.0, 5 / v[0]);
        inc_ = 2 * pi * v[0] / r; c_[0] = a + 3; c_[1] = a; c_[2] = 0; c_[3] = v[2] * 0.01;
        break;
    }
    case Flanger:
        inc_ = 2 * pi * v[0] / r; c_[0] = v[2] * 0.001 * r; c_[1] = std::log(1 + 7 * v[1] * 0.01); c_[2] = v[3] * 0.01;
        c_[3] = v[4] * 0.01 * pi; c_[4] = v[5] * 0.01;
        break;
    case Phaser: {
        c_[0] = stageTable[std::clamp(static_cast<int>(v[2]), 0, 3)]; c_[1] = v[3] * 0.01; c_[2] = v[5] * 0.01;
        const double depth = v[1] * 0.01, width = v[4] * 0.01 * pi;
        for (int c = 0; c < 2; ++c) {
            const double f = 200 * std::pow(16.0, 0.5 + 0.5 * depth * std::sin(lfo_ + c * width));
            const double t = std::tan(pi * std::min(f, 0.45 * r) / r);
            c_[3 + c] = (t - 1) / (t + 1);
        }
        lfo_ = std::fmod(lfo_ + 2 * pi * v[0] * frames / r, 2 * pi);
        break;
    }
    case Tremolo:
        inc_ = 2 * pi * v[0] / r; c_[0] = v[1] * 0.01; c_[1] = v[2] * 0.01; c_[2] = std::tanh(12.0); c_[3] = v[3] * 0.01 * pi;
        break;
    case Delay:
        c_[0] = std::clamp(v[0] * 0.001 * r, 4.0, line_[0].size - 8.0); c_[1] = v[1] * 0.01; c_[2] = pole(v[2], r);
        c_[3] = pole(60, r); c_[4] = v[3] * 0.01 * 0.0015 * r; c_[5] = v[4] * 0.01; wetLaw(v[5] * 0.01, c_[6], c_[7]);
        c_[8] = timeCoef(0.12, r);
        if (fresh_) time_ = c_[0];
        break;
    case Reverb: {
        const double scale = 0.35 + 1.05 * v[1] * 0.01;
        c_[0] = std::max(1.0, v[2] * 0.001 * r); wetLaw(v[5] * 0.01, c_[1], c_[2]); c_[3] = pole(v[3], r); c_[4] = pole(90, r);
        for (int j = 0; j < 4; ++j) c_[10 + j] = std::min(diffMs[j] * scale * 0.001 * r, diff_[j].size - 2.0);
        const double modDepth = v[4] * 0.01 * 0.0012 * r;
        constexpr double modHz[8] = {0.31, 0, 0, 0.47, 0, 0.73, 0, 0.19};
        for (int i = 0; i < 8; ++i) {
            const double target = std::min(fdnMs[i] * scale * 0.001 * r, fdn_[i].size - 0.003 * r);
            fdnLen_[i] = fresh_ ? target : fdnLen_[i] + 0.05 * (target - fdnLen_[i]);
            fdnGain_[i] = std::pow(10.0, -3 * fdnLen_[i] / (r * v[0]));
            fdnMod_[i] = modHz[i] > 0 ? modDepth * (1 + std::sin(lfo_ * modHz[i] + i)) : 0;
        }
        lfo_ = std::fmod(lfo_ + 2 * pi * frames / r, 2 * pi * 100);
        break;
    }
    case Spring: {
        c_[0] = 0.033 * r; c_[1] = 0.0415 * r;
        c_[2] = std::pow(10.0, -3 * c_[0] / (r * v[0])); c_[3] = std::pow(10.0, -3 * c_[1] / (r * v[0]));
        c_[4] = pole(v[1], r); c_[5] = pole(3500, r); c_[6] = -(0.45 + 0.4 * v[2] * 0.01);
        wetLaw(v[3] * 0.01, c_[7], c_[8]); c_[9] = pole(250, r);
        break;
    }
    default: break;
    }
    fresh_ = false;
}

void ModuleDsp::process(int type, double &l, double &r) DALNOK_NONBLOCKING {
    switch (type) {
    case Gate: {
        const double p = std::max(std::abs(l), std::abs(r));
        env_ = p > env_ ? p : env_ + c_[5] * (p - env_);
        if (env_ > c_[0]) { open_ = 1; hold_ = c_[6]; }
        else if (env_ < c_[1]) { if (hold_ > 0) hold_ -= 1; else open_ = 0; }
        // The gain moves in decibels, so the release sets how long the gate takes to close over its whole range.
        const double target = open_ > 0 ? 0 : c_[3];
        gr_ += (target > gr_ ? c_[4] : c_[2]) * (target - gr_);
        const double g = db(gr_);
        l *= g; r *= g;
        break;
    }
    case Compressor: {
        const double level = 20 * std::log10(std::max(std::abs(l), std::abs(r)) + 1e-9), over = level - c_[0], knee = c_[6];
        const double want = over <= -knee / 2 ? 0 : over < knee / 2 ? c_[1] * (over + knee / 2) * (over + knee / 2) / (2 * knee) : c_[1] * over;
        gr_ += (want > gr_ ? c_[2] : c_[3]) * (want - gr_);
        const double g = db(-gr_) * c_[4], m = c_[5];
        l *= 1 - m + m * g; r *= 1 - m + m * g;
        break;
    }
    case Boost:
        l = bq_[1].run(0, bq_[0].run(0, l * c_[0])) * c_[1];
        r = bq_[1].run(1, bq_[0].run(1, r * c_[0])) * c_[1];
        break;
    case Overdrive: case Distortion: case Fuzz: processDrive(type, l, r); break;
    case AmpClean: case AmpCrunch: case AmpLead: processAmp(type, l, r); break;
    case Cabinet: {
        double io[2] = {l, r};
        for (int c = 0; c < 2; ++c) {
            double y = io[c];
            for (int i : {0, 1, 7, 2, 3, 4, 5, 6, 8}) y = bq_[i].run(c, y);
            const double e = line_[c].at(static_cast<int>(c ? c_[2] : c_[1]));
            line_[c].push(y);
            y += c_[0] * e;
            io[c] += c_[3] * (y - io[c]);
        }
        l = io[0]; r = io[1];
        break;
    }
    case Eq: {
        double io[2] = {l, r};
        for (int c = 0; c < 2; ++c) for (int i = 0; i < 5; ++i) io[c] = bq_[i].run(c, io[c]);
        l = io[0]; r = io[1];
        break;
    }
    case Wah: {
        const double p = std::max(std::abs(l), std::abs(r));
        env_ += (p > env_ ? c_[5] : c_[6]) * (p - env_);
        double io[2] = {l, r};
        for (int c = 0; c < 2; ++c) {
            const double v3 = io[c] - two_[c], v1 = c_[0] * one_[c] + c_[1] * v3, v2 = two_[c] + c_[1] * one_[c] + c_[2] * v3;
            one_[c] = 2 * v1 - one_[c]; two_[c] = 2 * v2 - two_[c];
            const double y = c_[3] * v1 * 2.2 + v2 * 0.15;
            io[c] += c_[4] * (y - io[c]);
        }
        l = io[0]; r = io[1];
        break;
    }
    case Chorus: case Vibrato: {
        double io[2] = {l, r};
        const int voicesN = type == Chorus ? 2 : 1;
        for (int c = 0; c < 2; ++c) {
            double wet = 0;
            for (int v = 0; v < voicesN; ++v)
                wet += line_[c].cubic(c_[0] + c_[1] * (0.5 + 0.5 * std::sin(lfo_ + v * pi + c * c_[2]))) / voicesN;
            line_[c].push(io[c]);
            io[c] += c_[3] * (wet - io[c]);
        }
        l = io[0]; r = io[1];
        lfo_ += inc_; if (lfo_ >= 2 * pi) lfo_ -= 2 * pi;
        break;
    }
    case Flanger: {
        double io[2] = {l, r};
        for (int c = 0; c < 2; ++c) {
            const double sweep = 0.5 + 0.5 * std::sin(lfo_ + c * c_[3]);
            const double y = line_[c].cubic(c_[0] * std::exp(c_[1] * sweep));
            line_[c].push(io[c] + c_[2] * std::tanh(fb_[c]));
            fb_[c] = y;
            io[c] += c_[4] * (y - io[c]);
        }
        l = io[0]; r = io[1];
        lfo_ += inc_; if (lfo_ >= 2 * pi) lfo_ -= 2 * pi;
        break;
    }
    case Phaser: {
        double io[2] = {l, r};
        const int n = static_cast<int>(c_[0]);
        for (int c = 0; c < 2; ++c) {
            const double a = c_[3 + c];
            double u = io[c] + c_[1] * fb_[c];
            for (int i = 0; i < n; ++i) {
                const double y = a * u + ap_[c][i][0];
                ap_[c][i][0] = u - a * y;
                u = y;
            }
            fb_[c] = u;
            io[c] += c_[2] * (u - io[c]);
        }
        l = io[0]; r = io[1];
        break;
    }
    case Tremolo: {
        double io[2] = {l, r};
        for (int c = 0; c < 2; ++c) {
            const double s = std::sin(lfo_ + c * c_[3]);
            const double w = s + c_[1] * (std::tanh(12 * s) / c_[2] - s);
            io[c] *= 1 - c_[0] * (0.5 - 0.5 * w);
        }
        l = io[0]; r = io[1];
        lfo_ += inc_; if (lfo_ >= 2 * pi) lfo_ -= 2 * pi;
        break;
    }
    case Delay: {
        time_ += c_[8] * (c_[0] - time_);
        const double wow = c_[4] * (0.7 * std::sin(lfo_) + 0.3 * std::sin(lfo2_));
        lfo_ += 2 * pi * 0.55 / rate_; lfo2_ += 2 * pi * 2.3 / rate_;
        if (lfo_ >= 2 * pi) lfo_ -= 2 * pi;
        if (lfo2_ >= 2 * pi) lfo2_ -= 2 * pi;
        const double y[2] = {line_[0].cubic(time_ + wow), line_[1].cubic(time_ + wow)};
        double f[2];
        for (int c = 0; c < 2; ++c) {
            one_[c] += c_[2] * (y[c] - one_[c]);   // tone: high frequencies fade with each repeat
            two_[c] += c_[3] * (one_[c] - two_[c]); // and the lows stay tight
            f[c] = c_[1] * (one_[c] - two_[c]);
        }
        const double pp = c_[5], mono = 0.5 * (l + r);
        // The input goes in clean; only the repeats saturate (gently), which keeps high feedback bounded.
        line_[0].push((1 - pp) * l + pp * mono + std::tanh((1 - pp) * f[0] + pp * f[1]));
        line_[1].push((1 - pp) * r + std::tanh((1 - pp) * f[1] + pp * f[0]));
        l = l * c_[6] + y[0] * c_[7];
        r = r * c_[6] + y[1] * c_[7];
        break;
    }
    case Reverb: processReverb(l, r); break;
    case Spring: processSpring(l, r); break;
    default: break;
    }
}

void ModuleDsp::processDrive(int type, double &l, double &r) DALNOK_NONBLOCKING {
    double io[2] = {l, r};
    for (int c = 0; c < 2; ++c) {
        const double x = io[c];
        double y;
        if (type == Overdrive) {
            // The low end stays clean (summed back in), the rest is driven: a mid-forward overdrive.
            one_[c] += c_[1] * (x - one_[c]);
            double *st = adaa_[c][0];
            const double driven = os_.run(c, (x - one_[c]) * c_[0], [st](double s) DALNOK_NONBLOCKING { return adaa(s, st, asym, asymAnti); });
            y = driven + 0.25 * one_[c];
            two_[c] += c_[2] * (y - two_[c]);
            y = bq_[0].run(c, two_[c]);
        } else if (type == Distortion) {
            one_[c] += c_[1] * (x - one_[c]);
            const double pre = bq_[0].run(c, x - one_[c]) * c_[0];
            double *st = adaa_[c][0];
            y = os_.run(c, pre, [st](double s) DALNOK_NONBLOCKING { return adaa(s, st, clip, clipAnti); });
            y = bq_[2].run(c, bq_[1].run(c, y));
        } else {
            const double off = c_[1], g = c_[2], comp = c_[9];
            double *st = adaa_[c][0];
            const auto dead = [off, g](double s) DALNOK_NONBLOCKING { const double u = s + off; return u > g ? u - g : u < -g ? u + g : 0.0; };
            y = os_.run(c, x * c_[0], [&](double s) DALNOK_NONBLOCKING {
                return adaa(s, st, [&](double v) DALNOK_NONBLOCKING { return std::tanh(dead(v)) - comp; },
                            [&](double v) DALNOK_NONBLOCKING { return logcosh(dead(v)) - comp * v; });
            });
            two_[c] += c_[7] * (y - two_[c]);
            const double low = two_[c];
            three_[c] += c_[8] * (y - three_[c]);
            const double high = y - three_[c];
            y = bq_[0].run(c, (1 - c_[6]) * low + c_[6] * high * 1.4);
        }
        inter_[c] += c_[5] * (y - inter_[c]); // DC from asymmetric clipping
        y = (y - inter_[c]) * c_[3];
        io[c] += c_[4] * (y - io[c]);
    }
    l = io[0]; r = io[1];
}

void ModuleDsp::processAmp(int type, double &l, double &r) DALNOK_NONBLOCKING {
    const double p = std::max(std::abs(l), std::abs(r));
    double io[2] = {l, r};
    for (int c = 0; c < 2; ++c) {
        double x = bq_[2].run(c, bq_[1].run(c, bq_[0].run(c, io[c])));
        const bool two = c_[8] > 0;
        const double g2 = c_[1], ia = c_[2];
        double &inter = inter_[c];
        double *s1 = adaa_[c][0], *s2 = adaa_[c][1];
        double y = os_.run(c, x * c_[0], [two, g2, ia, &inter, s1, s2](double s) DALNOK_NONBLOCKING {
            double u = adaa(s, s1, tube, tubeAnti);
            if (two) {
                inter += ia * (u - inter);
                u = adaa((u - inter) * g2, s2, tube, tubeAnti);
            }
            return u;
        });
        one_[c] += c_[6] * (y - one_[c]);
        y -= one_[c];
        for (int i = 3; i <= 6; ++i) y = bq_[i].run(c, y);
        // Power stage: a softer limit whose drive sags a little with the program level.
        const double sat = c_[3] / (1 + c_[4] * env_);
        y = std::tanh(y * sat) / c_[3];
        io[c] = bq_[7].run(c, y) * c_[5];
    }
    env_ += c_[7] * (p - env_);
    (void)type;
    l = io[0]; r = io[1];
}

void ModuleDsp::processReverb(double &l, double &r) DALNOK_NONBLOCKING {
    double in = 0.5 * (l + r);
    one_[0] += c_[4] * (in - one_[0]);
    in -= one_[0];
    const double pre = pre_.linear(c_[0]);
    pre_.push(in);
    double x = pre;
    for (int j = 0; j < 4; ++j) { // Schroeder all-passes smear the attack before the network
        const double g = j < 2 ? 0.7 : 0.6, d = diff_[j].linear(c_[10 + j]), w = x - g * d;
        diff_[j].push(w);
        x = d + g * w;
    }
    double h[8];
    for (int i = 0; i < 8; ++i) {
        const double o = fdn_[i].linear(fdnLen_[i] + fdnMod_[i]);
        fdnLp_[i] += c_[3] * (o - fdnLp_[i]);
        h[i] = fdnLp_[i] * fdnGain_[i];
    }
    for (int len = 1; len < 8; len <<= 1) // fast Walsh-Hadamard: an orthogonal, lossless mix of the eight lines
        for (int i = 0; i < 8; i += 2 * len)
            for (int j = i; j < i + len; ++j) { const double a = h[j], b = h[j + len]; h[j] = a + b; h[j + len] = a - b; }
    const double norm = 1 / std::sqrt(8.0);
    for (int i = 0; i < 8; ++i) fdn_[i].push(h[i] * norm + x * (i & 1 ? -0.35 : 0.35));
    const double wl = 0.45 * (fdnLp_[0] - fdnLp_[3] + fdnLp_[5] + fdnLp_[6]);
    const double wr = 0.45 * (fdnLp_[1] + fdnLp_[2] - fdnLp_[4] + fdnLp_[7]);
    l = l * c_[1] + wl * c_[2];
    r = r * c_[1] + wr * c_[2];
}

void ModuleDsp::processSpring(double &l, double &r) DALNOK_NONBLOCKING {
    two_[0] += c_[4] * (0.5 * (l + r) - two_[0]);
    const double in = two_[0], a = c_[6];
    double wet[2];
    for (int c = 0; c < 2; ++c) {
        const double o = line_[c].at(static_cast<int>(c_[c]));
        one_[c] += c_[5] * (o - one_[c]);
        // Stretched all-passes (two-sample delay) disperse the loop: high frequencies arrive first, the drip.
        double u = in + c_[2 + c] * one_[c];
        for (int i = 0; i < 12; ++i) {
            double *s = ap_[c][i]; // x1, x2, y1, y2
            const double y = a * u + s[1] - a * s[3];
            s[1] = s[0]; s[0] = u; s[3] = s[2]; s[2] = y;
            u = y;
        }
        line_[c].push(u);
        three_[c] += c_[9] * (o - three_[c]);
        wet[c] = (o - three_[c]) * 0.8;
    }
    l = l * c_[7] + wet[0] * c_[8];
    r = r * c_[7] + wet[1] * c_[8];
}

} // namespace dalnok::fx::guitar
