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
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "pluginterfaces/gui/iplugview.h"
#pragma clang diagnostic pop

#include <CoreFoundation/CoreFoundation.h>
#include <algorithm>
#include <array>
#include <atomic>
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

// Fixed-capacity parameter changes for one block: one point per parameter (the latest value).
class BlockParamQueue final : public IParamValueQueue {
public:
    ParamID id = 0;
    ParamValue value = 0;
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IParamValueQueue::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) { *obj = this; return kResultOk; }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    ParamID PLUGIN_API getParameterId() override { return id; }
    int32 PLUGIN_API getPointCount() override { return 1; }
    tresult PLUGIN_API getPoint(int32 index, int32 &offset, ParamValue &v) override {
        if (index != 0) return kInvalidArgument;
        offset = 0;
        v = value;
        return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32, ParamValue, int32 &) override { return kResultFalse; }
};
class BlockParamChanges final : public IParameterChanges {
public:
    std::array<BlockParamQueue, 64> queues;
    int32 count = 0;
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IParameterChanges::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) { *obj = this; return kResultOk; }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    int32 PLUGIN_API getParameterCount() override { return count; }
    IParamValueQueue *PLUGIN_API getParameterData(int32 index) override {
        return index >= 0 && index < count ? &queues[static_cast<size_t>(index)] : nullptr;
    }
    IParamValueQueue *PLUGIN_API addParameterData(const ParamID &, int32 &index) override { index = -1; return nullptr; }
    // Audio thread: returns false when full (the change waits for the next block).
    bool set(ParamID id, ParamValue v) DALNOK_NONBLOCKING {
        for (int32 i = 0; i < count; ++i)
            if (queues[static_cast<size_t>(i)].id == id) { queues[static_cast<size_t>(i)].value = v; return true; }
        if (count >= static_cast<int32>(queues.size())) return false;
        queues[static_cast<size_t>(count)].id = id;
        queues[static_cast<size_t>(count)].value = v;
        ++count;
        return true;
    }
};

struct ParamChange { uint32 id; double value; };

std::string utf8(const char16 *s, size_t max) {
    std::string out;
    for (size_t i = 0; i < max && s[i]; ++i) {
        const uint32_t c = static_cast<uint16_t>(s[i]);
        if (c < 0x80) out += static_cast<char>(c);
        else if (c < 0x800) { out += static_cast<char>(0xC0 | (c >> 6)); out += static_cast<char>(0x80 | (c & 63)); }
        else { out += static_cast<char>(0xE0 | (c >> 12)); out += static_cast<char>(0x80 | ((c >> 6) & 63)); out += static_cast<char>(0x80 | (c & 63)); }
    }
    return out;
}

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

class Vst3Processor;

// Receives edits from the plugin's controller (its editor) and forwards them to the processor.
class ComponentHandler final : public IComponentHandler {
public:
    Vst3Processor *owner = nullptr;
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IComponentHandler::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) { *obj = this; return kResultOk; }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue v) override;
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32) override { return kResultOk; }
};

// Hosts the editor view and passes its resize requests to the window.
class PlugFrame final : public IPlugFrame {
public:
    void (*onResize)(void *, int32_t, int32_t) = nullptr;
    void *ctx = nullptr;
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IPlugFrame::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) { *obj = this; return kResultOk; }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *r) override {
        if (!view || !r) return kInvalidArgument;
        if (onResize) onResize(ctx, r->getWidth(), r->getHeight());
        view->onSize(r);
        return kResultOk;
    }
};

class Vst3Processor final : public PluginProcessor {
public:
    ~Vst3Processor() override {
        closeEditor();
        if (cpComponent_ && cpController_) { cpComponent_->disconnect(cpController_); cpController_->disconnect(cpComponent_); }
        if (cpComponent_) cpComponent_->release();
        if (cpController_) cpController_->release();
        if (controller_) {
            controller_->setComponentHandler(nullptr);
            if (!singleComponent_) controller_->terminate();
            controller_->release();
        }
        if (processor_) { processor_->setProcessing(false); processor_->release(); }
        if (component_) { component_->setActive(false); component_->terminate(); component_->release(); }
    }

    // Control side (main thread, or a plugin thread inside performEdit): serialized by a lock that the
    // audio thread never takes; the queue itself is single-producer/single-consumer.
    void pushChange(uint32 id, double v, bool fromEditor) {
        std::lock_guard<std::mutex> g(producer_);
        touched_[id] = v;
        if (!changes_.push(ParamChange{id, v})) dropped_.fetch_add(1, std::memory_order_relaxed);
        if (fromEditor) edits_.fetch_add(1, std::memory_order_relaxed);
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
        // Edit controller: the same object (single component) or a separate class, connected both ways.
        if (component_->queryInterface(IEditController::iid, reinterpret_cast<void **>(&controller_)) == kResultOk && controller_) {
            singleComponent_ = true;
        } else {
            controller_ = nullptr;
            TUID ccid{};
            if (component_->getControllerClassId(ccid) == kResultOk &&
                m.factory->createInstance(ccid, IEditController::iid, reinterpret_cast<void **>(&controller_)) == kResultOk && controller_) {
                if (controller_->initialize(&gHost) != kResultOk) { controller_->release(); controller_ = nullptr; }
            } else {
                controller_ = nullptr;
            }
            if (controller_ &&
                component_->queryInterface(IConnectionPoint::iid, reinterpret_cast<void **>(&cpComponent_)) == kResultOk &&
                controller_->queryInterface(IConnectionPoint::iid, reinterpret_cast<void **>(&cpController_)) == kResultOk &&
                cpComponent_ && cpController_) {
                cpComponent_->connect(cpController_);
                cpController_->connect(cpComponent_);
            }
        }
        handler_.owner = this;
        if (controller_) controller_->setComponentHandler(&handler_);
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
        syncController();
        return true;
    }

    // The controller mirrors the component's state (parameter values shown in editors and panels).
    void syncController() {
        if (!controller_ || singleComponent_) return;
        MemoryStream s;
        if (component_->getState(&s) != kResultOk) return;
        s.pos = 0;
        controller_->setComponentState(&s);
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
        // Parameter changes since the last block (latest value per parameter).
        paramChanges_.count = 0;
        ParamChange c;
        while (paramChanges_.count < static_cast<int32>(paramChanges_.queues.size()) && changes_.pop(c)) paramChanges_.set(c.id, c.value);
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
        data.inputParameterChanges = paramChanges_.count ? &paramChanges_ : nullptr;
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
        if (component_->setState(&s) != kResultOk) return false;
        syncController();
        std::lock_guard<std::mutex> g(producer_);
        touched_.clear();
        return true;
    }

    int32_t parameterCount() override { return controller_ ? controller_->getParameterCount() : 0; }
    bool parameter(int32_t index, PluginParameter &out) override {
        ParameterInfo info{};
        if (!controller_ || controller_->getParameterInfo(index, info) != kResultOk) return false;
        out.id = info.id;
        out.title = utf8(info.title, 128);
        out.units = utf8(info.units, 128);
        out.stepCount = info.stepCount;
        out.defaultValue = info.defaultNormalizedValue;
        out.value = controller_->getParamNormalized(info.id);
        out.automatable = info.flags & ParameterInfo::kCanAutomate;
        out.readOnly = info.flags & ParameterInfo::kIsReadOnly;
        out.hidden = info.flags & ParameterInfo::kIsHidden;
        String128 text{};
        if (controller_->getParamStringByValue(info.id, out.value, text) == kResultOk) out.display = utf8(text, 128);
        return true;
    }
    bool setParameter(uint32_t id, double v) override {
        if (!(v >= 0 && v <= 1)) return false;
        if (controller_) controller_->setParamNormalized(id, v);
        pushChange(id, v, false);
        return true;
    }
    void touchedParameters(std::vector<std::pair<uint32_t, double>> &out) override {
        std::lock_guard<std::mutex> g(producer_);
        out.assign(touched_.begin(), touched_.end());
    }
    uint64_t editCount() const override { return edits_.load(std::memory_order_relaxed); }

    bool hasEditor() override { return controller_ != nullptr; }
    bool openEditor(void *parent, int32_t &w, int32_t &h, void (*onResize)(void *, int32_t, int32_t), void *ctx,
                    std::string &err) override {
        closeEditor();
        if (!controller_) { err = "this plug-in has no editor"; return false; }
        view_ = controller_->createView(ViewType::kEditor);
        if (!view_) { err = "this plug-in has no editor"; return false; }
        if (view_->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) {
            view_->release(); view_ = nullptr;
            err = "the editor does not support macOS views";
            return false;
        }
        frame_.onResize = onResize;
        frame_.ctx = ctx;
        view_->setFrame(&frame_);
        if (view_->attached(parent, kPlatformTypeNSView) != kResultOk) {
            view_->release(); view_ = nullptr;
            err = "the editor could not be opened";
            return false;
        }
        ViewRect r{};
        view_->getSize(&r);
        w = r.getWidth();
        h = r.getHeight();
        return true;
    }
    void closeEditor() override {
        if (!view_) return;
        view_->removed();
        view_->setFrame(nullptr);
        view_->release();
        view_ = nullptr;
    }

private:
    IComponent *component_ = nullptr;
    IAudioProcessor *processor_ = nullptr;
    IEditController *controller_ = nullptr;
    IConnectionPoint *cpComponent_ = nullptr, *cpController_ = nullptr;
    IPlugView *view_ = nullptr;
    bool singleComponent_ = false;
    ComponentHandler handler_;
    PlugFrame frame_;
    SpscQueue<ParamChange, 1024> changes_;
    BlockParamChanges paramChanges_;
    std::mutex producer_;
    std::map<uint32_t, double> touched_;
    std::atomic<uint64_t> edits_{0}, dropped_{0};
    BlockEvents events_;
    std::vector<float> scratchL_, scratchR_;
    std::string name_, vendor_, classId_, subCategories_;
    bool instrument_ = false, hasInput_ = false, hasEvents_ = false;
};
tresult PLUGIN_API ComponentHandler::performEdit(ParamID id, ParamValue v) {
    if (owner) owner->pushChange(id, v, true);
    return kResultOk;
}
} // namespace

std::unique_ptr<PluginProcessor> loadVst3(const std::string &bundle, const std::string &classId, double sampleRate,
                                          int maxBlock, bool offline, std::string &err) {
    Module m;
    if (!openModule(bundle, m, err)) return nullptr;
    auto p = std::make_unique<Vst3Processor>();
    if (!p->open(m, classId, sampleRate, maxBlock, offline, err)) return nullptr;
    return p;
}

std::unique_ptr<PluginProcessor> loadPlugin(const std::string &format, const std::string &path, const std::string &classId,
                                            double sampleRate, int maxBlock, bool offline, std::string &err) {
    if (format == "au") return loadAudioUnit(path, sampleRate, maxBlock, err);
    if (format == "vst3") return loadVst3(path, classId, sampleRate, maxBlock, offline, err);
    err = "unsupported plug-in format " + format;
    return nullptr;
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
