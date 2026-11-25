// Guitar Studio host: eight module slots in series between input and output gain. Each slot fades (10 ms) when it
// is switched on or off, and when its module changes it fades out, clears, and fades in with the new module, so
// edits while playing never click.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/guitar_studio.hpp"
#include <algorithm>
#include <cmath>
#include <string>

namespace dalnok::fx {
namespace {
using P = BuiltinProcessor::Param;
using namespace guitar;
constexpr int kChunk = 16; // knob smoothing and coefficient updates run once per chunk
// A new instance starts as a complete rig: gate, compressor, crunch amp, cabinet, delay and reverb.
constexpr int defaultChain[GuitarStudio::kSlots] = {Gate, Compressor, AmpCrunch, Cabinet, Delay, Reverb, Empty, Empty};

const std::vector<P> &table() {
    static const std::vector<std::string> titles = [] {
        std::vector<std::string> t;
        for (int s = 0; s < GuitarStudio::kSlots; ++s) {
            const std::string n = std::to_string(s + 1);
            t.push_back(n + " Module");
            t.push_back(n + " On/Off");
            for (int k = 0; k < kKnobs; ++k) t.push_back(n + " Knob " + std::to_string(k + 1));
        }
        return t;
    }();
    static const std::vector<P> list = [] {
        std::vector<P> p = {{GuitarStudio::kInput, "Input", "dB", -24, 24, 0}, {GuitarStudio::kOutput, "Output", "dB", -36, 12, 0}};
        for (int s = 0; s < GuitarStudio::kSlots; ++s) {
            const Module &m = module(defaultChain[s]);
            const auto title = [&](int f) { return titles[static_cast<size_t>(s * GuitarStudio::kPerSlot + f)].c_str(); };
            p.push_back({GuitarStudio::typeId(s), title(0), "", 0, TypeCount - 1, static_cast<double>(defaultChain[s]), P::Choice, moduleNames()});
            p.push_back({GuitarStudio::onId(s), title(1), "", 0, 1, 1, P::Toggle});
            for (int k = 0; k < kKnobs; ++k)
                p.push_back({GuitarStudio::knobId(s, k), title(2 + k), "", 0, 1, k < m.knobs ? knobNormalized(m.knob[k], m.knob[k].def) : 0});
        }
        return p;
    }();
    return list;
}

// libm in the gain conversion; allocation- and lock-free.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
double db(double v) DALNOK_NONBLOCKING { return std::pow(10.0, v / 20); }
int typeOf(double plain) DALNOK_NONBLOCKING { return std::clamp(static_cast<int>(std::lround(plain)), 0, TypeCount - 1); }
#pragma clang diagnostic pop
} // namespace

GuitarStudio::GuitarStudio(double rate) : BuiltinProcessor("guitar-studio", "Dalnok Guitar Studio", table()), rate_(rate) {
    smoothing_ = 1 - std::exp(-1 / (0.02 * rate));
    knobSmoothing_ = 1 - std::exp(-kChunk / (0.03 * rate));
    fadeStep_ = 1 / (0.01 * rate);
    for (auto &s : slots_) s.dsp.prepare(rate);
}

int GuitarStudio::typeAt(int s) const { return typeOf(value(typeId(s))); }

bool GuitarStudio::parameter(int32_t index, PluginParameter &out) {
    if (!BuiltinProcessor::parameter(index, out)) return false;
    if (out.id < typeId(0)) return true;
    const int s = static_cast<int>(out.id - typeId(0)) / kPerSlot, f = static_cast<int>(out.id - typeId(0)) % kPerSlot;
    const int type = typeAt(s);
    const Module &m = module(type);
    const std::string prefix = std::to_string(s + 1) + " " + m.name;
    if (type == Empty) { out.hidden = true; return true; }
    if (f == 0) { out.title = prefix + " Module"; out.automatable = false; return true; }
    if (f == 1) { out.title = prefix + " On/Off"; return true; }
    const int k = f - 2;
    if (k >= m.knobs) { out.hidden = true; return true; }
    const Knob &knob = m.knob[k];
    out.title = prefix + " " + knob.name;
    out.display = knobText(knob, out.value);
    out.units = out.display.find(knob.units) != std::string::npos ? knob.units : "";
    out.defaultValue = knobNormalized(knob, knob.def);
    out.stepCount = knob.curve == Knob::Steps ? static_cast<int32_t>(knob.max - knob.min) : 0;
    return true;
}

bool GuitarStudio::parameterText(uint32_t id, double normalized, std::string &out) {
    if (id >= typeId(0) && id < typeId(kSlots) && normalized >= 0 && normalized <= 1) {
        const int s = static_cast<int>(id - typeId(0)) / kPerSlot, f = static_cast<int>(id - typeId(0)) % kPerSlot;
        if (f == 0) { out = module(typeOf(normalized * (TypeCount - 1))).name; return true; }
        const Module &m = module(typeAt(s));
        if (f >= 2 && f - 2 < m.knobs) { out = knobText(m.knob[f - 2], normalized); return true; }
    }
    return BuiltinProcessor::parameterText(id, normalized, out);
}

bool GuitarStudio::setParameter(uint32_t id, double normalized) {
    if (id < typeId(0) || id >= typeId(kSlots) || (id - typeId(0)) % kPerSlot != 0) return BuiltinProcessor::setParameter(id, normalized);
    const int s = static_cast<int>(id - typeId(0)) / kPerSlot, before = typeAt(s);
    if (!BuiltinProcessor::setParameter(id, normalized)) return false;
    const int after = typeAt(s);
    if (after == before) return true;
    const Module &m = module(after);
    BuiltinProcessor::setParameter(onId(s), 1);
    for (int k = 0; k < kKnobs; ++k)
        BuiltinProcessor::setParameter(knobId(s, k), k < m.knobs ? knobNormalized(m.knob[k], m.knob[k].def) : 0);
    return true;
}

void GuitarStudio::changed() DALNOK_NONBLOCKING {
    inTarget_ = db(rt(kInput));
    outTarget_ = db(rt(kOutput));
    for (int s = 0; s < kSlots; ++s) {
        Slot &sl = slots_[s];
        sl.wanted = typeOf(rt(typeId(s)));
        sl.on = rt(onId(s)) >= 0.5;
        for (int k = 0; k < kKnobs; ++k) sl.target[k] = rt(knobId(s, k));
    }
    if (primed_) return;
    inGain_ = inTarget_;
    outGain_ = outTarget_;
    for (int s = 0; s < kSlots; ++s) {
        prime(s, slots_[s].wanted);
        slots_[s].active = slots_[s].on && slots_[s].running != Empty ? 1 : 0;
        slots_[s].idle = slots_[s].active == 0;
    }
    primed_ = true;
}

void GuitarStudio::prime(int s, int type) DALNOK_NONBLOCKING {
    Slot &sl = slots_[s];
    sl.running = type;
    sl.dsp.reset(type);
    for (int k = 0; k < kKnobs; ++k) sl.knob[k] = sl.target[k];
    refresh(s, kChunk);
}

void GuitarStudio::refresh(int s, int frames) DALNOK_NONBLOCKING {
    Slot &sl = slots_[s];
    const Module &m = module(sl.running);
    double v[kKnobs]{};
    for (int k = 0; k < m.knobs; ++k) {
        if (m.knob[k].curve == Knob::Steps) sl.knob[k] = sl.target[k];
        else sl.knob[k] += knobSmoothing_ * (sl.target[k] - sl.knob[k]);
        v[k] = knobValue(m.knob[k], sl.knob[k]);
    }
    sl.dsp.update(sl.running, v, frames);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects" // std::isfinite only; the slots' DSP is checked in guitar_modules.cpp
void GuitarStudio::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    for (int start = 0; start < frames; start += kChunk) {
        const int n = std::min(kChunk, frames - start);
        bool ran[kSlots]{};
        for (int s = 0; s < kSlots; ++s)
            if (slots_[s].running != Empty && !slots_[s].idle) refresh(s, n);
        for (int i = start; i < start + n; ++i) {
            inGain_ += smoothing_ * (inTarget_ - inGain_);
            outGain_ += smoothing_ * (outTarget_ - outGain_);
            double l = std::isfinite(left[i]) ? left[i] * inGain_ : 0, r = std::isfinite(right[i]) ? right[i] * inGain_ : 0;
            for (int s = 0; s < kSlots; ++s) {
                Slot &sl = slots_[s];
                const bool want = sl.on && sl.wanted == sl.running && sl.running != Empty;
                if (!want && sl.active <= 0) {
                    if (sl.wanted != sl.running) prime(s, sl.wanted); // faded out: swap in the new module
                    sl.idle = true;
                    continue;
                }
                if (sl.idle) { prime(s, sl.running); sl.idle = false; } // back on: start clean, no stale tails
                sl.active = want ? std::min(1.0, sl.active + fadeStep_) : std::max(0.0, sl.active - fadeStep_);
                double wl = l, wr = r;
                sl.dsp.process(sl.running, wl, wr);
                l += sl.active * (wl - l);
                r += sl.active * (wr - r);
                ran[s] = true;
            }
            left[i] = static_cast<float>(l * outGain_);
            right[i] = static_cast<float>(r * outGain_);
        }
        for (int s = 0; s < kSlots; ++s) if (ran[s]) slots_[s].dsp.flush();
    }
}
#pragma clang diagnostic pop
} // namespace dalnok::fx
