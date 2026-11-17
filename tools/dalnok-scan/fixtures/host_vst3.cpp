// Test-only VST3 module with real processing, for scripts/ci/plugin-host.sh:
//   "Dalnok Test Gain"  (effect): out = in × gain; gain is the plugin state (float, default 0.5);
//                                  reports 7 frames of latency (not applied, only reported).
//   "Dalnok Test Synth" (instrument): outputs a constant level = velocity/127 while a note is held,
//                                  switching at the exact event sample offset; 0 otherwise.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include <CoreFoundation/CoreFoundation.h>
#include <cstring>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace Steinberg::Vst {
DEF_CLASS_IID(IComponent)
DEF_CLASS_IID(IAudioProcessor)
DEF_CLASS_IID(IEventList)
}

namespace {
const TUID kGainId = {'D', 'a', 'l', 'n', 'o', 'k', 'T', 'e', 's', 't', 'G', 'a', 'i', 'n', '0', '1'};
const TUID kSynthId = {'D', 'a', 'l', 'n', 'o', 'k', 'T', 'e', 's', 't', 'S', 'y', 'n', 't', 'h', '1'};

void setName(String128 out, const char *s) {
    int i = 0;
    for (; s[i] && i < 127; ++i) out[i] = static_cast<char16>(s[i]);
    out[i] = 0;
}

class TestPlugin final : public IComponent, public IAudioProcessor {
public:
    explicit TestPlugin(bool synth) : synth_(synth) {}
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IAudioProcessor::iid)) { *obj = static_cast<IAudioProcessor *>(this); addRef(); return kResultOk; }
        if (FUnknownPrivate::iidEqual(iid, IComponent::iid) || FUnknownPrivate::iidEqual(iid, IPluginBase::iid) ||
            FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
            *obj = static_cast<IComponent *>(this);
            addRef();
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return ++refs_; }
    uint32 PLUGIN_API release() override {
        const uint32 r = --refs_;
        if (r == 0) delete this;
        return r;
    }
    // IPluginBase
    tresult PLUGIN_API initialize(FUnknown *) override { return kResultOk; }
    tresult PLUGIN_API terminate() override { return kResultOk; }
    // IComponent
    tresult PLUGIN_API getControllerClassId(TUID) override { return kResultFalse; }
    tresult PLUGIN_API setIoMode(IoMode) override { return kResultOk; }
    int32 PLUGIN_API getBusCount(MediaType type, BusDirection dir) override {
        if (type == kAudio) return dir == kOutput ? 1 : (synth_ ? 0 : 1);
        return type == kEvent && dir == kInput && synth_ ? 1 : 0;
    }
    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo &bus) override {
        if (index != 0 || getBusCount(type, dir) == 0) return kInvalidArgument;
        bus.mediaType = type;
        bus.direction = dir;
        bus.channelCount = type == kAudio ? 2 : 16;
        setName(bus.name, type == kAudio ? "Main" : "Notes");
        bus.busType = kMain;
        bus.flags = BusInfo::kDefaultActive;
        return kResultOk;
    }
    tresult PLUGIN_API getRoutingInfo(RoutingInfo &, RoutingInfo &) override { return kNotImplemented; }
    tresult PLUGIN_API activateBus(MediaType, BusDirection, int32, TBool) override { return kResultOk; }
    tresult PLUGIN_API setActive(TBool) override { return kResultOk; }
    tresult PLUGIN_API setState(IBStream *s) override {
        float g = 0;
        int32 got = 0;
        if (!s || s->read(&g, sizeof g, &got) != kResultOk || got != sizeof g) return kResultFalse;
        gain_ = g;
        return kResultOk;
    }
    tresult PLUGIN_API getState(IBStream *s) override {
        float g = gain_;
        return s && s->write(&g, sizeof g) == kResultOk ? kResultOk : kResultFalse;
    }
    // IAudioProcessor
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement *, int32, SpeakerArrangement *, int32) override { return kResultOk; }
    tresult PLUGIN_API getBusArrangement(BusDirection, int32, SpeakerArrangement &arr) override { arr = SpeakerArr::kStereo; return kResultOk; }
    tresult PLUGIN_API canProcessSampleSize(int32 size) override { return size == kSample32 ? kResultOk : kResultFalse; }
    uint32 PLUGIN_API getLatencySamples() override { return synth_ ? 0 : 7; }
    tresult PLUGIN_API setupProcessing(ProcessSetup &) override { return kResultOk; }
    tresult PLUGIN_API setProcessing(TBool) override { return kResultOk; }
    uint32 PLUGIN_API getTailSamples() override { return 0; }
    tresult PLUGIN_API process(ProcessData &data) override {
        if (data.numOutputs < 1) return kResultOk;
        Sample32 **out = data.outputs[0].channelBuffers32;
        if (!synth_) {
            Sample32 **in = data.inputs[0].channelBuffers32;
            for (int c = 0; c < 2; ++c)
                for (int32 i = 0; i < data.numSamples; ++i) out[c][i] = in[c][i] * gain_;
            return kResultOk;
        }
        int32 next = 0, count = data.inputEvents ? data.inputEvents->getEventCount() : 0;
        Event e{};
        for (int32 i = 0; i < data.numSamples; ++i) {
            while (next < count && data.inputEvents->getEvent(next, e) == kResultOk && e.sampleOffset <= i) {
                if (e.type == Event::kNoteOnEvent) { level_ = e.noteOn.velocity; pitch_ = e.noteOn.pitch; }
                if (e.type == Event::kNoteOffEvent && e.noteOff.pitch == pitch_) level_ = 0;
                ++next;
            }
            out[0][i] = out[1][i] = level_;
        }
        return kResultOk;
    }

private:
    bool synth_;
    float gain_ = 0.5f, level_ = 0;
    int16 pitch_ = -1;
    uint32 refs_ = 1;
};

class Factory final : public IPluginFactory {
public:
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IPluginFactory::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) { *obj = this; return kResultOk; }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API getFactoryInfo(PFactoryInfo *info) override {
        *info = PFactoryInfo("Dalnok Tests", "", "", PFactoryInfo::kUnicode);
        return kResultOk;
    }
    int32 PLUGIN_API countClasses() override { return 2; }
    tresult PLUGIN_API getClassInfo(int32 index, PClassInfo *info) override {
        if (index == 0) { *info = PClassInfo(kGainId, PClassInfo::kManyInstances, kVstAudioEffectClass, "Dalnok Test Gain"); return kResultOk; }
        if (index == 1) { *info = PClassInfo(kSynthId, PClassInfo::kManyInstances, kVstAudioEffectClass, "Dalnok Test Synth"); return kResultOk; }
        return kInvalidArgument;
    }
    tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void **obj) override {
        const bool synth = std::memcmp(cid, kSynthId, sizeof(TUID)) == 0;
        if (!synth && std::memcmp(cid, kGainId, sizeof(TUID)) != 0) { *obj = nullptr; return kInvalidArgument; }
        auto *p = new TestPlugin(synth);
        const tresult r = p->queryInterface(iid, obj);
        p->release();
        return r;
    }
};
} // namespace

extern "C" {
SMTG_EXPORT_SYMBOL bool bundleEntry(CFBundleRef) { return true; }
SMTG_EXPORT_SYMBOL bool bundleExit() { return true; }
SMTG_EXPORT_SYMBOL IPluginFactory *PLUGIN_API GetPluginFactory() {
    static Factory factory;
    return &factory;
}
}
