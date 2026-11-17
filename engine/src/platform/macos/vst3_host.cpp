// VST3 hosting on macOS (ADR-0009 stage 3): loads a bundle in-process, creates the processor
// component, activates stereo buses and processes 32-bit blocks. Audio-thread work is limited to
// filling fixed buffers and calling IAudioProcessor::process.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "plugin_host.hpp"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/vstspeaker.h"
#pragma clang diagnostic pop

#include <CoreFoundation/CoreFoundation.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <map>
#include <mutex>
#include <vector>

namespace dalnok {
using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {
// ---- Small COM-style objects owned by the host ----------------------------------

class HostApplication final : public IHostApplication {
public:
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IHostApplication::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
            *obj = this;
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API getName(String128 name) override {
        const char *n = "Dalnok";
        for (int i = 0; i < 128; ++i) { name[i] = static_cast<char16>(n[i]); if (!n[i]) break; }
        return kResultOk;
    }
    tresult PLUGIN_API createInstance(TUID, TUID, void **obj) override { *obj = nullptr; return kNotImplemented; }
};
HostApplication gHost;

// Growable memory stream for plugin state (control thread only).
class MemoryStream final : public IBStream {
public:
    std::string data;
    int64 pos = 0;
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IBStream::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
            *obj = this;
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API read(void *buffer, int32 n, int32 *got) override {
        const int64 avail = std::max<int64>(0, static_cast<int64>(data.size()) - pos);
        const int32 k = static_cast<int32>(std::min<int64>(std::max(0, n), avail));
        if (k > 0) std::memcpy(buffer, data.data() + pos, static_cast<size_t>(k));
        pos += k;
        if (got) *got = k;
        return kResultOk;
    }
    tresult PLUGIN_API write(void *buffer, int32 n, int32 *written) override {
        if (n < 0) return kInvalidArgument;
        if (pos + n > static_cast<int64>(data.size())) data.resize(static_cast<size_t>(pos + n));
        std::memcpy(data.data() + pos, buffer, static_cast<size_t>(n));
        pos += n;
        if (written) *written = n;
        return kResultOk;
    }
    tresult PLUGIN_API seek(int64 p, int32 mode, int64 *result) override {
        const int64 base = mode == kIBSeekSet ? 0 : mode == kIBSeekCur ? pos : static_cast<int64>(data.size());
        if (base + p < 0) return kInvalidArgument;
        pos = base + p;
        if (result) *result = pos;
        return kResultOk;
    }
    tresult PLUGIN_API tell(int64 *p) override { if (p) *p = pos; return kResultOk; }
};

// Fixed-capacity event list read by the plugin during process (no allocation).
class BlockEvents final : public IEventList {
public:
    std::array<Event, 512> events{};
    int32 count = 0;
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IEventList::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
            *obj = this;
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    int32 PLUGIN_API getEventCount() override { return count; }
    tresult PLUGIN_API getEvent(int32 index, Event &e) override {
        if (index < 0 || index >= count) return kInvalidArgument;
        e = events[static_cast<size_t>(index)];
        return kResultOk;
    }
    tresult PLUGIN_API addEvent(Event &) override { return kResultFalse; } // output events are not collected yet
};

// Loaded bundles stay loaded for the process lifetime: unloading plugin code is a common crash source,
// and instances may outlive each other in undo history and render snapshots.
struct Module {
    CFBundleRef bundle = nullptr;
    IPluginFactory *factory = nullptr;
};
std::mutex gModulesLock;
std::map<std::string, Module> gModules;

bool openModule(const std::string &path, Module &out, std::string &err) {
    std::lock_guard<std::mutex> g(gModulesLock);
    if (auto it = gModules.find(path); it != gModules.end()) { out = it->second; return true; }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(path.c_str()),
                                                           static_cast<CFIndex>(path.size()), true);
    CFBundleRef bundle = url ? CFBundleCreate(nullptr, url) : nullptr;
    if (url) CFRelease(url);
    if (!bundle) { err = "not a plugin bundle: " + path; return false; }
    if (!CFBundleLoadExecutableAndReturnError(bundle, nullptr)) { err = "cannot load plugin code"; CFRelease(bundle); return false; }
    using Entry = bool (*)(CFBundleRef);
    using GetFactory = IPluginFactory *(PLUGIN_API *)();
    if (auto entry = reinterpret_cast<Entry>(CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleEntry"))))
        if (!entry(bundle)) { err = "the plugin's bundleEntry failed"; return false; }
    auto get = reinterpret_cast<GetFactory>(CFBundleGetFunctionPointerForName(bundle, CFSTR("GetPluginFactory")));
    IPluginFactory *factory = get ? get() : nullptr;
    if (!factory) { err = "no plugin factory"; return false; }
    out = {bundle, factory};
    gModules[path] = out;
    return true;
}

std::string hexId(const TUID id) {
    static const char *digits = "0123456789ABCDEF";
    std::string s;
    for (int i = 0; i < 16; ++i) {
        const auto b = static_cast<unsigned char>(id[i]);
        s += digits[b >> 4];
        s += digits[b & 15];
    }
    return s;
}

class Vst3Processor final : public PluginProcessor {
public:
    ~Vst3Processor() override {
        if (processor_) { processor_->setProcessing(false); processor_->release(); }
        if (component_) { component_->setActive(false); component_->terminate(); component_->release(); }
    }
    bool open(const Module &m, const std::string &wantedId, double rate, int maxBlock, bool offline, std::string &err) {
        IPluginFactory2 *f2 = nullptr;
        if (m.factory->queryInterface(IPluginFactory2::iid, reinterpret_cast<void **>(&f2)) != kResultOk) f2 = nullptr;
        TUID cid{};
        bool found = false;
        for (int32 i = 0; i < m.factory->countClasses() && !found; ++i) {
            PClassInfo ci{};
            if (m.factory->getClassInfo(i, &ci) != kResultOk || std::strcmp(ci.category, kVstAudioEffectClass) != 0) continue;
            if (!wantedId.empty() && hexId(ci.cid) != wantedId) continue;
            std::memcpy(cid, ci.cid, sizeof cid);
            name_ = ci.name;
            if (f2) {
                PClassInfo2 c2{};
                if (f2->getClassInfo2(i, &c2) == kResultOk) { vendor_ = c2.vendor; subCategories_ = c2.subCategories; }
            }
            found = true;
        }
        if (f2) f2->release();
        if (!found) { err = wantedId.empty() ? "the plugin has no audio processor" : "plugin class not found"; return false; }
        classId_ = hexId(cid);
        if (m.factory->createInstance(cid, IComponent::iid, reinterpret_cast<void **>(&component_)) != kResultOk || !component_) {
            err = "cannot create the plugin";
            return false;
        }
        if (component_->initialize(&gHost) != kResultOk) { err = "the plugin failed to initialize"; return false; }
        if (component_->queryInterface(IAudioProcessor::iid, reinterpret_cast<void **>(&processor_)) != kResultOk || !processor_) {
            err = "the plugin has no audio processor interface";
            return false;
        }
        const int32 audioIn = component_->getBusCount(kAudio, kInput), audioOut = component_->getBusCount(kAudio, kOutput);
        const int32 eventIn = component_->getBusCount(kEvent, kInput);
        if (audioOut < 1) { err = "the plugin has no audio output"; return false; }
        instrument_ = audioIn == 0 && eventIn > 0;
        // Stereo main buses; other buses stay inactive.
        SpeakerArrangement stereo = SpeakerArr::kStereo;
        processor_->setBusArrangements(audioIn > 0 ? &stereo : nullptr, audioIn > 0 ? 1 : 0, &stereo, 1);
        if (audioIn > 0) component_->activateBus(kAudio, kInput, 0, true);
        component_->activateBus(kAudio, kOutput, 0, true);
        if (eventIn > 0) component_->activateBus(kEvent, kInput, 0, true);
        ProcessSetup setup{offline ? kOffline : kRealtime, kSample32, maxBlock, rate};
        if (processor_->setupProcessing(setup) != kResultOk) { err = "the plugin rejected the sample rate or block size"; return false; }
        if (component_->setActive(true) != kResultOk) { err = "the plugin could not be activated"; return false; }
        processor_->setProcessing(true);
        hasInput_ = audioIn > 0;
        hasEvents_ = eventIn > 0;
        scratchL_.assign(static_cast<size_t>(maxBlock), 0.0f);
        scratchR_.assign(static_cast<size_t>(maxBlock), 0.0f);
        return true;
    }

    bool instrument() const override { return instrument_; }
    uint32_t latency() const override { return processor_ ? processor_->getLatencySamples() : 0; }
    const std::string &name() const override { return name_; }
    const std::string &vendor() const override { return vendor_; }
    const std::string &classId() const override { return classId_; }

    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override {
        events_.count = 0;
        for (int i = 0; i < noteCount && events_.count < static_cast<int32>(events_.events.size()); ++i) {
            Event &e = events_.events[static_cast<size_t>(events_.count++)];
            e = Event{};
            e.sampleOffset = notes[i].offset;
            if (notes[i].on) {
                e.type = Event::kNoteOnEvent;
                e.noteOn = {0, notes[i].pitch, 0.0f, static_cast<float>(notes[i].velocity) / 127.0f, 0, -1};
            } else {
                e.type = Event::kNoteOffEvent;
                e.noteOff = {0, notes[i].pitch, 0.0f, -1, 0.0f};
            }
        }
        // Effects get the input in separate buffers so plugins that read after writing still see it.
        for (int i = 0; i < frames; ++i) { scratchL_[static_cast<size_t>(i)] = left[i]; scratchR_[static_cast<size_t>(i)] = right[i]; }
        float *inPtr[2] = {scratchL_.data(), scratchR_.data()};
        float *outPtr[2] = {left, right};
        AudioBusBuffers in, out;
        in.numChannels = 2;
        in.channelBuffers32 = inPtr;
        out.numChannels = 2;
        out.channelBuffers32 = outPtr;
        ProcessData data;
        data.processMode = kRealtime;
        data.symbolicSampleSize = kSample32;
        data.numSamples = frames;
        data.numInputs = hasInput_ ? 1 : 0;
        data.numOutputs = 1;
        data.inputs = hasInput_ ? &in : nullptr;
        data.outputs = &out;
        data.inputEvents = hasEvents_ ? &events_ : nullptr;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        // The one call into plugin code (ADR-0009): it cannot be verified, so it is the explicit exception.
        if (processor_->process(data) != kResultOk) {
            for (int i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
        }
#pragma clang diagnostic pop
    }

    bool getState(std::string &bytes) override {
        MemoryStream s;
        if (component_->getState(&s) != kResultOk) return false;
        bytes = std::move(s.data);
        return true;
    }
    bool setState(const std::string &bytes) override {
        MemoryStream s;
        s.data = bytes;
        return component_->setState(&s) == kResultOk;
    }

private:
    IComponent *component_ = nullptr;
    IAudioProcessor *processor_ = nullptr;
    BlockEvents events_;
    std::vector<float> scratchL_, scratchR_;
    std::string name_, vendor_, classId_, subCategories_;
    bool instrument_ = false, hasInput_ = false, hasEvents_ = false;
};
} // namespace

std::unique_ptr<PluginProcessor> loadVst3(const std::string &bundle, const std::string &classId, double sampleRate,
                                          int maxBlock, bool offline, std::string &err) {
    Module m;
    if (!openModule(bundle, m, err)) return nullptr;
    auto p = std::make_unique<Vst3Processor>();
    if (!p->open(m, classId, sampleRate, maxBlock, offline, err)) return nullptr;
    return p;
}

// ---- base64 for plugin state in project files -------------------------------------

std::string base64Encode(const std::string &in) {
    static const char *t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    size_t i = 0;
    for (; i + 2 < in.size(); i += 3) {
        const uint32_t v = (static_cast<uint8_t>(in[i]) << 16) | (static_cast<uint8_t>(in[i + 1]) << 8) | static_cast<uint8_t>(in[i + 2]);
        out += t[v >> 18]; out += t[(v >> 12) & 63]; out += t[(v >> 6) & 63]; out += t[v & 63];
    }
    if (i + 1 == in.size()) {
        const uint32_t v = static_cast<uint8_t>(in[i]) << 16;
        out += t[v >> 18]; out += t[(v >> 12) & 63]; out += "==";
    } else if (i + 2 == in.size()) {
        const uint32_t v = (static_cast<uint8_t>(in[i]) << 16) | (static_cast<uint8_t>(in[i + 1]) << 8);
        out += t[v >> 18]; out += t[(v >> 12) & 63]; out += t[(v >> 6) & 63]; out += '=';
    }
    return out;
}

bool base64Decode(const std::string &in, std::string &out) {
    auto val = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        return c == '+' ? 62 : c == '/' ? 63 : -1;
    };
    out.clear();
    uint32_t acc = 0;
    int bits = 0;
    for (char c : in) {
        if (c == '=') break;
        const int v = val(c);
        if (v < 0) return false;
        acc = (acc << 6) | static_cast<uint32_t>(v);
        bits += 6;
        if (bits >= 8) { bits -= 8; out += static_cast<char>((acc >> bits) & 0xff); }
    }
    return true;
}

} // namespace dalnok
