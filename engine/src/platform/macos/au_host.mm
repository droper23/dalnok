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
#include <atomic>
#include <map>
#include <mutex>
#include <vector>

namespace dalnok {
namespace {

OSType fourCC(const std::string &s, size_t at) {
    return static_cast<OSType>((static_cast<unsigned char>(s[at]) << 24) | (static_cast<unsigned char>(s[at + 1]) << 16) |
                               (static_cast<unsigned char>(s[at + 2]) << 8) | static_cast<unsigned char>(s[at + 3]));
}

struct ParamChange { AudioUnitParameterID id; double value; };

class AudioUnitProcessor final : public PluginProcessor {
public:
    ~AudioUnitProcessor() override {
        closeEditor();
        if (unit_) {
            AudioUnitUninitialize(unit_);
            AudioComponentInstanceDispose(unit_);
        }
    }

    bool open(const std::string &id, double rate, int maxBlock, std::string &err) {
        if (id.size() != 14 || id[4] != ':' || id[9] != ':') { err = "expected an Audio Unit id type:subtype:manufacturer"; return false; }
        AudioComponentDescription desc{fourCC(id, 0), fourCC(id, 5), fourCC(id, 10), 0, 0};
        AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
        if (!comp) { err = "Audio Unit not installed"; return false; }
        if (AudioComponentInstanceNew(comp, &unit_) != noErr || !unit_) { err = "cannot create the Audio Unit"; return false; }
        classId_ = id;
        instrument_ = desc.componentType == kAudioUnitType_MusicDevice;
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
        }
        UInt32 frames = static_cast<UInt32>(maxBlock);
        AudioUnitSetProperty(unit_, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, sizeof frames);
        if (AudioUnitInitialize(unit_) != noErr) { err = "the Audio Unit failed to initialize"; return false; }
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

    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override {
        for (int i = 0; i < frames; ++i) { inL_[static_cast<size_t>(i)] = left[i]; inR_[static_cast<size_t>(i)] = right[i]; }
        struct { UInt32 count; AudioBuffer buffers[2]; } out{2, {{1, static_cast<UInt32>(frames) * 4, left}, {1, static_cast<UInt32>(frames) * 4, right}}};
        AudioUnitRenderActionFlags flags = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        // Plugin code (ADR-0009): parameters and note events first, then render.
        ParamChange c;
        while (changes_.pop(c)) AudioUnitSetParameter(unit_, c.id, kAudioUnitScope_Global, 0, static_cast<AudioUnitParameterValue>(c.value), 0);
        for (int i = 0; i < noteCount; ++i)
            MusicDeviceMIDIEvent(unit_, notes[i].on ? 0x90u : 0x80u, notes[i].pitch, notes[i].on ? notes[i].velocity : 0u,
                                 static_cast<UInt32>(notes[i].offset));
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
    bool setState(const std::string &bytes) override {
        CFDataRef data = CFDataCreate(nullptr, reinterpret_cast<const UInt8 *>(bytes.data()), static_cast<CFIndex>(bytes.size()));
        CFPropertyListRef plist = data ? CFPropertyListCreateWithData(nullptr, data, kCFPropertyListImmutable, nullptr, nullptr) : nullptr;
        if (data) CFRelease(data);
        if (!plist) return false;
        const bool ok = AudioUnitSetProperty(unit_, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &plist, sizeof plist) == noErr;
        CFRelease(plist);
        if (ok) {
            AudioUnitParameter changed{unit_, kAUParameterListener_AnyParameter, kAudioUnitScope_Global, 0};
            AUParameterListenerNotify(nullptr, nullptr, &changed);
            std::lock_guard<std::mutex> g(producer_);
            touched_.clear();
        }
        return ok;
    }

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
        char text[64];
        snprintf(text, sizeof text, span >= 100 || pi.unit == kAudioUnitParameterUnit_Indexed ? "%.0f" : "%.2f", v);
        out.display = text;
        static const std::map<AudioUnitParameterUnit, const char *> units = {
            {kAudioUnitParameterUnit_Hertz, "Hz"}, {kAudioUnitParameterUnit_Decibels, "dB"}, {kAudioUnitParameterUnit_Seconds, "s"},
            {kAudioUnitParameterUnit_Milliseconds, "ms"}, {kAudioUnitParameterUnit_Percent, "%"}, {kAudioUnitParameterUnit_EqualPowerCrossfade, "%"},
            {kAudioUnitParameterUnit_Cents, "cents"}, {kAudioUnitParameterUnit_RelativeSemiTones, "st"}};
        if (auto it = units.find(pi.unit); it != units.end()) out.units = it->second;
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
    uint64_t editCount() const override { return 0; } // AU editors change parameters directly; state is read at save

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
    std::string name_, vendor_, classId_;
    bool instrument_ = false;
    SpscQueue<ParamChange, 1024> changes_;
    std::mutex producer_;
    std::map<uint32_t, double> touched_;
    void *editor_ = nullptr;
};
} // namespace

std::unique_ptr<PluginProcessor> loadAudioUnit(const std::string &id, double sampleRate, int maxBlock, std::string &err) {
    auto p = std::make_unique<AudioUnitProcessor>();
    if (!p->open(id, sampleRate, maxBlock, err)) return nullptr;
    return p;
}

} // namespace dalnok
