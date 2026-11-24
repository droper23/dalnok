// Dalnok Poly: the first stock instrument. A small polyphonic subtractive synth
// (band-limited saw, two-pole low-pass, linear ADSR) that runs on the audio
// thread. All coefficients are computed on the control thread (SynthParams).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "rt.hpp"

#include <array>
#include <cmath>
#include <cstdint>

namespace dalnok {

constexpr int kSynthVoices = 16;

// Precomputed per sample rate (control thread; uses libm).
struct SynthParams {
    float attackStep = 0, decayStep = 0, sustain = 0.6f, releaseStep = 0;
    float lowpass = 0;   // one-pole coefficient (applied twice)
    float level = 0.2f;  // per-voice output level at full velocity
    std::array<float, 128> increment{}; // cycles per sample for each MIDI note

    static SynthParams make(double sampleRate) {
        SynthParams p;
        const auto sr = static_cast<float>(sampleRate);
        p.attackStep = 1.0f / (0.004f * sr);
        p.decayStep = (1.0f - p.sustain) / (0.25f * sr);
        p.releaseStep = 1.0f / (0.18f * sr); // from full level; scaled by the level at release
        p.lowpass = 1.0f - std::exp(-2.0f * 3.14159265f * 5000.0f / sr);
        for (int n = 0; n < 128; ++n)
            p.increment[static_cast<size_t>(n)] =
                static_cast<float>(440.0 * std::pow(2.0, (n - 69) / 12.0) / sampleRate);
        return p;
    }
};

struct SynthVoice {
    enum Stage : uint8_t { idle, attack, decay, sustain, release };
    Stage stage = idle;
    uint8_t note = 0;
    float velocity = 0, env = 0, releaseStep = 0, phase = 0, inc = 0, lp1 = 0, lp2 = 0;
    int64_t endFrame = -1; // timeline frame of the note-off (timeline voices), -1 = held
    uint64_t age = 0;
    bool sustained = false; // released while the sustain pedal was down: sounds until the pedal comes up
};

// Voice state. Live playback, live input, and each offline render own separate instances.
struct SynthState {
    std::array<SynthVoice, kSynthVoices> voices{};
    uint64_t counter = 0;
    int64_t expected = -1; // next timeline frame; any other position means a seek
    // Plugin instruments: notes this render has started and not yet ended, per pitch.
    std::array<uint8_t, 128> pluginHeld{};
    int64_t pluginExpected = -1;
    uint64_t mutedMidiSignature = 0;
    float bend = 1.0f;     // pitch-bend frequency ratio (±2 semitones)
    bool pedal = false;    // sustain pedal (CC 64 >= 64)

    void reset() DALNOK_NONBLOCKING {
        for (auto &v : voices) v = SynthVoice{};
        expected = -1;
        bend = 1.0f;
        pedal = false;
    }
    // Pitch bend, 0-16383 (8192 = none), over ±2 semitones.
    void pitchBend(int value) DALNOK_NONBLOCKING {
        bend = __builtin_exp2f(static_cast<float>(value - 8192) / 8192.0f * 2.0f / 12.0f);
    }
    // Control change: 64 sustain (pedal up releases what it held), 120/123 all sound/notes off.
    void control(const SynthParams &p, uint8_t cc, uint8_t value) DALNOK_NONBLOCKING {
        if (cc == 64) {
            const bool down = value >= 64;
            if (pedal && !down)
                for (auto &v : voices)
                    if (v.sustained) { v.sustained = false; release(p, v); }
            pedal = down;
        } else if (cc == 120 || cc == 123) {
            for (auto &v : voices) if (v.stage != SynthVoice::idle) release(p, v);
        }
    }
    bool active() const DALNOK_NONBLOCKING {
        for (const auto &v : voices)
            if (v.stage != SynthVoice::idle) return true;
        return false;
    }
    void noteOn(const SynthParams &p, uint8_t note, uint8_t velocity, int64_t endFrame) DALNOK_NONBLOCKING {
        SynthVoice *slot = nullptr;
        for (auto &v : voices) // retrigger the same held note in place
            if (v.stage != SynthVoice::idle && v.note == note && v.stage != SynthVoice::release) { slot = &v; break; }
        if (!slot)
            for (auto &v : voices)
                if (v.stage == SynthVoice::idle) { slot = &v; break; }
        if (!slot) { // steal the oldest voice
            slot = &voices[0];
            for (auto &v : voices)
                if (v.age < slot->age) slot = &v;
        }
        const bool fresh = slot->stage == SynthVoice::idle;
        slot->stage = SynthVoice::attack;
        slot->note = note & 0x7f;
        slot->velocity = static_cast<float>(velocity & 0x7f) / 127.0f;
        slot->inc = p.increment[slot->note];
        slot->endFrame = endFrame;
        slot->age = ++counter;
        slot->sustained = false;
        if (fresh) { slot->env = 0; slot->phase = 0; slot->lp1 = slot->lp2 = 0; }
    }
    void noteOff(const SynthParams &p, uint8_t note) DALNOK_NONBLOCKING {
        for (auto &v : voices)
            if (v.stage != SynthVoice::idle && v.stage != SynthVoice::release && v.note == (note & 0x7f) &&
                v.endFrame < 0 && !v.sustained) {
                if (pedal) v.sustained = true;
                else release(p, v);
            }
    }
    static void release(const SynthParams &p, SynthVoice &v) DALNOK_NONBLOCKING {
        v.stage = SynthVoice::release;
        v.releaseStep = p.releaseStep * (v.env > 0.05f ? v.env : 0.05f);
    }

    // Adds `frames` of output to out (mono). `pos` is the timeline frame of the
    // first sample (used for timeline note-offs; pass -1 for live input).
    void render(const SynthParams &p, float *out, int frames, int64_t pos) DALNOK_NONBLOCKING {
        for (auto &v : voices) {
            if (v.stage == SynthVoice::idle) continue;
            for (int i = 0; i < frames; ++i) {
                if (v.endFrame >= 0 && pos >= 0 && pos + i >= v.endFrame && v.stage != SynthVoice::release) {
                    if (pedal) v.sustained = true;
                    else release(p, v);
                    v.endFrame = -1;
                }
                switch (v.stage) {
                case SynthVoice::attack:
                    v.env += p.attackStep;
                    if (v.env >= 1.0f) { v.env = 1.0f; v.stage = SynthVoice::decay; }
                    break;
                case SynthVoice::decay:
                    v.env -= p.decayStep;
                    if (v.env <= p.sustain) { v.env = p.sustain; v.stage = SynthVoice::sustain; }
                    break;
                case SynthVoice::release:
                    v.env -= v.releaseStep;
                    if (v.env <= 0.0f) { v.env = 0.0f; v.stage = SynthVoice::idle; }
                    break;
                default: break;
                }
                if (v.stage == SynthVoice::idle) break;
                // PolyBLEP saw.
                float saw = 2.0f * v.phase - 1.0f;
                const float t = v.phase, dt = v.inc * bend;
                if (t < dt) { const float x = t / dt; saw -= x + x - x * x - 1.0f; }
                else if (t > 1.0f - dt) { const float x = (t - 1.0f) / dt; saw -= x * x + x + x + 1.0f; }
                v.phase += v.inc * bend;
                if (v.phase >= 1.0f) v.phase -= 1.0f;
                v.lp1 += p.lowpass * (saw - v.lp1);
                v.lp2 += p.lowpass * (v.lp1 - v.lp2);
                out[i] += v.lp2 * v.env * v.velocity * p.level;
            }
        }
    }
};

} // namespace dalnok
