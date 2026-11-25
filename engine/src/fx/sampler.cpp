// Dalnok Sampler and Dalnok Drums (see sampler.hpp).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/sampler.hpp"

#include "json.hpp"
#include "media.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>

// Coefficients use libm (exp2, pow), which neither allocates nor locks.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"

namespace dalnok::fx {
namespace {
using P = BuiltinProcessor::Param;
const char *const kOnOff[] = {"Off", "On"};
const char *const kModes[] = {"Poly", "Mono"};
constexpr int64_t kMaxSampleSeconds = 120;

const std::vector<P> &samplerParams() {
    static const std::vector<P> params = {
        {Sampler::kRoot, "Root Key", "", 0, 127, 60, P::Linear},
        {Sampler::kTune, "Transpose", "st", -24, 24, 0, P::Linear},
        {Sampler::kFine, "Fine Tune", "ct", -100, 100, 0, P::Linear},
        {Sampler::kAttack, "Attack", "ms", 0.1, 5000, 1, P::Log},
        {Sampler::kDecay, "Decay", "ms", 1, 10000, 300, P::Log},
        {Sampler::kSustain, "Sustain", "%", 0, 100, 100, P::Linear},
        {Sampler::kRelease, "Release", "ms", 1, 10000, 50, P::Log},
        {Sampler::kGain, "Level", "dB", -60, 12, 0, P::Linear},
        {Sampler::kVelocity, "Velocity", "%", 0, 100, 100, P::Linear},
        {Sampler::kOneShot, "One Shot", "", 0, 1, 0, P::Toggle, kOnOff},
        {Sampler::kLoop, "Loop", "", 0, 1, 0, P::Toggle, kOnOff},
        {Sampler::kLoopStart, "Loop Start", "%", 0, 100, 0, P::Linear},
        {Sampler::kLoopEnd, "Loop End", "%", 0, 100, 100, P::Linear},
        {Sampler::kLoopFade, "Loop Crossfade", "%", 0, 50, 0, P::Linear},
        {Sampler::kCutoff, "Cutoff", "Hz", 20, 20000, 20000, P::Log},
        {Sampler::kResonance, "Resonance", "", 0.5, 15, 0.707, P::Log},
        {Sampler::kGlide, "Glide", "ms", 0, 2000, 0, P::Linear},
        {Sampler::kVoiceMode, "Voices", "", 0, 1, 0, P::Choice, kModes},
    };
    return params;
}

const std::vector<P> &drumParams() {
    static const std::vector<P> params = [] {
        static const char *const names[] = {"Kick", "Rim", "Snare", "Clap", "Snare 2", "Low Tom", "Closed Hat", "Mid Tom",
                                            "Pedal Hat", "Tom", "Open Hat", "High Tom", "Crash", "High Tom 2", "Ride", "Pad 16"};
        static std::vector<std::string> titles;
        titles.clear();
        for (const char *n : names) { titles.push_back(std::string(n) + " Level"); titles.push_back(std::string(n) + " Tune"); }
        std::vector<P> list;
        for (uint32_t p = 0; p < SamplerBase::kMaxZones; ++p) {
            list.push_back({2 * p, titles[2 * p].c_str(), "dB", -60, 12, 0, P::Linear});
            list.push_back({2 * p + 1, titles[2 * p + 1].c_str(), "st", -24, 24, 0, P::Linear});
        }
        list.push_back({Drums::kKitGain, "Kit Level", "dB", -60, 12, 0, P::Linear});
        list.push_back({Drums::kKitRelease, "Choke Fade", "ms", 1, 2000, 30, P::Log});
        return list;
    }();
    return params;
}

double dbToLin(double db) { return db <= -60 ? 0.0 : std::pow(10.0, db / 20); }
} // namespace

SamplerBase::SamplerBase(const char *id, const char *name, std::vector<Param> params, double sampleRate, int zones)
    : BuiltinProcessor(id, name, std::move(params)), sampleRate_(sampleRate), zones_(zones) {
    for (auto &z : live_) z.store(nullptr, std::memory_order_relaxed);
}

bool SamplerBase::loadSample(int zone, const std::string &path, std::string &err, int64_t from, int64_t to) {
    if (zone < 0 || zone >= zones_) { err = "no such pad"; return false; }
    std::shared_ptr<SampleBuffer> buf;
    if (!path.empty()) {
        auto media = Media::loadFile(path, sampleRate_, err);
        if (!media) return false;
        from = std::clamp<int64_t>(from, 0, media->frames());
        const int64_t end = to < 0 ? media->frames() : std::clamp<int64_t>(to, from, media->frames());
        const int64_t n = std::min<int64_t>(end - from, static_cast<int64_t>(sampleRate_) * kMaxSampleSeconds);
        if (n <= 0) { err = "the file has no audio"; return false; }
        buf = std::make_shared<SampleBuffer>();
        buf->l.resize(static_cast<size_t>(n));
        buf->r.resize(static_cast<size_t>(n));
        media->read(from, n, buf->l.data(), buf->r.data());
        buf->path = path;
        buf->from = from;
        buf->to = to < 0 ? -1 : from + n;
    }
    // The old buffer is freed only after the audio thread has stopped every voice using it (two blocks on).
    const uint64_t now = blocks_.load(std::memory_order_acquire);
    std::erase_if(retired_, [now](const Retired &r) { return r.after <= now; });
    if (owned_[static_cast<size_t>(zone)]) retired_.push_back({owned_[static_cast<size_t>(zone)], now + 2});
    owned_[static_cast<size_t>(zone)] = buf;
    live_[static_cast<size_t>(zone)].store(buf.get(), std::memory_order_release);
    return true;
}

std::string SamplerBase::samplePath(int zone) const {
    return zone >= 0 && zone < zones_ && owned_[static_cast<size_t>(zone)] ? owned_[static_cast<size_t>(zone)]->path : "";
}

bool SamplerBase::getState(std::string &bytes) {
    if (!BuiltinProcessor::getState(bytes)) return false;
    json::Value doc;
    std::string err;
    if (!json::parse(bytes, doc, err)) return false;
    json::Value samples = json::Value::makeArray();
    for (int z = 0; z < zones_; ++z) {
        const auto &b = owned_[static_cast<size_t>(z)];
        if (b && (b->from > 0 || b->to >= 0)) { // a slice: the file and its range
            json::Value v = json::Value::makeObject();
            v.set("path", b->path);
            v.set("from", b->from);
            v.set("to", b->to);
            samples.push(std::move(v));
        } else {
            samples.push(json::Value(samplePath(z)));
        }
    }
    doc.set("samples", std::move(samples));
    bytes = json::serialize(doc);
    return true;
}

bool SamplerBase::setState(const std::string &bytes) {
    if (!BuiltinProcessor::setState(bytes)) return false;
    json::Value doc;
    std::string err;
    if (!json::parse(bytes, doc, err)) return false;
    std::string missing;
    if (const json::Value *s = doc.get("samples"); s && s->isArray())
        for (size_t z = 0; z < s->array.size() && static_cast<int>(z) < zones_; ++z) {
            const json::Value &v = s->array[z];
            const std::string path = v.isString() ? v.string : v.isObject() ? v.getString("path", "") : "";
            const int64_t from = v.isObject() ? static_cast<int64_t>(v.getNumber("from", 0)) : 0;
            const int64_t to = v.isObject() ? static_cast<int64_t>(v.getNumber("to", -1)) : -1;
            const auto &have = owned_[z];
            if (path == samplePath(static_cast<int>(z)) && (!have || (have->from == from && have->to == to))) continue;
            std::string e;
            if (!loadSample(static_cast<int>(z), path, e, from, to) && !path.empty()) missing += (missing.empty() ? "" : ", ") + path;
        }
    // A missing sample leaves its pad silent; the rest of the state still applies.
    (void)missing;
    return true;
}

void SamplerBase::setFilter(double cutoffHz, double resonance) DALNOK_NONBLOCKING {
    filter_ = cutoffHz < 19'999;
    const double g = std::tan(3.14159265358979323846 * std::min(cutoffHz, sampleRate_ * 0.45) / sampleRate_);
    fk_ = 1 / std::max(0.5, resonance);
    fa1_ = 1 / (1 + g * (g + fk_));
    fa2_ = g * fa1_;
    fa3_ = g * fa2_;
}

void SamplerBase::noteOn(uint8_t note, uint8_t velocity) DALNOK_NONBLOCKING {
    const int zone = zoneFor(note);
    if (zone < 0) return;
    const SampleBuffer *buf = live_[static_cast<size_t>(zone)].load(std::memory_order_acquire);
    if (!buf || buf->l.empty()) return;
    const double ratio = ratioFor(zone, note);
    Voice *slot = nullptr;
    if (mono_) {
        slot = &voices_[0];
        for (size_t i = 1; i < voices_.size(); ++i) voices_[i].stage = Voice::idle;
        if (slot->stage != Voice::idle && slot->held && slot->buf == buf) { // legato: the same voice slides on
            slot->note = note;
            slot->targetInc = ratio;
            if (glide_ <= 0) slot->inc = ratio;
            slot->gain = levelFor(zone, velocity);
            lastInc_ = ratio;
            return;
        }
        const double from = slot->stage != Voice::idle ? slot->inc : lastInc_;
        const float env = slot->stage != Voice::idle ? slot->env : 0.0f;
        *slot = Voice{};
        slot->inc = glide_ > 0 && from > 0 ? from : ratio;
        slot->env = env; // retriggered from where it was: no click
    } else {
        for (auto &v : voices_) if (v.stage == Voice::idle) { slot = &v; break; }
        if (!slot) { // steal the quietest
            slot = &voices_[0];
            for (auto &v : voices_) if (v.env < slot->env) slot = &v;
        }
        *slot = Voice{};
        slot->inc = glide_ > 0 && lastInc_ > 0 ? lastInc_ : ratio;
    }
    slot->buf = buf;
    slot->zone = zone;
    slot->note = note;
    slot->targetInc = ratio;
    slot->gain = levelFor(zone, velocity);
    slot->stage = Voice::attack;
    slot->held = true;
    lastInc_ = ratio;
    ++age_;
}

void SamplerBase::noteOff(uint8_t note) DALNOK_NONBLOCKING {
    for (auto &v : voices_)
        if (v.stage != Voice::idle && v.note == note && v.held) {
            v.held = false;
            if (!oneShot(v.zone) && !pedal_) v.stage = Voice::release;
        }
}

void SamplerBase::process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING {
    applyPending();
    // A replaced sample: voices still reading the old buffer stop here, before it can be freed.
    for (auto &v : voices_)
        if (v.stage != Voice::idle && v.buf != live_[static_cast<size_t>(v.zone)].load(std::memory_order_acquire)) v.stage = Voice::idle;
    for (int i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
    int next = 0, done = 0;
    auto renderTo = [&](int end) DALNOK_NONBLOCKING {
        for (auto &v : voices_) {
            if (v.stage == Voice::idle) continue;
            const auto n = static_cast<int64_t>(v.buf->l.size());
            // The sustain loop (not for one-shots, which ignore note-off and would never end).
            int64_t ls = 0, le = n, fade = 0;
            const bool looping = loop_ && !oneShot(v.zone);
            if (looping) {
                ls = std::clamp<int64_t>(static_cast<int64_t>(loopStart_ * static_cast<double>(n)), 0, n);
                le = std::clamp<int64_t>(static_cast<int64_t>(loopEnd_ * static_cast<double>(n)), 0, n);
                if (le - ls < 2) { ls = 0; le = n; }
                fade = std::min<int64_t>(static_cast<int64_t>(loopFade_ * static_cast<double>(le - ls)), ls);
            }
            const int64_t span = le - ls;
            auto at = [&](double p, float &outL, float &outR) DALNOK_NONBLOCKING {
                const auto k = static_cast<int64_t>(p);
                const float f = static_cast<float>(p - static_cast<double>(k));
                const auto a = static_cast<size_t>(k);
                const size_t b = k + 1 < (looping ? le : n) ? a + 1 : looping ? static_cast<size_t>(ls) : a; // the last frame plays as itself
                outL = v.buf->l[a] + f * (v.buf->l[b] - v.buf->l[a]);
                outR = v.buf->r[a] + f * (v.buf->r[b] - v.buf->r[a]);
            };
            for (int i = done; i < end; ++i) {
                switch (v.stage) {
                case Voice::attack: v.env += attackStep_; if (v.env >= 1) { v.env = 1; v.stage = decayStep_ > 0 ? Voice::decay : Voice::sustain; } break;
                case Voice::decay: v.env -= decayStep_; if (v.env <= sustain_) { v.env = sustain_; v.stage = Voice::sustain; } break;
                case Voice::release: v.env -= releaseStep_; if (v.env <= 0) { v.env = 0; v.stage = Voice::idle; } break;
                default: break;
                }
                if (looping && v.pos >= static_cast<double>(le)) v.pos -= static_cast<double>(span);
                const auto k = static_cast<int64_t>(v.pos);
                if (v.stage == Voice::idle || k >= n || k < 0) { v.stage = Voice::idle; break; }
                float sl, sr;
                at(v.pos, sl, sr);
                if (fade > 0 && v.pos >= static_cast<double>(le - fade)) { // crossfade into the loop start
                    const float t = static_cast<float>((v.pos - static_cast<double>(le - fade)) / static_cast<double>(fade));
                    float xl, xr;
                    at(v.pos - static_cast<double>(span), xl, xr);
                    sl = sl * (1 - t) + xl * t;
                    sr = sr * (1 - t) + xr * t;
                }
                if (filter_) {
                    double *ic = v.ic;
                    for (int c = 0; c < 2; ++c) {
                        const double x = c == 0 ? sl : sr;
                        const double v3 = x - ic[2 * c + 1], v1 = fa1_ * ic[2 * c] + fa2_ * v3, v2 = ic[2 * c + 1] + fa2_ * ic[2 * c] + fa3_ * v3;
                        ic[2 * c] = 2 * v1 - ic[2 * c];
                        ic[2 * c + 1] = 2 * v2 - ic[2 * c + 1];
                        (c == 0 ? sl : sr) = static_cast<float>(v2);
                    }
                }
                const float g = v.gain * v.env;
                left[i] += sl * g;
                right[i] += sr * g;
                v.inc = v.targetInc + (v.inc - v.targetInc) * glide_;
                v.pos += v.inc;
            }
        }
        done = end;
    };
    for (; next < noteCount; ++next) {
        const PluginNote &e = notes[next];
        renderTo(std::clamp(e.offset, done, frames));
        if (e.on == kEventNoteOn) noteOn(e.pitch, e.velocity);
        else if (e.on == kEventNoteOff) noteOff(e.pitch);
        else if (e.on == kEventControl && e.pitch == 64) {
            pedal_ = e.velocity >= 64;
            if (!pedal_)
                for (auto &v : voices_)
                    if (v.stage != Voice::idle && !v.held && !oneShot(v.zone)) v.stage = Voice::release;
        } else if (e.on == kEventControl && (e.pitch == 120 || e.pitch == 123)) {
            for (auto &v : voices_) if (v.stage != Voice::idle) v.stage = Voice::release;
        }
    }
    renderTo(frames);
    blocks_.fetch_add(1, std::memory_order_acq_rel);
}

// ---- Sampler ----------------------------------------------------------------------------------------------------

Sampler::Sampler(double sampleRate) : SamplerBase("sampler", "Dalnok Sampler", samplerParams(), sampleRate, 1) {}

void Sampler::changed() DALNOK_NONBLOCKING {
    root_ = std::round(rt(kRoot));
    tune_ = std::round(rt(kTune)) + rt(kFine) / 100.0;
    gain_ = static_cast<float>(dbToLin(rt(kGain)));
    velocity_ = static_cast<float>(std::clamp(rt(kVelocity) / 100.0, 0.0, 1.0));
    oneShot_ = rt(kOneShot) >= 0.5;
    sustain_ = static_cast<float>(std::clamp(rt(kSustain) / 100.0, 0.0, 1.0));
    attackStep_ = static_cast<float>(1.0 / std::max(1.0, rt(kAttack) * 1e-3 * sampleRate_));
    decayStep_ = sustain_ < 1 ? static_cast<float>((1.0 - sustain_) / std::max(1.0, rt(kDecay) * 1e-3 * sampleRate_)) : 0.0f;
    releaseStep_ = static_cast<float>(1.0 / std::max(1.0, rt(kRelease) * 1e-3 * sampleRate_));
    loop_ = rt(kLoop) >= 0.5;
    loopStart_ = std::clamp(rt(kLoopStart) / 100, 0.0, 1.0);
    loopEnd_ = std::clamp(rt(kLoopEnd) / 100, 0.0, 1.0);
    loopFade_ = std::clamp(rt(kLoopFade) / 100, 0.0, 0.5);
    setFilter(rt(kCutoff), rt(kResonance));
    const double glideMs = rt(kGlide);
    glide_ = glideMs < 0.5 ? 0.0 : std::exp(-1.0 / std::max(1.0, glideMs / 4 * 1e-3 * sampleRate_)); // ~98 % there in glideMs
    mono_ = rt(kVoiceMode) >= 0.5;
}

double Sampler::ratioFor(int, uint8_t note) const DALNOK_NONBLOCKING {
    return std::exp2((static_cast<double>(note) - root_ + tune_) / 12.0);
}

float Sampler::levelFor(int, uint8_t velocity) const DALNOK_NONBLOCKING {
    const float v = static_cast<float>(velocity) / 127.0f;
    return gain_ * (1.0f - velocity_ + velocity_ * v);
}

// ---- Drums ------------------------------------------------------------------------------------------------------

Drums::Drums(double sampleRate) : SamplerBase("drums", "Dalnok Drums", drumParams(), sampleRate, kMaxZones) {}

void Drums::changed() DALNOK_NONBLOCKING {
    const double kit = dbToLin(rt(kKitGain));
    for (uint32_t p = 0; p < kMaxZones; ++p) {
        gain_[p] = static_cast<float>(kit * dbToLin(rt(2 * p)));
        ratio_[p] = std::exp2(std::round(rt(2 * p + 1)) / 12.0);
    }
    attackStep_ = 1.0f; // drums start at once
    decayStep_ = 0;
    sustain_ = 1;
    releaseStep_ = static_cast<float>(1.0 / std::max(1.0, rt(kKitRelease) * 1e-3 * sampleRate_));
}

float Drums::levelFor(int zone, uint8_t velocity) const DALNOK_NONBLOCKING {
    return gain_[static_cast<size_t>(zone)] * static_cast<float>(velocity) / 127.0f;
}

} // namespace dalnok::fx

#pragma clang diagnostic pop
