// Dalnok Sampler and Dalnok Drums: the stock sample instruments (Logic's Quick Sampler and Drum Machine Designer,
// Ableton's Simpler and Drum Rack cover the same ground). Dalnok's own design.
//   Sampler: one sample played across the keyboard, transposed from its root key (linear interpolation), with an
//            ADSR envelope, tuning, velocity sensitivity and a one-shot mode.
//   Drums:   16 pads on notes 36-51 (C1-D#2, the General MIDI drum area), one sample each, played one-shot with
//            its own level and tuning.
// Samples are decoded on the control thread (dalnok_plugin_set_sample, or a saved state naming their files) into
// memory; the audio thread reads finished buffers only. A replaced buffer stays alive until the audio thread has
// moved past it (two blocks), so the audio thread never frees memory.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "fx/builtin.hpp"

#include <array>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

namespace dalnok::fx {

struct SampleBuffer {
    std::vector<float> l, r;
    std::string path;
};

class SamplerBase : public BuiltinProcessor {
public:
    static constexpr int kMaxZones = 16, kVoices = 32;
    SamplerBase(const char *id, const char *name, std::vector<Param> params, double sampleRate, int zones);
    bool instrument() const override { return true; }
    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override;
    bool getState(std::string &bytes) override;
    bool setState(const std::string &bytes) override;
    // Control thread: decode `path` into zone `zone` (empty path clears it). Returns false with a message.
    bool loadSample(int zone, const std::string &path, std::string &err);
    std::string samplePath(int zone) const;
    int zoneCount() const { return zones_; }

protected:
    struct Voice {
        const SampleBuffer *buf = nullptr;
        int zone = -1;
        uint8_t note = 0;
        double pos = 0, inc = 1;
        float gain = 0, env = 0;
        enum Stage : uint8_t { idle, attack, decay, sustain, release } stage = idle;
        bool held = false;
    };
    // Which zone a note plays (-1 = none), and its pitch ratio and level (velocity 1-127).
    virtual int zoneFor(uint8_t note) const DALNOK_NONBLOCKING = 0;
    virtual double ratioFor(int zone, uint8_t note) const DALNOK_NONBLOCKING = 0;
    virtual float levelFor(int zone, uint8_t velocity) const DALNOK_NONBLOCKING = 0;
    virtual bool oneShot(int zone) const DALNOK_NONBLOCKING = 0;
    // Envelope steps per sample (attack and release always; decay to sustain for the Sampler).
    float attackStep_ = 1, decayStep_ = 0, sustain_ = 1, releaseStep_ = 1;
    double sampleRate_;

private:
    void noteOn(uint8_t note, uint8_t velocity) DALNOK_NONBLOCKING;
    void noteOff(uint8_t note) DALNOK_NONBLOCKING;
    int zones_;
    std::array<std::atomic<const SampleBuffer *>, kMaxZones> live_{}; // what the audio thread plays
    std::array<std::shared_ptr<const SampleBuffer>, kMaxZones> owned_{}; // control thread: keeps live_ alive
    struct Retired { std::shared_ptr<const SampleBuffer> buf; uint64_t after; };
    std::vector<Retired> retired_;                                     // freed once the audio thread has moved on
    std::atomic<uint64_t> blocks_{0};
    std::array<Voice, kVoices> voices_{};
    uint64_t age_ = 0;
    bool pedal_ = false;
};

class Sampler final : public SamplerBase {
public:
    explicit Sampler(double sampleRate);
    enum : uint32_t { kRoot = 0, kTune, kFine, kAttack, kDecay, kSustain, kRelease, kGain, kVelocity, kOneShot };

private:
    void changed() DALNOK_NONBLOCKING override;
    int zoneFor(uint8_t) const DALNOK_NONBLOCKING override { return 0; }
    double ratioFor(int, uint8_t note) const DALNOK_NONBLOCKING override;
    float levelFor(int, uint8_t velocity) const DALNOK_NONBLOCKING override;
    bool oneShot(int) const DALNOK_NONBLOCKING override { return oneShot_; }
    double root_ = 60, tune_ = 0;
    float gain_ = 1, velocity_ = 1;
    bool oneShot_ = false;
};

class Drums final : public SamplerBase {
public:
    explicit Drums(double sampleRate);
    static constexpr int kFirstNote = 36;
    // Parameters: pad p's level (dB) is 2p, its tuning (semitones) 2p + 1; then the kit's level and decay.
    enum : uint32_t { kKitGain = 32, kKitRelease = 33 };

private:
    void changed() DALNOK_NONBLOCKING override;
    int zoneFor(uint8_t note) const DALNOK_NONBLOCKING override {
        return note >= kFirstNote && note < kFirstNote + kMaxZones ? note - kFirstNote : -1;
    }
    double ratioFor(int zone, uint8_t) const DALNOK_NONBLOCKING override { return ratio_[static_cast<size_t>(zone)]; }
    float levelFor(int zone, uint8_t velocity) const DALNOK_NONBLOCKING override;
    bool oneShot(int) const DALNOK_NONBLOCKING override { return true; }
    std::array<float, kMaxZones> gain_{};
    std::array<double, kMaxZones> ratio_{};
};

} // namespace dalnok::fx
