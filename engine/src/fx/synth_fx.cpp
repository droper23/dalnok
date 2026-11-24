// Dalnok Synth (see synth_fx.hpp).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/synth_fx.hpp"

#include <algorithm>
#include <cmath>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects" // libm (exp, exp2, sin, tan) neither allocates nor locks

namespace dalnok::fx {
namespace {
constexpr double kPi = 3.14159265358979323846;
using P = BuiltinProcessor::Param;
const char *const kWaves[] = {"Saw", "Square", "Triangle", "Sine"};
const char *const kModes[] = {"Poly", "Mono"};

const std::vector<P> &synthParams() {
    static const std::vector<P> params = {
        {Synth::kWave, "Wave", "", 0, 3, 0, P::Choice, kWaves},
        {Synth::kDetune, "Detune", "ct", 0, 50, 8, P::Linear},
        {Synth::kSub, "Sub", "%", 0, 100, 0, P::Linear},
        {Synth::kCutoff, "Cutoff", "Hz", 20, 20000, 3000, P::Log},
        {Synth::kResonance, "Resonance", "", 0.5, 15, 0.9, P::Log},
        {Synth::kFilterEnv, "Filter Env", "%", 0, 100, 30, P::Linear},
        {Synth::kAttack, "Attack", "ms", 0.5, 5000, 3, P::Log},
        {Synth::kDecay, "Decay", "ms", 1, 5000, 300, P::Log},
        {Synth::kSustain, "Sustain", "%", 0, 100, 70, P::Linear},
        {Synth::kRelease, "Release", "ms", 1, 10000, 200, P::Log},
        {Synth::kFilterDecay, "Filter Decay", "ms", 1, 5000, 400, P::Log},
        {Synth::kGlide, "Glide", "ms", 0, 2000, 0, P::Linear},
        {Synth::kPitchEnv, "Pitch Env", "st", 0, 48, 0, P::Linear},
        {Synth::kPitchDecay, "Pitch Decay", "ms", 1, 2000, 60, P::Log},
        {Synth::kLevel, "Level", "dB", -60, 12, -6, P::Linear},
        {Synth::kVoices, "Voices", "", 0, 1, 0, P::Choice, kModes},
        {Synth::kVelocity, "Velocity", "%", 0, 100, 70, P::Linear},
    };
    return params;
}
double polyBlep(double t, double dt) {
    if (t < dt) { const double x = t / dt; return x + x - x * x - 1; }
    if (t > 1 - dt) { const double x = (t - 1) / dt; return x * x + x + x + 1; }
    return 0;
}
double osc(int wave, double phase, double dt) {
    switch (wave) {
    case 1: { // square: two saws
        double v = phase < 0.5 ? 1.0 : -1.0;
        v += polyBlep(phase, dt);
        double t2 = phase + 0.5; if (t2 >= 1) t2 -= 1;
        return v - polyBlep(t2, dt);
    }
    case 2: return 4 * std::fabs(phase - 0.5) - 1; // triangle (soft enough without band-limiting at these levels)
    case 3: return std::sin(2 * kPi * phase);
    default: return 2 * phase - 1 - polyBlep(phase, dt); // saw
    }
}
} // namespace

Synth::Synth(double sampleRate) : BuiltinProcessor("synth", "Dalnok Synth", synthParams()), sampleRate_(sampleRate) {}

void Synth::changed() DALNOK_NONBLOCKING {
    auto perSample = [&](double ms) { return 1.0 / std::max(1.0, ms * 1e-3 * sampleRate_); };
    auto falloff = [&](double ms) { return std::exp(-1.0 / std::max(1.0, ms * 1e-3 * sampleRate_)); };
    wave_ = static_cast<int>(std::lround(rt(kWave)));
    detune_ = std::exp2(rt(kDetune) / 1200);
    sub_ = rt(kSub) / 100;
    cutoff_ = rt(kCutoff);
    k_ = 1 / std::max(0.5, rt(kResonance));
    fenvAmt_ = rt(kFilterEnv) / 100 * 5; // up to five octaves above the cutoff
    attack_ = perSample(rt(kAttack));
    // Decay and release times are to -60 dB (a time constant of ms / 6.9); so is the filter decay.
    decay_ = falloff(rt(kDecay) / 6.9);
    sustain_ = rt(kSustain) / 100;
    release_ = falloff(rt(kRelease) / 6.9);
    fdecay_ = falloff(rt(kFilterDecay) / 6.9);
    glide_ = rt(kGlide) < 0.5 ? 0.0 : falloff(rt(kGlide) / 4); // how much of the way is left each sample (0: no glide)
    penvAmt_ = rt(kPitchEnv);
    pdecay_ = falloff(rt(kPitchDecay));
    level_ = rt(kLevel) <= -60 ? 0 : std::pow(10.0, rt(kLevel) / 20) * 0.5; // a voice at full level is -6 dBFS
    mono_ = rt(kVoices) >= 0.5;
    velAmt_ = rt(kVelocity) / 100;
}

void Synth::noteOn(uint8_t note, uint8_t velocity) DALNOK_NONBLOCKING {
    const double hz = 440.0 * std::exp2((note - 69) / 12.0);
    Voice *v = nullptr;
    if (mono_) {
        v = &voices_[0];
        for (size_t i = 1; i < voices_.size(); ++i) voices_[i].active = false;
        const bool legato = v->active && v->held;
        if (!legato) { v->env = v->active ? v->env : 0; v->stage = 0; v->fenv = 1; v->penv = 1; }
        v->hz = v->active && glide_ > 0 ? v->hz : (glide_ > 0 && lastHz_ > 0 ? lastHz_ : hz);
    } else {
        for (auto &x : voices_) if (!x.active) { v = &x; break; }
        if (!v) { v = &voices_[0]; for (auto &x : voices_) if (x.age < v->age) v = &x; }
        *v = Voice{};
        v->hz = glide_ > 0 && lastHz_ > 0 ? lastHz_ : hz;
        v->fenv = 1;
        v->penv = 1;
    }
    v->active = true;
    v->held = true;
    v->releasing = false;
    v->note = note;
    v->velocity = static_cast<float>(1 - velAmt_ + velAmt_ * velocity / 127.0);
    v->targetHz = hz;
    v->age = ++age_;
    lastHz_ = hz;
}

void Synth::noteOff(uint8_t note) DALNOK_NONBLOCKING {
    for (auto &v : voices_)
        if (v.active && v.held && v.note == note) {
            v.held = false;
            if (!pedal_) { v.releasing = true; v.stage = 3; }
        }
}

void Synth::process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING {
    applyPending();
    int next = 0;
    for (int i = 0; i < frames; ++i) {
        for (; next < noteCount && notes[next].offset <= i; ++next) {
            const PluginNote &e = notes[next];
            if (e.on == kEventNoteOn) noteOn(e.pitch, e.velocity);
            else if (e.on == kEventNoteOff) noteOff(e.pitch);
            else if (e.on == kEventPitchBend) bend_ = std::exp2(((e.pitch | e.velocity << 7) - 8192) / 8192.0 * 2 / 12);
            else if (e.on == kEventControl && e.pitch == 64) {
                pedal_ = e.velocity >= 64;
                if (!pedal_) for (auto &v : voices_) if (v.active && !v.held) { v.releasing = true; v.stage = 3; }
            } else if (e.on == kEventControl && (e.pitch == 120 || e.pitch == 123)) {
                for (auto &v : voices_) if (v.active) { v.releasing = true; v.stage = 3; }
            }
        }
        double out = 0;
        for (auto &v : voices_) {
            if (!v.active) continue;
            // Envelopes.
            switch (v.stage) {
            case 0: v.env += attack_; if (v.env >= 1) { v.env = 1; v.stage = 1; } break;
            case 1: v.env = sustain_ + (v.env - sustain_) * decay_; if (v.env - sustain_ < 1e-4) v.stage = 2; break;
            case 2: v.env = sustain_; break;
            default: v.env *= release_; if (v.env < 1e-5) { v.active = false; continue; } break;
            }
            v.fenv *= fdecay_;
            v.penv *= pdecay_;
            v.hz = v.targetHz + (v.hz - v.targetHz) * glide_; // glide: an exponential approach to the note's pitch
            const double hz = v.hz * bend_ * std::exp2(penvAmt_ * v.penv / 12);
            const double dt1 = std::min(0.45, hz / sampleRate_), dt2 = std::min(0.45, hz * detune_ / sampleRate_);
            double s = osc(wave_, v.p1, dt1);
            if (detune_ > 1.0000001) s = 0.5 * (s + osc(wave_, v.p2, dt2));
            s += sub_ * std::sin(2 * kPi * v.ps);
            v.p1 += dt1; if (v.p1 >= 1) v.p1 -= 1;
            v.p2 += dt2; if (v.p2 >= 1) v.p2 -= 1;
            v.ps += dt1 * 0.5; if (v.ps >= 1) v.ps -= 1;
            // Low-pass (state variable), its cutoff opened by the filter envelope.
            const double fc = std::min(cutoff_ * std::exp2(fenvAmt_ * v.fenv), sampleRate_ * 0.45);
            const double g = std::tan(kPi * fc / sampleRate_), a1 = 1 / (1 + g * (g + k_)), a2 = g * a1, a3 = g * a2;
            const double v3 = s - v.ic2, v1 = a1 * v.ic1 + a2 * v3, v2 = v.ic2 + a2 * v.ic1 + a3 * v3;
            v.ic1 = 2 * v1 - v.ic1;
            v.ic2 = 2 * v2 - v.ic2;
            out += v2 * v.env * v.velocity;
        }
        left[i] = right[i] = static_cast<float>(out * level_);
    }
}

} // namespace dalnok::fx

#pragma clang diagnostic pop
