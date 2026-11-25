// Guitar Studio: an eight-slot chain; each slot holds any module from guitar_modules.hpp (gate, compressor, drives,
// amps, cabinet, EQ, wah, chorus, flanger, phaser, tremolo, vibrato, delay, reverb, spring), in any order.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "fx/builtin.hpp"
#include "fx/guitar_modules.hpp"

namespace dalnok::fx {
class GuitarStudio final : public BuiltinProcessor {
public:
    explicit GuitarStudio(double sampleRate);
    void process(float *, float *, int, const PluginNote *, int) DALNOK_NONBLOCKING override;
    // Titles, units, text and defaults follow each slot's module; parameters an empty slot or module doesn't use
    // are hidden. Choosing a module resets that slot's switch and knobs to the module's defaults.
    bool parameter(int32_t index, PluginParameter &out) override;
    bool parameterText(uint32_t id, double normalized, std::string &out) override;
    bool setParameter(uint32_t id, double normalized) override;

    // Parameter ids (index == id): 0 input, 1 output, then per slot: module, on, six knobs (normalized 0-1).
    static constexpr int kSlots = 8, kPerSlot = 2 + guitar::kKnobs;
    static constexpr uint32_t kInput = 0, kOutput = 1;
    static constexpr uint32_t typeId(int s) { return 2 + static_cast<uint32_t>(s * kPerSlot); }
    static constexpr uint32_t onId(int s) { return typeId(s) + 1; }
    static constexpr uint32_t knobId(int s, int k) { return typeId(s) + 2 + static_cast<uint32_t>(k); }

private:
    void changed() DALNOK_NONBLOCKING override;
    int typeAt(int slot) const;
    void prime(int s, int type) DALNOK_NONBLOCKING;
    void refresh(int s, int frames) DALNOK_NONBLOCKING;

    struct Slot {
        int running = 0, wanted = 0;
        bool on = true, idle = true;
        double active = 0, knob[guitar::kKnobs]{}, target[guitar::kKnobs]{};
        guitar::ModuleDsp dsp;
    };
    Slot slots_[kSlots];
    double rate_, inGain_ = 1, outGain_ = 1, inTarget_ = 1, outTarget_ = 1, smoothing_, knobSmoothing_, fadeStep_;
    bool primed_ = false;
};
} // namespace dalnok::fx
