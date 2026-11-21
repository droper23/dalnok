// Test Audio Unit (AUv2 effect, aufx/dkdk/Dlnk): a ducker with a sidechain input bus, for the hosting tests.
// out = in * gain * (1 - |key|), per channel and sample; gain is parameter 0 (default 0.5), saved in ClassInfo.
// It registers in the calling process only (dalnok_test_au_register, AudioComponentRegister): nothing is installed.
// Built by scripts/ci/plugin-host.sh as a dylib; tests and dalnok-plughost load it through DALNOK_TEST_AU.
// SPDX-License-Identifier: GPL-3.0-or-later
#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace {

constexpr UInt32 kSub = 'dkdk', kManu = 'Dlnk';

struct Duck {
    AudioComponentPlugInInterface iface{};
    AudioComponentInstance instance = nullptr;
    Float64 rate = 48000;
    UInt32 maxFrames = 4096;
    AURenderCallbackStruct input[2]{};
    AudioStreamBasicDescription in[2]{}, out{};
    std::vector<float> buf[4]; // bus 0 L/R, bus 1 L/R
    float gain = 0.5f;
    bool initialized = false;
};

AudioStreamBasicDescription stereo(Float64 rate) {
    AudioStreamBasicDescription f{};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) | kAudioFormatFlagIsNonInterleaved;
    f.mChannelsPerFrame = 2;
    f.mFramesPerPacket = 1;
    f.mBitsPerChannel = 32;
    f.mBytesPerFrame = f.mBytesPerPacket = 4;
    return f;
}

OSStatus Initialize(void *self) {
    auto *d = static_cast<Duck *>(self);
    for (auto &b : d->buf) b.assign(d->maxFrames, 0.0f);
    d->initialized = true;
    return noErr;
}
OSStatus Uninitialize(void *self) { static_cast<Duck *>(self)->initialized = false; return noErr; }

OSStatus GetPropertyInfo(void *self, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el, UInt32 *size, Boolean *writable) {
    (void)self; (void)el;
    UInt32 s = 0; Boolean w = false;
    switch (id) {
    case kAudioUnitProperty_StreamFormat: s = sizeof(AudioStreamBasicDescription); w = true; break;
    case kAudioUnitProperty_ElementCount: s = sizeof(UInt32); break;
    case kAudioUnitProperty_SetRenderCallback: if (scope != kAudioUnitScope_Input) return kAudioUnitErr_InvalidScope; s = sizeof(AURenderCallbackStruct); w = true; break;
    case kAudioUnitProperty_MaximumFramesPerSlice: s = sizeof(UInt32); w = true; break;
    case kAudioUnitProperty_SampleRate: s = sizeof(Float64); w = true; break;
    case kAudioUnitProperty_Latency: case kAudioUnitProperty_TailTime: s = sizeof(Float64); break;
    case kAudioUnitProperty_ParameterList: s = scope == kAudioUnitScope_Global ? sizeof(AudioUnitParameterID) : 0; break;
    case kAudioUnitProperty_ParameterInfo: s = sizeof(AudioUnitParameterInfo); break;
    case kAudioUnitProperty_ClassInfo: s = sizeof(CFPropertyListRef); w = true; break;
    case kAudioUnitProperty_SupportedNumChannels: s = sizeof(AUChannelInfo); break;
    default: return kAudioUnitErr_InvalidProperty;
    }
    if (size) *size = s;
    if (writable) *writable = w;
    return noErr;
}

OSStatus GetProperty(void *self, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el, void *data, UInt32 *size) {
    auto *d = static_cast<Duck *>(self);
    switch (id) {
    case kAudioUnitProperty_StreamFormat:
        if (scope == kAudioUnitScope_Input && el < 2) *static_cast<AudioStreamBasicDescription *>(data) = d->in[el];
        else if (scope == kAudioUnitScope_Output && el == 0) *static_cast<AudioStreamBasicDescription *>(data) = d->out;
        else return kAudioUnitErr_InvalidElement;
        *size = sizeof(AudioStreamBasicDescription); return noErr;
    case kAudioUnitProperty_ElementCount:
        *static_cast<UInt32 *>(data) = scope == kAudioUnitScope_Input ? 2 : 1; *size = sizeof(UInt32); return noErr;
    case kAudioUnitProperty_MaximumFramesPerSlice: *static_cast<UInt32 *>(data) = d->maxFrames; *size = sizeof(UInt32); return noErr;
    case kAudioUnitProperty_SampleRate: *static_cast<Float64 *>(data) = d->rate; *size = sizeof(Float64); return noErr;
    case kAudioUnitProperty_Latency: case kAudioUnitProperty_TailTime: *static_cast<Float64 *>(data) = 0; *size = sizeof(Float64); return noErr;
    case kAudioUnitProperty_ParameterList:
        if (scope != kAudioUnitScope_Global) { *size = 0; return noErr; }
        *static_cast<AudioUnitParameterID *>(data) = 0; *size = sizeof(AudioUnitParameterID); return noErr;
    case kAudioUnitProperty_ParameterInfo: {
        if (el != 0) return kAudioUnitErr_InvalidParameter;
        auto *p = static_cast<AudioUnitParameterInfo *>(data);
        std::memset(p, 0, sizeof *p);
        std::strncpy(p->name, "Gain", sizeof p->name - 1);
        p->unit = kAudioUnitParameterUnit_Generic;
        p->minValue = 0; p->maxValue = 1; p->defaultValue = 0.5f;
        p->flags = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable;
        *size = sizeof *p; return noErr;
    }
    case kAudioUnitProperty_ClassInfo: {
        CFMutableDictionaryRef dict = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        auto num = [&](const char *key, SInt32 v) {
            CFStringRef k = CFStringCreateWithCString(nullptr, key, kCFStringEncodingUTF8);
            CFNumberRef n = CFNumberCreate(nullptr, kCFNumberSInt32Type, &v);
            CFDictionarySetValue(dict, k, n); CFRelease(k); CFRelease(n);
        };
        num(kAUPresetVersionKey, 0); num(kAUPresetTypeKey, kAudioUnitType_Effect);
        num(kAUPresetSubtypeKey, static_cast<SInt32>(kSub)); num(kAUPresetManufacturerKey, static_cast<SInt32>(kManu));
        CFDictionarySetValue(dict, CFSTR(kAUPresetNameKey), CFSTR("Untitled"));
        Float32 g = d->gain;
        CFNumberRef gn = CFNumberCreate(nullptr, kCFNumberFloat32Type, &g);
        CFDictionarySetValue(dict, CFSTR("gain"), gn); CFRelease(gn);
        *static_cast<CFPropertyListRef *>(data) = dict;
        *size = sizeof(CFPropertyListRef); return noErr;
    }
    case kAudioUnitProperty_SupportedNumChannels: {
        auto *c = static_cast<AUChannelInfo *>(data);
        c->inChannels = 2; c->outChannels = 2; *size = sizeof *c; return noErr;
    }
    default: return kAudioUnitErr_InvalidProperty;
    }
}

OSStatus SetProperty(void *self, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el, const void *data, UInt32 size) {
    auto *d = static_cast<Duck *>(self);
    switch (id) {
    case kAudioUnitProperty_StreamFormat: {
        if (size < sizeof(AudioStreamBasicDescription)) return kAudio_ParamError;
        const auto f = *static_cast<const AudioStreamBasicDescription *>(data);
        if (f.mFormatID != kAudioFormatLinearPCM || f.mChannelsPerFrame != 2 || f.mBitsPerChannel != 32 ||
            !(f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) || !(f.mFormatFlags & kAudioFormatFlagIsFloat))
            return kAudioUnitErr_FormatNotSupported;
        if (scope == kAudioUnitScope_Input && el < 2) d->in[el] = f;
        else if (scope == kAudioUnitScope_Output && el == 0) d->out = f;
        else return kAudioUnitErr_InvalidElement;
        d->rate = f.mSampleRate;
        return noErr;
    }
    case kAudioUnitProperty_SetRenderCallback:
        if (scope != kAudioUnitScope_Input || el > 1) return kAudioUnitErr_InvalidElement;
        d->input[el] = *static_cast<const AURenderCallbackStruct *>(data); return noErr;
    case kAudioUnitProperty_MaximumFramesPerSlice:
        d->maxFrames = *static_cast<const UInt32 *>(data);
        if (d->initialized) for (auto &b : d->buf) b.assign(d->maxFrames, 0.0f);
        return noErr;
    case kAudioUnitProperty_SampleRate: d->rate = *static_cast<const Float64 *>(data); return noErr;
    case kAudioUnitProperty_ClassInfo: {
        auto dict = *static_cast<const CFDictionaryRef *>(data);
        if (!dict || CFGetTypeID(dict) != CFDictionaryGetTypeID()) return kAudioUnitErr_InvalidPropertyValue;
        if (auto n = static_cast<CFNumberRef>(CFDictionaryGetValue(dict, CFSTR("gain")))) {
            Float32 g = 0.5f;
            CFNumberGetValue(n, kCFNumberFloat32Type, &g);
            d->gain = g;
        }
        return noErr;
    }
    default: return kAudioUnitErr_InvalidProperty;
    }
}

OSStatus AddListener(void *, AudioUnitPropertyID, AudioUnitPropertyListenerProc, void *) { return noErr; }
OSStatus RemoveListener(void *, AudioUnitPropertyID, AudioUnitPropertyListenerProc, void *) { return noErr; }
OSStatus AddNotify(void *, AURenderCallback, void *) { return noErr; }
OSStatus Reset(void *, AudioUnitScope, AudioUnitElement) { return noErr; }

OSStatus GetParameter(void *self, AudioUnitParameterID id, AudioUnitScope, AudioUnitElement, AudioUnitParameterValue *v) {
    if (id != 0) return kAudioUnitErr_InvalidParameter;
    *v = static_cast<Duck *>(self)->gain; return noErr;
}
OSStatus SetParameter(void *self, AudioUnitParameterID id, AudioUnitScope, AudioUnitElement, AudioUnitParameterValue v, UInt32) {
    if (id != 0) return kAudioUnitErr_InvalidParameter;
    static_cast<Duck *>(self)->gain = std::clamp(v, 0.0f, 1.0f); return noErr;
}

// Pulls `bus` into buf[2*bus], buf[2*bus+1]; a bus with no source reads silence.
OSStatus pull(Duck *d, UInt32 bus, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 frames) {
    float *l = d->buf[2 * bus].data(), *r = d->buf[2 * bus + 1].data();
    if (!d->input[bus].inputProc) { std::fill(l, l + frames, 0.0f); std::fill(r, r + frames, 0.0f); return noErr; }
    struct { UInt32 n; AudioBuffer b[2]; } list{2, {{1, frames * 4, l}, {1, frames * 4, r}}};
    return d->input[bus].inputProc(d->input[bus].inputProcRefCon, flags, ts, bus, frames, reinterpret_cast<AudioBufferList *>(&list));
}

OSStatus Render(void *self, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *io) {
    auto *d = static_cast<Duck *>(self);
    if (bus != 0 || !d->initialized || frames > d->maxFrames || !io || io->mNumberBuffers < 2) return kAudio_ParamError;
    if (OSStatus s = pull(d, 0, flags, ts, frames)) return s;
    if (OSStatus s = pull(d, 1, flags, ts, frames)) return s;
    for (UInt32 c = 0; c < 2; ++c) {
        auto *o = static_cast<float *>(io->mBuffers[c].mData);
        if (!o) { io->mBuffers[c].mData = o = d->buf[c].data(); } // in-place: output into our own buffer
        const float *x = d->buf[c].data(), *k = d->buf[2 + c].data();
        for (UInt32 i = 0; i < frames; ++i) o[i] = x[i] * d->gain * (1.0f - std::min(1.0f, std::fabs(k[i])));
        io->mBuffers[c].mDataByteSize = frames * 4;
    }
    return noErr;
}

AudioComponentMethod Lookup(SInt16 selector) {
    switch (selector) {
    case kAudioUnitInitializeSelect: return reinterpret_cast<AudioComponentMethod>(Initialize);
    case kAudioUnitUninitializeSelect: return reinterpret_cast<AudioComponentMethod>(Uninitialize);
    case kAudioUnitGetPropertyInfoSelect: return reinterpret_cast<AudioComponentMethod>(GetPropertyInfo);
    case kAudioUnitGetPropertySelect: return reinterpret_cast<AudioComponentMethod>(GetProperty);
    case kAudioUnitSetPropertySelect: return reinterpret_cast<AudioComponentMethod>(SetProperty);
    case kAudioUnitAddPropertyListenerSelect: return reinterpret_cast<AudioComponentMethod>(AddListener);
    case kAudioUnitRemovePropertyListenerWithUserDataSelect: return reinterpret_cast<AudioComponentMethod>(RemoveListener);
    case kAudioUnitAddRenderNotifySelect: case kAudioUnitRemoveRenderNotifySelect: return reinterpret_cast<AudioComponentMethod>(AddNotify);
    case kAudioUnitResetSelect: return reinterpret_cast<AudioComponentMethod>(Reset);
    case kAudioUnitGetParameterSelect: return reinterpret_cast<AudioComponentMethod>(GetParameter);
    case kAudioUnitSetParameterSelect: return reinterpret_cast<AudioComponentMethod>(SetParameter);
    case kAudioUnitRenderSelect: return reinterpret_cast<AudioComponentMethod>(Render);
    default: return nullptr;
    }
}

OSStatus Open(void *self, AudioComponentInstance instance) {
    auto *d = static_cast<Duck *>(self);
    d->instance = instance;
    d->in[0] = d->in[1] = d->out = stereo(d->rate);
    return noErr;
}
OSStatus Close(void *self) { delete static_cast<Duck *>(self); return noErr; }

AudioComponentPlugInInterface *Factory(const AudioComponentDescription *) {
    auto *d = new Duck;
    d->iface.Open = Open;
    d->iface.Close = Close;
    d->iface.Lookup = Lookup;
    return &d->iface; // first member: Open/Close/methods receive it as `self`
}

} // namespace

// Registers the test unit in this process; returns 0 on success. Safe to call more than once.
extern "C" __attribute__((visibility("default"))) int dalnok_test_au_register() {
    static AudioComponent registered = nullptr;
    if (registered) return 0;
    AudioComponentDescription desc{kAudioUnitType_Effect, kSub, kManu, 0, 0};
    registered = AudioComponentRegister(&desc, CFSTR("Dalnok: Test AU Duck"), 0x00010000, Factory);
    return registered ? 0 : 1;
}
