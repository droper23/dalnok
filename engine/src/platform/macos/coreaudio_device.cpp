// Core Audio output via AUHAL: the default-output unit (follows the system
// default) or the HAL output unit bound to a specific device.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "device.hpp"
#include "sample_clock.hpp"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <atomic>
#include <cmath>

namespace dalnok {

namespace {

std::string osStatusString(const char *what, OSStatus s) {
    return std::string(what) + " failed (OSStatus " + std::to_string(static_cast<int>(s)) + ")";
}

AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel,
                                AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {sel, scope, kAudioObjectPropertyElementMain};
}

std::string cfString(AudioObjectID obj, AudioObjectPropertySelector sel) {
    auto a = addr(sel);
    CFStringRef s = nullptr;
    UInt32 size = sizeof(s);
    if (AudioObjectGetPropertyData(obj, &a, 0, nullptr, &size, &s) != noErr || !s) return {};
    char buf[512] = {};
    CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    CFRelease(s);
    return buf;
}

AudioDeviceID defaultOutputID() {
    auto a = addr(kAudioHardwarePropertyDefaultOutputDevice);
    AudioDeviceID dev = 0;
    UInt32 size = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, &dev) != noErr) return 0;
    return dev;
}

AudioDeviceID defaultInputID() {
    auto a = addr(kAudioHardwarePropertyDefaultInputDevice);
    AudioDeviceID dev = 0;
    UInt32 size = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, &dev) != noErr) return 0;
    return dev;
}

double nominalRate(AudioDeviceID dev) {
    auto a = addr(kAudioDevicePropertyNominalSampleRate);
    Float64 sr = 0;
    UInt32 size = sizeof(sr);
    if (!dev || AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &sr) != noErr) return 0;
    return sr;
}

int channelCount(AudioDeviceID dev, AudioObjectPropertyScope scope) {
    auto a = addr(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, nullptr, &size) != noErr || size == 0) return 0;
    std::vector<char> buf(size);
    auto *abl = reinterpret_cast<AudioBufferList *>(buf.data());
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, abl) != noErr) return 0;
    int n = 0;
    for (UInt32 i = 0; i < abl->mNumberBuffers; ++i) n += static_cast<int>(abl->mBuffers[i].mNumberChannels);
    return n;
}

std::vector<AudioDeviceID> allDevices() {
    auto a = addr(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size) != noErr) return {};
    std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data()) != noErr) return {};
    return ids;
}

AudioDeviceID deviceForUID(const std::string &uid) {
    for (auto id : allDevices())
        if (cfString(id, kAudioDevicePropertyDeviceUID) == uid) return id;
    return 0;
}

class CoreAudioOutput final : public AudioDevice {
public:
    CoreAudioOutput(AudioDeviceID dev, double sr) : device_(dev), sampleRate_(sr) {}
    ~CoreAudioOutput() override { stop(); }

    bool start(Callback cb, void *ctx, std::string &err) override {
        if (unit_) return true;
        cb_ = cb;
        ctx_ = ctx;

        AudioComponentDescription desc{};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = device_ ? kAudioUnitSubType_HALOutput : kAudioUnitSubType_DefaultOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
        if (!comp) {
            err = "output AudioUnit not found";
            return false;
        }
        OSStatus s = AudioComponentInstanceNew(comp, &unit_);
        if (s != noErr) return fail("AudioComponentInstanceNew", s, err);

        if (device_) {
            s = AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &device_, sizeof(device_));
            if (s != noErr) return fail("select output device", s, err);
        }

        AudioStreamBasicDescription fmt{};
        fmt.mSampleRate = sampleRate_; // AUHAL converts if the hardware runs at another rate
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) |
                           kAudioFormatFlagIsNonInterleaved;
        fmt.mChannelsPerFrame = 2;
        fmt.mFramesPerPacket = 1;
        fmt.mBitsPerChannel = 32;
        fmt.mBytesPerFrame = 4;
        fmt.mBytesPerPacket = 4;
        s = AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt,
                                 sizeof(fmt));
        if (s != noErr) return fail("set stream format", s, err);

        UInt32 maxFrames = 4096;
        AudioUnitSetProperty(unit_, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                             &maxFrames, sizeof(maxFrames));

        AURenderCallbackStruct rcb{&CoreAudioOutput::render, this};
        s = AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &rcb,
                                 sizeof(rcb));
        if (s != noErr) return fail("set render callback", s, err);

        if ((s = AudioUnitInitialize(unit_)) != noErr) return fail("AudioUnitInitialize", s, err);
        if ((s = AudioOutputUnitStart(unit_)) != noErr) return fail("AudioOutputUnitStart", s, err);
        return true;
    }

    void stop() override {
        if (!unit_) return;
        AudioOutputUnitStop(unit_);
        AudioUnitUninitialize(unit_);
        AudioComponentInstanceDispose(unit_);
        unit_ = nullptr;
    }

    bool alive() const override {
        if (!device_) return true; // default-output unit follows whatever the default is
        auto a = addr(kAudioDevicePropertyDeviceIsAlive);
        UInt32 isAlive = 0, size = sizeof(isAlive);
        return AudioObjectGetPropertyData(device_, &a, 0, nullptr, &size, &isAlive) == noErr && isAlive;
    }

    double hardwareSampleRate() const override { return nominalRate(device_ ? device_ : defaultOutputID()); }

private:
    bool fail(const char *what, OSStatus s, std::string &err) {
        err = osStatusString(what, s);
        if (unit_) {
            AudioComponentInstanceDispose(unit_);
            unit_ = nullptr;
        }
        return false;
    }

    static OSStatus render(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
                           AudioBufferList *io) DALNOK_NONBLOCKING {
        auto *self = static_cast<CoreAudioOutput *>(ref);
        if (io->mNumberBuffers < 2) return noErr;
        self->cb_(self->ctx_, static_cast<float *>(io->mBuffers[0].mData),
                  static_cast<float *>(io->mBuffers[1].mData), static_cast<int>(frames));
        return noErr;
    }

    AudioDeviceID device_; // 0 = system default
    double sampleRate_;
    AudioComponentInstance unit_ = nullptr;
    Callback cb_ = nullptr;
    void *ctx_ = nullptr;
};

// One AUHAL instance keeps capture and playback on a single device clock.
class CoreAudioDuplex final : public AudioDuplexDevice {
public:
    CoreAudioDuplex(AudioDeviceID device, double rate, int channel, int channels)
        : device_(device), sampleRate_(rate), selected_(channel), channels_(channels) {}
    ~CoreAudioDuplex() override { stop(); }

    bool start(Callback cb, void *ctx, std::string &err) override {
        if (unit_) { err = "duplex device already started"; return false; }
        if (!cb) { err = "missing duplex callback"; return false; }
        cb_ = cb; ctx_ = ctx;
        failed_.store(false, std::memory_order_relaxed);
        clock_.reset();
        AudioComponentDescription desc{};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_HALOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        auto comp = AudioComponentFindNext(nullptr, &desc);
        if (!comp) { err = "duplex AudioUnit not found"; return false; }
        OSStatus s = AudioComponentInstanceNew(comp, &unit_);
        if (s != noErr) return fail("create duplex unit", s, err);
        UInt32 enabled = 1;
        s = AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, sizeof(enabled));
        if (s != noErr) return fail("enable input", s, err);
        s = AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, sizeof(enabled));
        if (s != noErr) return fail("enable output", s, err);
        s = AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device_, sizeof(device_));
        if (s != noErr) return fail("select duplex device", s, err);
        AudioStreamBasicDescription fmt{};
        fmt.mSampleRate = sampleRate_;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) | kAudioFormatFlagIsNonInterleaved;
        fmt.mChannelsPerFrame = static_cast<UInt32>(channels_);
        fmt.mFramesPerPacket = 1; fmt.mBitsPerChannel = 32; fmt.mBytesPerFrame = 4; fmt.mBytesPerPacket = 4;
        s = AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, sizeof(fmt));
        if (s != noErr) return fail("set input format", s, err);
        fmt.mChannelsPerFrame = 2;
        s = AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
        if (s != noErr) return fail("set output format", s, err);
        UInt32 size = sizeof(maxFrames_);
        s = AudioUnitGetProperty(unit_, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames_, &size);
        if (s != noErr) return fail("get maximum callback size", s, err);
        if (maxFrames_ == 0 || maxFrames_ > 65536) return fail("invalid maximum callback size", kAudio_ParamError, err);
        input_.resize(static_cast<size_t>(maxFrames_) * static_cast<size_t>(channels_));
        inputData_ = input_.data();
        AURenderCallbackStruct callback{&CoreAudioDuplex::render, this};
        s = AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
        if (s != noErr) return fail("set duplex callback", s, err);
        if ((s = AudioUnitInitialize(unit_)) != noErr) return fail("initialize duplex unit", s, err);
        if ((s = AudioOutputUnitStart(unit_)) != noErr) { AudioUnitUninitialize(unit_); return fail("start duplex unit", s, err); }
        return true;
    }
    void stop() override {
        if (!unit_) return;
        AudioOutputUnitStop(unit_);
        AudioUnitUninitialize(unit_);
        AudioComponentInstanceDispose(unit_);
        unit_ = nullptr;
    }
    bool captureFailed() const override { return failed_.load(std::memory_order_acquire); }
    bool alive() const override {
        auto a = addr(kAudioDevicePropertyDeviceIsAlive);
        UInt32 value = 0, size = sizeof(value);
        return AudioObjectGetPropertyData(device_, &a, 0, nullptr, &size, &value) == noErr && value;
    }
    double hardwareSampleRate() const override { return nominalRate(device_); }
    int64_t roundTripLatency() const override {
        auto get = [](AudioObjectID object, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
            auto a = addr(sel, scope);
            UInt32 value = 0, size = sizeof(value);
            return AudioObjectGetPropertyData(object, &a, 0, nullptr, &size, &value) == noErr ? int64_t(value) : int64_t(0);
        };
        auto firstStream = [this](AudioObjectPropertyScope scope) -> AudioObjectID {
            auto a = addr(kAudioDevicePropertyStreams, scope);
            UInt32 size = 0;
            if (AudioObjectGetPropertyDataSize(device_, &a, 0, nullptr, &size) != noErr || size < sizeof(AudioStreamID)) return 0;
            std::vector<AudioStreamID> streams(size / sizeof(AudioStreamID));
            return AudioObjectGetPropertyData(device_, &a, 0, nullptr, &size, streams.data()) == noErr ? streams[0] : 0;
        };
        int64_t total = 0;
        for (auto scope : {kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput}) {
            total += get(device_, kAudioDevicePropertyLatency, scope) + get(device_, kAudioDevicePropertySafetyOffset, scope) +
                     get(device_, kAudioDevicePropertyBufferFrameSize, scope);
            if (const AudioObjectID stream = firstStream(scope)) total += get(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal);
        }
        return total;
    }

private:
    bool fail(const char *what, OSStatus status, std::string &err) {
        err = osStatusString(what, status);
        if (unit_) { AudioComponentInstanceDispose(unit_); unit_ = nullptr; }
        return false;
    }
    static OSStatus render(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *time,
                           UInt32, UInt32 frames, AudioBufferList *output) DALNOK_NONBLOCKING {
        auto *self = static_cast<CoreAudioDuplex *>(ref);
        if (!output || output->mNumberBuffers < 2) { self->failed_.store(true, std::memory_order_release); return kAudio_ParamError; }
        auto *left = static_cast<float *>(output->mBuffers[0].mData);
        auto *right = static_cast<float *>(output->mBuffers[1].mData);
        if (!left || !right || output->mBuffers[0].mDataByteSize < frames * sizeof(float) ||
            output->mBuffers[1].mDataByteSize < frames * sizeof(float)) {
            self->failed_.store(true, std::memory_order_release); return kAudio_ParamError;
        }
        const float *selected = nullptr;
        const bool continuous = self->clock_.accept(time && (time->mFlags & kAudioTimeStampSampleTimeValid),
                                                    time ? time->mSampleTime : 0, frames);
        if (continuous && frames <= self->maxFrames_) {
            struct InputBuffers { UInt32 count; AudioBuffer buffers[64]; } input{};
            input.count = static_cast<UInt32>(self->channels_);
            for (int c = 0; c < self->channels_; ++c) {
                input.buffers[c].mNumberChannels = 1;
                input.buffers[c].mDataByteSize = frames * sizeof(float);
                input.buffers[c].mData = self->inputData_ + static_cast<size_t>(c) * self->maxFrames_;
            }
            AudioUnitRenderActionFlags inputFlags = 0;
            const OSStatus s = AudioUnitRender(self->unit_, &inputFlags, time, 1, frames, reinterpret_cast<AudioBufferList *>(&input));
            if (s == noErr && input.count > static_cast<UInt32>(self->selected_) &&
                input.buffers[self->selected_].mDataByteSize >= frames * sizeof(float))
                selected = static_cast<const float *>(input.buffers[self->selected_].mData);
        }
        if (!selected) self->failed_.store(true, std::memory_order_release);
        self->cb_(self->ctx_, left, right, selected, static_cast<int>(frames));
        return noErr;
    }
    AudioDeviceID device_;
    double sampleRate_;
    int selected_, channels_;
    UInt32 maxFrames_ = 0;
    AudioComponentInstance unit_ = nullptr;
    std::vector<float> input_;
    float *inputData_ = nullptr;
    Callback cb_ = nullptr;
    void *ctx_ = nullptr;
    std::atomic<bool> failed_{false};
    SampleClock clock_;
};

} // namespace

std::vector<DeviceInfo> listOutputDevices() {
    std::vector<DeviceInfo> out;
    const AudioDeviceID def = defaultOutputID();
    for (auto id : allDevices()) {
        const int ch = channelCount(id, kAudioObjectPropertyScopeOutput);
        if (ch <= 0) continue;
        DeviceInfo d;
        d.uid = cfString(id, kAudioDevicePropertyDeviceUID);
        d.name = cfString(id, kAudioObjectPropertyName);
        d.sampleRate = nominalRate(id);
        d.outputChannels = ch;
        d.isDefault = id == def;
        if (!d.uid.empty()) out.push_back(std::move(d));
    }
    return out;
}

std::vector<DeviceInfo> listInputDevices() {
    std::vector<DeviceInfo> out;
    const AudioDeviceID def = defaultInputID();
    for (auto id : allDevices()) {
        const int ch = channelCount(id, kAudioObjectPropertyScopeInput);
        if (ch <= 0) continue;
        DeviceInfo d;
        d.uid = cfString(id, kAudioDevicePropertyDeviceUID);
        d.name = cfString(id, kAudioObjectPropertyName);
        d.sampleRate = nominalRate(id);
        d.inputChannels = ch;
        d.isDefault = id == def;
        if (!d.uid.empty()) out.push_back(std::move(d));
    }
    return out;
}

std::unique_ptr<AudioDevice> createOutputDevice(const std::string &uid, double sampleRate, std::string &err) {
    AudioDeviceID dev = 0;
    if (!uid.empty()) {
        dev = deviceForUID(uid);
        if (!dev) {
            err = "output device not found (unplugged?)";
            return nullptr;
        }
    }
    return std::make_unique<CoreAudioOutput>(dev, sampleRate);
}

std::unique_ptr<AudioDuplexDevice> createDuplexDevice(const std::string &uid, double sampleRate,
                                                      int inputChannel, std::string &err) {
    const AudioDeviceID device = uid.empty() ? 0 : deviceForUID(uid);
    if (!device) { err = "select an available duplex device"; return nullptr; }
    const int inputs = channelCount(device, kAudioObjectPropertyScopeInput);
    const int outputs = channelCount(device, kAudioObjectPropertyScopeOutput);
    if (inputs <= 0 || inputs > 64 || outputs < 2 || inputChannel < 0 || inputChannel >= inputs) {
        err = "device does not support the requested input and stereo output"; return nullptr;
    }
    const double rate = nominalRate(device);
    if (rate <= 0 || std::abs(rate - sampleRate) > 0.5) {
        err = "engine and duplex device sample rates do not match"; return nullptr;
    }
    return std::make_unique<CoreAudioDuplex>(device, rate, inputChannel, inputs);
}

double defaultOutputSampleRate() { return nominalRate(defaultOutputID()); }

} // namespace dalnok
