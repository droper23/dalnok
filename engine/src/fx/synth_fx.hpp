// Dalnok Synth: the stock subtractive instrument with controls (Logic's Retro Synth / ES2, Ableton's Analog / Drift
// cover the same ground). Two oscillators (saw, square, triangle or sine; the second detuned), a sine sub an octave
// down, a resonant low-pass with its own decay envelope, an ADSR, glide, a pitch envelope (808s and kicks), poly or
// mono, velocity, pitch bend (±2 semitones) and the sustain pedal. Dalnok's own design.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "fx/builtin.hpp"

#include <array>

namespace dalnok::fx {

class Synth final : public BuiltinProcessor {
public:
    explicit Synth(double sampleRate);
    bool instrument() const override { return true; }
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    enum : uint32_t {
        kWave = 0, kDetune, kSub, kCutoff, kResonance, kFilterEnv, kAttack, kDecay, kSustain, kRelease, kFilterDecay,
        kGlide, kPitchEnv, kPitchDecay, kLevel, kVoices, kVelocity,
    };
    static constexpr int kMaxVoices = 16;

private:
    struct Voice {
        bool active = false, held = false, releasing = false;
        uint8_t note = 0;
        float velocity = 0;
        double p1 = 0, p2 = 0, ps = 0;   // oscillator phases (0-1)
        double hz = 440, targetHz = 440; // glides from hz to targetHz
        double env = 0, fenv = 0, penv = 0;
        int stage = 0;                   // 0 attack, 1 decay, 2 sustain, 3 release
        double ic1 = 0, ic2 = 0;         // filter state
        uint64_t age = 0;
    };
    void changed() DALNOK_NONBLOCKING override;
    void noteOn(uint8_t note, uint8_t velocity) DALNOK_NONBLOCKING;
    void noteOff(uint8_t note) DALNOK_NONBLOCKING;
    double sampleRate_;
    std::array<Voice, kMaxVoices> voices_{};
    uint64_t age_ = 0;
    double lastHz_ = 0;
    bool pedal_ = false;
    double bend_ = 1;
    // From the parameters.
    int wave_ = 0;
    bool mono_ = false;
    double detune_ = 1, sub_ = 0, cutoff_ = 4000, k_ = 1.1, fenvAmt_ = 0, attack_ = 0, decay_ = 0, sustain_ = 0.7,
           release_ = 0, fdecay_ = 0, glide_ = 0, penvAmt_ = 0, pdecay_ = 0, level_ = 0.5, velAmt_ = 0.7;
};

} // namespace dalnok::fx
