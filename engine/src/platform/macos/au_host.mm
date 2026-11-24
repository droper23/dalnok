// Audio Unit hosting on macOS (ADR-0009): effects and instruments through the AUv2 API (AUv3 units are
// reached through the system's v2 bridge). Same PluginProcessor contract as VST3: configured on the
// control thread; AudioUnitRender runs on the audio thread as the one unverifiable call.
// Identifier: "type:subtype:manufacturer" four-character codes, e.g. "aufx:dely:appl".
// SPDX-License-Identifier: GPL-3.0-or-later
#include "plugin_host.hpp"
#include "rt.hpp"

#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>
#import <AVFoundation/AVFoundation.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <map>
#include <mutex>
#include <vector>

namespace dalnok {
namespace {

OSType fourCC(const std::string &s, size_t at) {
    return static_cast<OSType>((static_cast<unsigned char>(s[at]) << 24) | (static_cast<unsigned char>(s[at + 1]) << 16) |
                               (static_cast<unsigned char>(s[at + 2]) << 8) | static_cast<unsigned char>(s[at + 3]));
}

// Some Apple units (e.g. the DLS synth) share global state between instances, and Core Audio does not
// promise that instance creation and teardown are thread-safe. Lifecycle calls run off the audio thread.
std::mutex &lifecycleLock() { static std::mutex m; return m; }

struct ParamChange { AudioUnitParameterID id; double value; };

class AudioUnitProcessor;
// The event listener's user data. Its notifications arrive on the main run loop's timer, while a unit can be destroyed on
// any thread: the destructor detaches under `m` (so a notification never touches a freed unit) and the listener is
// disposed on the main thread, where its timer runs (disposing it elsewhere raced AudioToolbox's timer: ASan SEGV in
// CAEventReceiver::timerFired).
struct ListenerContext { std::mutex m; AudioUnitProcessor *owner = nullptr; };

class AudioUnitProcessor final : public PluginProcessor {
public:
    ~AudioUnitProcessor() override {
        closeEditor();
        if (listener_) {
            { std::lock_guard<std::mutex> g(listenerCtx_->m); listenerCtx_->owner = nullptr; }
            AUEventListenerRef l = listener_;
            ListenerContext *c = listenerCtx_;
            if (pthread_main_np()) { AUListenerDispose(l); delete c; }
            else dispatch_async(dispatch_get_main_queue(), ^{ AUListenerDispose(l); delete c; });
        } else delete listenerCtx_;
        if (unit_) {
            std::lock_guard<std::mutex> g(lifecycleLock());
            AudioUnitUninitialize(unit_);
            AudioComponentInstanceDispose(unit_);
        }
    }

    bool open(const std::string &id, double rate, int maxBlock, std::string &err) {
        if (id.size() != 14 || id[4] != ':' || id[9] != ':') { err = "expected an Audio Unit id type:subtype:manufacturer"; return false; }
        AudioComponentDescription desc{fourCC(id, 0), fourCC(id, 5), fourCC(id, 10), 0, 0};
        AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
        if (!comp) { err = "Audio Unit not installed"; return false; }
        std::lock_guard<std::mutex> lifecycle(lifecycleLock());
        if (AudioComponentInstanceNew(comp, &unit_) != noErr || !unit_) { err = "cannot create the Audio Unit"; return false; }
        classId_ = id;
        instrument_ = desc.componentType == kAudioUnitType_MusicDevice;
        // The system's tags for the component ("Delay", "Dynamics", "EQ"…) and its type name.
        AVAudioUnitComponent *info = [[[AVAudioUnitComponentManager sharedAudioUnitComponentManager] componentsMatchingDescription:desc] firstObject];
        for (NSString *tag in info.allTagNames) categories_ += (categories_.empty() ? "" : "|") + std::string(tag.UTF8String);
        if (info.typeName.length) categories_ += (categories_.empty() ? "" : "|") + std::string(info.typeName.UTF8String);
        CFStringRef name = nullptr;
        if (AudioComponentCopyName(comp, &name) == noErr && name) {
            NSString *full = (__bridge NSString *)name;
            NSRange colon = [full rangeOfString:@": "];
            vendor_ = colon.location == NSNotFound ? "" : std::string([[full substringToIndex:colon.location] UTF8String]);
            name_ = std::string([(colon.location == NSNotFound ? full : [full substringFromIndex:colon.location + 2]) UTF8String]);
            CFRelease(name);
        }
        // Non-interleaved float stereo in and out at the engine rate.
        AudioStreamBasicDescription fmt{};
        fmt.mSampleRate = rate;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) | kAudioFormatFlagIsNonInterleaved;
        fmt.mChannelsPerFrame = 2;
        fmt.mFramesPerPacket = 1;
        fmt.mBitsPerChannel = 32;
        fmt.mBytesPerFrame = fmt.mBytesPerPacket = 4;
        if (AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, sizeof fmt) != noErr) {
            err = "the Audio Unit does not accept stereo float output"; return false;
        }
        if (!instrument_) {
            if (AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt) != noErr) {
                err = "the Audio Unit does not accept stereo float input"; return false;
            }
            AURenderCallbackStruct cb{&AudioUnitProcessor::provideInput, this};
            AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
            // Sidechain: a second input bus (element 1) that takes stereo float gets the track's sidechain feed.
            UInt32 buses = 0, size = sizeof buses;
            if (AudioUnitGetProperty(unit_, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &buses, &size) == noErr && buses > 1 &&
                AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &fmt, sizeof fmt) == noErr) {
                AURenderCallbackStruct sc{&AudioUnitProcessor::provideSidechain, this};
                sidechain_ = AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 1, &sc, sizeof sc) == noErr;
            }
        }
        UInt32 frames = static_cast<UInt32>(maxBlock);
        AudioUnitSetProperty(unit_, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, sizeof frames);
        if (AudioUnitInitialize(unit_) != noErr) { err = "the Audio Unit failed to initialize"; return false; }
        listenForEdits();
        inL_.assign(static_cast<size_t>(maxBlock), 0.0f);
        inR_.assign(static_cast<size_t>(maxBlock), 0.0f);
        time_.mFlags = kAudioTimeStampSampleTimeValid;
        return true;
    }

    bool instrument() const override { return instrument_; }
    uint32_t latency() const override {
        Float64 seconds = 0;
        UInt32 size = sizeof seconds;
        AudioUnitGetProperty(unit_, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size);
        UInt32 rateSize = sizeof(Float64);
        Float64 rate = 0;
        AudioStreamBasicDescription fmt{};
        UInt32 fsize = sizeof fmt;
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, &fsize) == noErr) rate = fmt.mSampleRate;
        (void)rateSize;
        return static_cast<uint32_t>(seconds * rate + 0.5);
    }
    const std::string &name() const override { return name_; }
    const std::string &vendor() const override { return vendor_; }
    const std::string &classId() const override { return classId_; }

    static OSStatus provideInput(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
                                 AudioBufferList *data) DALNOK_NONBLOCKING {
        auto *self = static_cast<AudioUnitProcessor *>(ref);
        const float *src[2] = {self->inL_.data(), self->inR_.data()};
        for (UInt32 b = 0; b < data->mNumberBuffers && b < 2; ++b) {
            auto *dst = static_cast<float *>(data->mBuffers[b].mData);
            for (UInt32 i = 0; i < frames; ++i) dst[i] = src[b][i];
        }
        return noErr;
    }

    bool hasSidechain() const override { return sidechain_; }
    static OSStatus provideSidechain(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
                                     AudioBufferList *data) DALNOK_NONBLOCKING {
        auto *self = static_cast<AudioUnitProcessor *>(ref);
        const float *src[2] = {self->scL_, self->scR_ ? self->scR_ : self->scL_};
        for (UInt32 b = 0; b < data->mNumberBuffers && b < 2; ++b) {
            auto *dst = static_cast<float *>(data->mBuffers[b].mData);
            for (UInt32 i = 0; i < frames; ++i) dst[i] = src[b] ? src[b][i] : 0.0f;
        }
        return noErr;
    }

    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override {
        for (int i = 0; i < frames; ++i) { inL_[static_cast<size_t>(i)] = left[i]; inR_[static_cast<size_t>(i)] = right[i]; }
        struct { UInt32 count; AudioBuffer buffers[2]; } out{2, {{1, static_cast<UInt32>(frames) * 4, left}, {1, static_cast<UInt32>(frames) * 4, right}}};
        AudioUnitRenderActionFlags flags = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        // Plugin code (ADR-0009): parameters and note events first, then render.
        ParamChange c;
        while (changes_.pop(c)) AudioUnitSetParameter(unit_, c.id, kAudioUnitScope_Global, 0, static_cast<AudioUnitParameterValue>(c.value), 0);
        for (int i = 0; i < autoCount_; ++i) // automation (plain values; see automationRange)
            AudioUnitSetParameter(unit_, autoQueue_[i].id, kAudioUnitScope_Global, 0, static_cast<AudioUnitParameterValue>(autoQueue_[i].value), 0);
        autoCount_ = 0;
        for (int i = 0; i < noteCount; ++i) {
            const PluginNote &n = notes[i];
            const UInt32 status = n.on == kEventNoteOn ? 0x90u : n.on == kEventControl ? 0xB0u : n.on == kEventPitchBend ? 0xE0u : 0x80u;
            MusicDeviceMIDIEvent(unit_, status, n.pitch, n.on == kEventNoteOff ? 0u : n.velocity, static_cast<UInt32>(n.offset));
        }
        const OSStatus s = AudioUnitRender(unit_, &flags, &time_, 0, static_cast<UInt32>(frames), reinterpret_cast<AudioBufferList *>(&out));
#pragma clang diagnostic pop
        if (s != noErr) for (int i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
        time_.mSampleTime += frames;
    }

    // State: the unit's class info property list, stored as a binary plist.
    bool getState(std::string &bytes) override {
        CFPropertyListRef plist = nullptr;
        UInt32 size = sizeof plist;
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &plist, &size) != noErr || !plist) return false;
        CFDataRef data = CFPropertyListCreateData(nullptr, plist, kCFPropertyListBinaryFormat_v1_0, 0, nullptr);
        CFRelease(plist);
        if (!data) return false;
        bytes.assign(reinterpret_cast<const char *>(CFDataGetBytePtr(data)), static_cast<size_t>(CFDataGetLength(data)));
        CFRelease(data);
        return true;
    }
    bool setState(const std::string &bytes) override { return applyState(bytes, false); }
    bool setStateFromDocument(const std::string &bytes) override { return applyState(bytes, true); }
    bool applyState(const std::string &bytes, bool fromDocument) {
        stateError_.clear();
        CFDataRef data = CFDataCreate(nullptr, reinterpret_cast<const UInt8 *>(bytes.data()), static_cast<CFIndex>(bytes.size()));
        CFPropertyListRef plist = data ? CFPropertyListCreateWithData(nullptr, data, kCFPropertyListImmutable, nullptr, nullptr) : nullptr;
        if (data) CFRelease(data);
        if (!plist) { stateError_ = "invalid Audio Unit state"; return false; }
        // Apple specifies document-specific restoration first, with the normal class-info property as
        // fallback on any error. Direct preset/state changes keep using the normal property.
        OSStatus status = fromDocument ? AudioUnitSetProperty(unit_, kAudioUnitProperty_ClassInfoFromDocument,
                                                               kAudioUnitScope_Global, 0, &plist, sizeof plist)
                                       : kAudioUnitErr_InvalidProperty;
        if (status != noErr)
            status = AudioUnitSetProperty(unit_, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &plist, sizeof plist);
        const bool ok = status == noErr;
        if (status == kAudioUnitErr_Unauthorized) stateError_ = "Audio Unit reported an authorization error";
        else if (!ok) stateError_ = "Audio Unit error " + std::to_string(status);
        CFRelease(plist);
        if (ok) {
            preset_ = currentPreset(); // restoring is not an edit
            rememberValues();
            AudioUnitParameter changed{unit_, kAUParameterListener_AnyParameter, kAudioUnitScope_Global, 0};
            AUParameterListenerNotify(nullptr, nullptr, &changed);
            std::lock_guard<std::mutex> g(producer_);
            touched_.clear();
        }
        return ok;
    }

    std::string stateError() const override { return stateError_; }

    // Parameters: normalized over each parameter's own range.
    std::vector<AudioUnitParameterID> ids() const {
        UInt32 size = 0;
        if (AudioUnitGetPropertyInfo(unit_, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, nullptr) != noErr) return {};
        std::vector<AudioUnitParameterID> list(size / sizeof(AudioUnitParameterID));
        if (!list.empty()) AudioUnitGetProperty(unit_, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, list.data(), &size);
        return list;
    }
    bool info(AudioUnitParameterID id, AudioUnitParameterInfo &out) const {
        UInt32 size = sizeof out;
        return AudioUnitGetProperty(unit_, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &out, &size) == noErr;
    }
    static std::string format(const AudioUnitParameterInfo &pi, double v) {
        char text[64];
        snprintf(text, sizeof text, pi.maxValue - pi.minValue >= 100 || pi.unit == kAudioUnitParameterUnit_Indexed ? "%.0f" : "%.2f", v);
        return text;
    }
    bool parameterText(uint32_t id, double normalized, std::string &out) override {
        AudioUnitParameterInfo pi{};
        if (!info(id, pi)) return false;
        if ((pi.flags & kAudioUnitParameterFlag_CFNameRelease) && pi.cfNameString) CFRelease(pi.cfNameString);
        out = format(pi, pi.minValue + std::clamp(normalized, 0.0, 1.0) * (pi.maxValue - pi.minValue));
        return true;
    }
    std::string categories() const override { return categories_; }
    int32_t parameterCount() override { return static_cast<int32_t>(ids().size()); }
    bool parameter(int32_t index, PluginParameter &out) override {
        const auto list = ids();
        if (index < 0 || index >= static_cast<int32_t>(list.size())) return false;
        AudioUnitParameterInfo pi{};
        if (!info(list[static_cast<size_t>(index)], pi)) return false;
        out.id = list[static_cast<size_t>(index)];
        out.title = pi.cfNameString ? std::string([(__bridge NSString *)pi.cfNameString UTF8String]) : std::string(pi.name);
        if ((pi.flags & kAudioUnitParameterFlag_CFNameRelease) && pi.cfNameString) CFRelease(pi.cfNameString);
        const double span = pi.maxValue - pi.minValue;
        AudioUnitParameterValue v = 0;
        AudioUnitGetParameter(unit_, out.id, kAudioUnitScope_Global, 0, &v);
        out.value = span > 0 ? (v - pi.minValue) / span : 0;
        out.defaultValue = span > 0 ? (pi.defaultValue - pi.minValue) / span : 0;
        out.stepCount = pi.unit == kAudioUnitParameterUnit_Boolean ? 1
                        : pi.unit == kAudioUnitParameterUnit_Indexed ? static_cast<int32_t>(span) : 0;
        out.readOnly = !(pi.flags & kAudioUnitParameterFlag_IsWritable);
        out.automatable = !out.readOnly;
        out.display = format(pi, v);
        static const std::map<AudioUnitParameterUnit, const char *> units = {
            {kAudioUnitParameterUnit_Hertz, "Hz"}, {kAudioUnitParameterUnit_Decibels, "dB"}, {kAudioUnitParameterUnit_Seconds, "s"},
            {kAudioUnitParameterUnit_Milliseconds, "ms"}, {kAudioUnitParameterUnit_Percent, "%"}, {kAudioUnitParameterUnit_EqualPowerCrossfade, "%"},
            {kAudioUnitParameterUnit_Cents, "cents"}, {kAudioUnitParameterUnit_RelativeSemiTones, "st"}};
        if (auto it = units.find(pi.unit); it != units.end()) out.units = it->second;
        return true;
    }
    bool automationRange(uint32_t id, double &lo, double &hi) override {
        AudioUnitParameterInfo pi{};
        if (!info(id, pi)) return false;
        lo = pi.minValue; hi = pi.maxValue;
        return true;
    }
    bool setParameter(uint32_t id, double normalized) override {
        AudioUnitParameterInfo pi{};
        if (!(normalized >= 0 && normalized <= 1) || !info(id, pi)) return false;
        const double plain = pi.minValue + normalized * (pi.maxValue - pi.minValue);
        std::lock_guard<std::mutex> g(producer_);
        touched_[id] = normalized;
        // The UI thread sets it too, so panels and editors read the new value right away.
        AudioUnitSetParameter(unit_, id, kAudioUnitScope_Global, 0, static_cast<AudioUnitParameterValue>(plain), 0);
        changes_.push(ParamChange{id, plain});
        return true;
    }
    void touchedParameters(std::vector<std::pair<uint32_t, double>> &out) override {
        std::lock_guard<std::mutex> g(producer_);
        out.assign(touched_.begin(), touched_.end());
    }
    // Edits in the unit's own view: the end of a parameter gesture (its view tells listeners, as Apple's generic
    // view and most frameworks do) or a preset change. State itself is read at save.
    uint64_t editCount() const override { return edits_.load(std::memory_order_relaxed); }
    void rememberValues() {
        for (AudioUnitParameterID id : paramIds_) {
            AudioUnitParameterValue v = 0;
            if (AudioUnitGetParameter(unit_, id, kAudioUnitScope_Global, 0, &v) == noErr) known_[id] = v;
        }
    }
    // The unit's current preset as number and name ("" when it has none). Main thread.
    std::string currentPreset() const {
        AUPreset p{};
        UInt32 size = sizeof p;
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &p, &size) != noErr) return {};
        std::string name = std::to_string(p.presetNumber) + ":";
        if (p.presetName) {
            char buf[256] = {};
            CFStringGetCString(p.presetName, buf, sizeof buf, kCFStringEncodingUTF8);
            name += buf;
            CFRelease(p.presetName);
        }
        return name;
    }
    void listenForEdits() {
        auto counted = [](void *ctx, void *, const AudioUnitEvent *e, UInt64, AudioUnitParameterValue) {
            auto *c = static_cast<ListenerContext *>(ctx);
            std::lock_guard<std::mutex> g(c->m);
            AudioUnitProcessor *me = c->owner;
            if (!me) return; // the unit is gone
            // Units also announce their preset, and some end parameter gestures, while loading or restoring state
            // (asynchronously): only a different preset or a changed value counts.
            if (e->mEventType == kAudioUnitEvent_PropertyChange) {
                const std::string now = me->currentPreset();
                if (now == me->preset_) return;
                me->preset_ = now;
            } else {
                const AudioUnitParameterID id = e->mArgument.mParameter.mParameterID;
                AudioUnitParameterValue v = 0;
                if (AudioUnitGetParameter(me->unit_, id, kAudioUnitScope_Global, 0, &v) != noErr) return;
                auto it = me->known_.find(id);
                if (it != me->known_.end() && std::abs(it->second - v) < 1e-6f) return;
                me->known_[id] = v;
            }
            // Only an open editor makes an edit. Some units apply restored state in the background and announce the
            // resulting preset and values later (seen isolated, where the host's run loop delivers them at once).
            if (!me->editor_) return;
            me->edits_.fetch_add(1, std::memory_order_relaxed);
        };
        listenerCtx_ = new ListenerContext;
        listenerCtx_->owner = this;
        if (AUEventListenerCreate(counted, listenerCtx_, CFRunLoopGetMain(), kCFRunLoopCommonModes, 0.05f, 0.05f, &listener_) != noErr) {
            listener_ = nullptr;
            return;
        }
        // The wildcard parameter ID is only valid for sending, so each parameter is registered.
        UInt32 size = 0;
        std::vector<AudioUnitParameterID> ids;
        if (AudioUnitGetPropertyInfo(unit_, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, nullptr) == noErr && size) {
            ids.resize(size / sizeof(AudioUnitParameterID));
            if (AudioUnitGetProperty(unit_, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, ids.data(), &size) != noErr) ids.clear();
        }
        paramIds_ = ids;
        rememberValues();
        for (AudioUnitParameterID id : ids) {
            AudioUnitEvent e{};
            e.mEventType = kAudioUnitEvent_EndParameterChangeGesture;
            e.mArgument.mParameter = {unit_, id, kAudioUnitScope_Global, 0};
            AUEventListenerAddEventType(listener_, listenerCtx_, &e);
        }
        preset_ = currentPreset();
        AudioUnitEvent preset{};
        preset.mEventType = kAudioUnitEvent_PropertyChange;
        preset.mArgument.mProperty = {unit_, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0};
        AUEventListenerAddEventType(listener_, listenerCtx_, &preset);
    }

    // Editor: the unit's Cocoa view (AUv2 kAudioUnitProperty_CocoaUI).
    bool hasEditor() override {
        UInt32 size = 0;
        Boolean writable = false;
        return AudioUnitGetPropertyInfo(unit_, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr && size > 0;
    }
    bool openEditor(void *parent, int32_t &w, int32_t &h, void (*)(void *, int32_t, int32_t), void *, std::string &err) override {
        closeEditor();
        UInt32 size = 0;
        Boolean writable = false;
        if (AudioUnitGetPropertyInfo(unit_, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) != noErr || !size) {
            err = "this Audio Unit has no editor";
            return false;
        }
        std::vector<char> buf(size);
        auto *ui = reinterpret_cast<AudioUnitCocoaViewInfo *>(buf.data());
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, ui, &size) != noErr) {
            err = "this Audio Unit has no editor";
            return false;
        }
        NSURL *bundleURL = (__bridge_transfer NSURL *)ui->mCocoaAUViewBundleLocation;
        NSString *className = (__bridge_transfer NSString *)ui->mCocoaAUViewClass[0];
        Class factoryClass = [[NSBundle bundleWithURL:bundleURL] classNamed:className];
        NSObject<AUCocoaUIBase> *factory = factoryClass ? [[factoryClass alloc] init] : nil;
        NSView *view = [factory respondsToSelector:@selector(uiViewForAudioUnit:withSize:)] ? [factory uiViewForAudioUnit:unit_ withSize:NSMakeSize(640, 400)] : nil;
        if (!view) { err = "the Audio Unit's editor could not be created"; return false; }
        NSView *host = (__bridge NSView *)parent;
        [host addSubview:view];
        view.frameOrigin = NSZeroPoint;
        editor_ = (__bridge_retained void *)view;
        w = static_cast<int32_t>(view.frame.size.width);
        h = static_cast<int32_t>(view.frame.size.height);
        return true;
    }
    void closeEditor() override {
        if (!editor_) return;
        NSView *view = (__bridge_transfer NSView *)editor_;
        [view removeFromSuperview];
        editor_ = nullptr;
    }

private:
    AudioComponentInstance unit_ = nullptr;
    AudioTimeStamp time_{};
    std::vector<float> inL_, inR_;
    std::string name_, vendor_, classId_, categories_;
    std::string stateError_;
    bool instrument_ = false, sidechain_ = false;
    SpscQueue<ParamChange, 1024> changes_;
    std::mutex producer_;
    std::map<uint32_t, double> touched_;
    void *editor_ = nullptr;
    AUEventListenerRef listener_ = nullptr;
    ListenerContext *listenerCtx_ = nullptr; // owned; freed with the listener (on the main thread)
    std::string preset_; // last known preset (main thread)
    std::vector<AudioUnitParameterID> paramIds_;
    std::map<AudioUnitParameterID, AudioUnitParameterValue> known_; // last known values (main thread)
    std::atomic<uint64_t> edits_{0};
};
} // namespace

std::unique_ptr<PluginProcessor> loadAudioUnit(const std::string &id, double sampleRate, int maxBlock, std::string &err) {
    auto p = std::make_unique<AudioUnitProcessor>();
    if (!p->open(id, sampleRate, maxBlock, err)) return nullptr;
    return p;
}

} // namespace dalnok
