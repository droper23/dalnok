// Test-only VST3 module with real processing, for scripts/ci/plugin-host.sh:
//   "Dalnok Test Gain"  (effect): out = in × gain; gain is the plugin state (float, default 0.5) and
//                                  parameter 1 "Gain" (normalized = gain). The processor sees parameter
//                                  changes only through process() (as with a separate controller);
//                                  reports 7 frames of latency (not applied, only reported). No editor view,
//                                  unless DALNOK_TEST_EDITOR=1: then a 400 × 300 NSView painted solid green
//                                  (built through the Objective-C runtime, so this file stays plain C++);
//                                  DALNOK_TEST_EDITOR_RESIZE=WxH asks the host frame for that size once attached, and
//                                  DALNOK_TEST_EDITOR_EDIT=v performs an edit of parameter 1 to v (a user edit).
//   "Dalnok Test Synth" (instrument): outputs a constant level = velocity/127 while a note is held,
//                                  switching at the exact event sample offset; 0 otherwise.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstattributes.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
#include <dlfcn.h>
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <cmath>
#include <cstring>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace Steinberg::Vst {
DEF_CLASS_IID(IComponent)
DEF_CLASS_IID(IAudioProcessor)
DEF_CLASS_IID(IEventList)
DEF_CLASS_IID(IEditController)
DEF_CLASS_IID(IHostApplication)
DEF_CLASS_IID(IMessage)
DEF_CLASS_IID(IAttributeList)
DEF_CLASS_IID(IParameterChanges)
DEF_CLASS_IID(IParamValueQueue)
DEF_CLASS_IID(IComponentHandler)
DEF_CLASS_IID(IComponentHandler2)
}
namespace Steinberg {
DEF_CLASS_IID(IPlugView)
DEF_CLASS_IID(IPlugFrame)
}

namespace {
const TUID kGainId = {'D', 'a', 'l', 'n', 'o', 'k', 'T', 'e', 's', 't', 'G', 'a', 'i', 'n', '0', '1'};
const TUID kSynthId = {'D', 'a', 'l', 'n', 'o', 'k', 'T', 'e', 's', 't', 'S', 'y', 'n', 't', 'h', '1'};
// Delays its input by exactly the latency it reports (delay compensation tests).
const TUID kDelayId = {'D', 'a', 'l', 'n', 'o', 'k', 'T', 'e', 's', 't', 'D', 'e', 'l', 'a', 'y', '1'};
// Ducks its main input by its sidechain level: out = in * (1 - min(1, |sidechain|)) (sidechain tests).
const TUID kDuckId = {'D', 'a', 'l', 'n', 'o', 'k', 'T', 'e', 's', 't', 'D', 'u', 'c', 'k', '0', '1'};
constexpr int kTestDelay = 300;

// ---- Editor view (DALNOK_TEST_EDITOR=1): an NSView made through the Objective-C runtime --------------------
struct Rect { double x, y, w, h; };
struct Size { double w, h; };
using Id = void *;
template <typename R, typename... A> R msg(Id obj, const char *sel, A... a) {
    static void *send = dlsym(RTLD_DEFAULT, "objc_msgSend");
    static auto selector = reinterpret_cast<void *(*)(const char *)>(dlsym(RTLD_DEFAULT, "sel_registerName"));
    return reinterpret_cast<R (*)(Id, void *, A...)>(send)(obj, selector(sel), a...);
}
Id cls(const char *name) { return reinterpret_cast<Id (*)(const char *)>(dlsym(RTLD_DEFAULT, "objc_getClass"))(name); }

class TestView final : public IPlugView {
public:
    TestView(IComponentHandler *handler, float *gain) : handler_(handler), gain_(gain) {}
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IPlugView::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) { *obj = this; addRef(); return kResultOk; }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return ++refs_; }
    uint32 PLUGIN_API release() override { const uint32 r = --refs_; if (!r) delete this; return r; }
    tresult PLUGIN_API isPlatformTypeSupported(FIDString type) override { return std::strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue : kResultFalse; }
    tresult PLUGIN_API attached(void *parent, FIDString) override {
        if (!parent || !cls("NSView")) return kResultFalse;
        view_ = msg<Id>(msg<Id>(cls("NSView"), "alloc"), "initWithFrame:", Rect{0, 0, double(w_), double(h_)});
        msg<void>(view_, "setWantsLayer:", true);
        Id green = msg<Id>(cls("NSColor"), "colorWithSRGBRed:green:blue:alpha:", 0.1, 0.8, 0.3, 1.0);
        msg<void>(msg<Id>(view_, "layer"), "setBackgroundColor:", msg<Id>(green, "CGColor"));
        msg<void>(static_cast<Id>(parent), "addSubview:", view_);
        if (const char *size = std::getenv("DALNOK_TEST_EDITOR_RESIZE"); size && frame_) {
            int w = 0, h = 0;
            if (std::sscanf(size, "%dx%d", &w, &h) == 2) {
                // DALNOK_TEST_EDITOR_RESIZE_LATER: ask a moment after opening, as editors that build their UI late do.
                if (std::getenv("DALNOK_TEST_EDITOR_RESIZE_LATER")) {
                    IPlugFrame *f = frame_;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300'000'000), dispatch_get_main_queue(), ^{
                        ViewRect r(0, 0, w, h);
                        f->resizeView(this, &r);
                    });
                } else {
                    ViewRect r(0, 0, w, h);
                    frame_->resizeView(this, &r);
                }
            }
        }
        // A change that is not a parameter, made without telling the host at all (DALNOK_TEST_EDITOR_SILENT).
        if (std::getenv("DALNOK_TEST_EDITOR_SILENT") && gain_) *gain_ = 0.3f;
        // A change that is not a parameter (a sound picked in the editor), reported with IComponentHandler2::setDirty.
        if (std::getenv("DALNOK_TEST_EDITOR_DIRTY") && handler_) {
            if (gain_) *gain_ = 0.3f; // the change (part of the state, not a parameter)
            IComponentHandler2 *h2 = nullptr;
            if (handler_->queryInterface(IComponentHandler2::iid, reinterpret_cast<void **>(&h2)) == kResultOk && h2) h2->setDirty(true);
        }
        if (const char *edit = std::getenv("DALNOK_TEST_EDITOR_EDIT"); edit && handler_) {
            handler_->beginEdit(1);
            handler_->performEdit(1, std::atof(edit));
            handler_->endEdit(1);
        }
        return kResultOk;
    }
    tresult PLUGIN_API removed() override {
        if (view_) { msg<void>(view_, "removeFromSuperview"); msg<void>(view_, "release"); view_ = nullptr; }
        return kResultOk;
    }
    tresult PLUGIN_API onWheel(float) override { return kResultFalse; }
    tresult PLUGIN_API onKeyDown(char16, int16, int16) override { return kResultFalse; }
    tresult PLUGIN_API onKeyUp(char16, int16, int16) override { return kResultFalse; }
    tresult PLUGIN_API getSize(ViewRect *r) override { if (!r) return kInvalidArgument; *r = ViewRect(0, 0, w_, h_); return kResultOk; }
    tresult PLUGIN_API onSize(ViewRect *r) override {
        if (!r) return kInvalidArgument;
        w_ = r->getWidth(); h_ = r->getHeight();
        if (view_) msg<void>(view_, "setFrameSize:", Size{double(w_), double(h_)});
        return kResultOk;
    }
    tresult PLUGIN_API onFocus(TBool) override { return kResultOk; }
    tresult PLUGIN_API setFrame(IPlugFrame *frame) override { frame_ = frame; return kResultOk; }
    tresult PLUGIN_API canResize() override { return kResultFalse; }
    tresult PLUGIN_API checkSizeConstraint(ViewRect *) override { return kResultOk; }
private:
    uint32 refs_ = 1;
    int32 w_ = 400, h_ = 300;
    Id view_ = nullptr;
    IPlugFrame *frame_ = nullptr;
    IComponentHandler *handler_ = nullptr;
    float *gain_ = nullptr;
};

void setName(String128 out, const char *s) {
    int i = 0;
    for (; s[i] && i < 127; ++i) out[i] = static_cast<char16>(s[i]);
    out[i] = 0;
}

class TestPlugin final : public IComponent, public IAudioProcessor, public IEditController {
public:
    explicit TestPlugin(bool synth, bool delay = false, bool duck = false) : synth_(synth), delay_(delay), duck_(duck) {}
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IAudioProcessor::iid)) { *obj = static_cast<IAudioProcessor *>(this); addRef(); return kResultOk; }
        if (FUnknownPrivate::iidEqual(iid, IEditController::iid)) { *obj = static_cast<IEditController *>(this); addRef(); return kResultOk; }
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
    // Like many real plug-ins: build a message through the host (as for IConnectionPoint traffic) and refuse a host
    // that cannot make one, rather than crash on it.
    tresult PLUGIN_API initialize(FUnknown *context) override {
        if (const char *mode = std::getenv("DALNOK_TEST_INIT_FAILURE")) {
            if (const char *marker = std::getenv("DALNOK_TEST_INIT_MARKER")) {
                if (FILE *f = std::fopen(marker, "w")) { std::fputs("initialized", f); std::fclose(f); }
            }
            if (std::strcmp(mode, "crash") == 0) std::abort();
            if (std::strcmp(mode, "hang") == 0) for (;;) ::sleep(1);
            // A plug-in that blocks its own initialization for a while (license checks, sample loading): A-08.
            if (std::strcmp(mode, "slow") == 0) {
                const char *ms = std::getenv("DALNOK_TEST_INIT_SLOW_MS");
                ::usleep(static_cast<useconds_t>((ms ? std::atoi(ms) : 3000) * 1000));
            }
        }
        // A plug-in whose main-thread work keeps the host's run loop busy (timers, UI refresh, locks held by its
        // own threads): DALNOK_TEST_MAIN_BUSY=1 sleeps 200 ms in a main-thread timer every millisecond.
        if (std::getenv("DALNOK_TEST_MAIN_BUSY")) {
            CFRunLoopTimerRef t = CFRunLoopTimerCreateWithHandler(nullptr, CFAbsoluteTimeGetCurrent(), 0.001, 0, 0,
                                                                  ^(CFRunLoopTimerRef) { ::usleep(200'000); });
            CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
        }
        IHostApplication *host = nullptr;
        if (!context || context->queryInterface(IHostApplication::iid, reinterpret_cast<void **>(&host)) != kResultOk || !host) return kResultFalse;
        TUID id;
        std::memcpy(id, IMessage::iid, sizeof id);
        IMessage *msg = nullptr;
        bool ok = host->createInstance(id, id, reinterpret_cast<void **>(&msg)) == kResultOk && msg;
        if (ok) {
            msg->setMessageID("dalnok-test");
            IAttributeList *a = msg->getAttributes();
            int64 v = 0;
            const char blob[3] = {1, 2, 3};
            const void *data = nullptr;
            uint32 size = 0;
            ok = a && a->setInt("n", 42) == kResultOk && a->getInt("n", v) == kResultOk && v == 42
                && a->setBinary("b", blob, 3) == kResultOk && a->getBinary("b", data, size) == kResultOk && size == 3
                && std::strcmp(msg->getMessageID(), "dalnok-test") == 0;
        }
        if (msg) msg->release();
        host->release();
        return ok ? kResultOk : kResultFalse;
    }
    tresult PLUGIN_API terminate() override { return kResultOk; }
    // IComponent
    tresult PLUGIN_API getControllerClassId(TUID) override { return kResultFalse; }
    tresult PLUGIN_API setIoMode(IoMode) override { return kResultOk; }
    int32 PLUGIN_API getBusCount(MediaType type, BusDirection dir) override {
        if (type == kAudio) return dir == kOutput ? 1 : synth_ ? 0 : duck_ ? 2 : 1; // the duck has a sidechain bus
        return type == kEvent && dir == kInput && synth_ ? 1 : 0;
    }
    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo &bus) override {
        if (index < 0 || index >= getBusCount(type, dir)) return kInvalidArgument;
        bus.mediaType = type;
        bus.direction = dir;
        bus.channelCount = type == kAudio ? 2 : 16;
        setName(bus.name, type == kAudio ? "Main" : "Notes");
        bus.busType = index == 0 ? kMain : kAux;
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
        // Many plug-ins report their restored values through performEdit (DALNOK_TEST_STATE_EDIT=1 behaves so).
        if (std::getenv("DALNOK_TEST_STATE_EDIT") && handler_) handler_->performEdit(1, g);
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
    uint32 PLUGIN_API getLatencySamples() override { return synth_ || duck_ ? 0 : delay_ ? kTestDelay : 7; } // and really delays by it
    tresult PLUGIN_API setupProcessing(ProcessSetup &) override { return kResultOk; }
    tresult PLUGIN_API setProcessing(TBool) override { return kResultOk; }
    uint32 PLUGIN_API getTailSamples() override { return 0; }
    // IEditController (single component). The displayed value is separate from the processor's gain.
    tresult PLUGIN_API setComponentState(IBStream *s) override {
        float g = 0;
        int32 got = 0;
        if (s && s->read(&g, sizeof g, &got) == kResultOk && got == sizeof g) shown_ = g;
        return kResultOk;
    }
    int32 PLUGIN_API getParameterCount() override { return synth_ ? 0 : 1; }
    tresult PLUGIN_API getParameterInfo(int32 index, ParameterInfo &info) override {
        if (synth_ || index != 0) return kInvalidArgument;
        info = ParameterInfo{};
        info.id = 1;
        setName(info.title, "Gain");
        setName(info.units, "%");
        info.defaultNormalizedValue = 0.5;
        info.flags = ParameterInfo::kCanAutomate;
        return kResultOk;
    }
    tresult PLUGIN_API getParamStringByValue(ParamID id, ParamValue v, String128 out) override {
        if (id != 1) return kInvalidArgument;
        char buf[32];
        std::snprintf(buf, sizeof buf, "%.0f %%", v * 100);
        setName(out, buf);
        return kResultOk;
    }
    tresult PLUGIN_API getParamValueByString(ParamID, TChar *, ParamValue &) override { return kNotImplemented; }
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID, ParamValue v) override { return v; }
    ParamValue PLUGIN_API plainParamToNormalized(ParamID, ParamValue v) override { return v; }
    ParamValue PLUGIN_API getParamNormalized(ParamID id) override { return id == 1 ? shown_ : 0; }
    tresult PLUGIN_API setParamNormalized(ParamID id, ParamValue v) override { if (id == 1) shown_ = v; return kResultOk; }
    tresult PLUGIN_API setComponentHandler(IComponentHandler *h) override { handler_ = h; return kResultOk; }
    IPlugView *PLUGIN_API createView(FIDString name) override {
        const char *on = std::getenv("DALNOK_TEST_EDITOR");
        if (!on || std::strcmp(on, "1") != 0 || !name || std::strcmp(name, ViewType::kEditor) != 0) return nullptr;
        return new TestView(handler_, &gain_);
    }

    tresult PLUGIN_API process(ProcessData &data) override {
        // Isolation tests (ADR-0014): crash or hang after a few blocks, as a faulty plug-in would mid-session.
        if (const char *mode = std::getenv("DALNOK_TEST_PROCESS_FAILURE"); mode && data.numSamples > 0) {
            const char *after = std::getenv("DALNOK_TEST_PROCESS_AFTER");
            if (++blocks_ > (after ? std::atoi(after) : 4)) {
                if (std::strcmp(mode, "crash") == 0) std::abort();
                if (std::strcmp(mode, "hang") == 0) for (;;) ::sleep(1);
            }
        }
        if (data.numOutputs < 1) return kResultOk;
        if (IParameterChanges *pc = data.inputParameterChanges) {
            for (int32 i = 0; i < pc->getParameterCount(); ++i) {
                IParamValueQueue *q = pc->getParameterData(i);
                int32 offset = 0;
                ParamValue v = 0;
                if (q && q->getParameterId() == 1 && q->getPointCount() > 0 && q->getPoint(q->getPointCount() - 1, offset, v) == kResultOk)
                    gain_ = static_cast<float>(v);
            }
        }
        Sample32 **out = data.outputs[0].channelBuffers32;
        if (duck_) {
            Sample32 **in = data.inputs[0].channelBuffers32;
            Sample32 **sc = data.numInputs > 1 ? data.inputs[1].channelBuffers32 : nullptr;
            for (int32 i = 0; i < data.numSamples; ++i) {
                const float level = sc ? std::fabs(sc[0][i]) : 0.0f;
                const float g = 1.0f - (level > 1.0f ? 1.0f : level);
                out[0][i] = in[0][i] * g;
                out[1][i] = in[1][i] * g;
            }
            return kResultOk;
        }
        if (!synth_) {
            // Effects delay their output by exactly the latency they report (gain: 7 frames, delay: 300).
            const int latency = delay_ ? kTestDelay : 7;
            const float g = delay_ ? 1.0f : gain_;
            Sample32 **in = data.inputs[0].channelBuffers32;
            for (int32 i = 0; i < data.numSamples; ++i) {
                for (int c = 0; c < 2; ++c) {
                    const float x = in[c][i] * g;
                    out[c][i] = line_[c][pos_];
                    line_[c][pos_] = x;
                }
                pos_ = (pos_ + 1) % latency;
            }
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
        // Like sample players that finish loading in their first blocks: silent for the first N process calls
        // (DALNOK_TEST_SYNTH_WARMUP_BLOCKS).
        if (const char *n = std::getenv("DALNOK_TEST_SYNTH_WARMUP_BLOCKS"); n && warmed_ < std::atoi(n)) {
            ++warmed_;
            for (int32 i = 0; i < data.numSamples; ++i) out[0][i] = out[1][i] = 0;
        }
        return kResultOk;
    }

private:
    bool synth_, delay_, duck_;
    float line_[2][kTestDelay] = {};
    int pos_ = 0;
    int blocks_ = 0, warmed_ = 0;
    float gain_ = 0.5f, level_ = 0;
    double shown_ = 0.5;
    IComponentHandler *handler_ = nullptr;
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
    int32 PLUGIN_API countClasses() override { return 4; }
    tresult PLUGIN_API getClassInfo(int32 index, PClassInfo *info) override {
        if (index == 0) { *info = PClassInfo(kGainId, PClassInfo::kManyInstances, kVstAudioEffectClass, "Dalnok Test Gain"); return kResultOk; }
        if (index == 1) { *info = PClassInfo(kSynthId, PClassInfo::kManyInstances, kVstAudioEffectClass, "Dalnok Test Synth"); return kResultOk; }
        if (index == 2) { *info = PClassInfo(kDelayId, PClassInfo::kManyInstances, kVstAudioEffectClass, "Dalnok Test Delay"); return kResultOk; }
        if (index == 3) { *info = PClassInfo(kDuckId, PClassInfo::kManyInstances, kVstAudioEffectClass, "Dalnok Test Duck"); return kResultOk; }
        return kInvalidArgument;
    }
    tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void **obj) override {
        const bool synth = std::memcmp(cid, kSynthId, sizeof(TUID)) == 0, delay = std::memcmp(cid, kDelayId, sizeof(TUID)) == 0,
                   duck = std::memcmp(cid, kDuckId, sizeof(TUID)) == 0;
        if (!synth && !delay && !duck && std::memcmp(cid, kGainId, sizeof(TUID)) != 0) { *obj = nullptr; return kInvalidArgument; }
        auto *p = new TestPlugin(synth, delay, duck);
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
