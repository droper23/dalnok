// Core Audio output via AUHAL: the default-output unit (follows the system
// default) or the HAL output unit bound to a specific device.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "device.hpp"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>

namespace atrium {

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

double nominalRate(AudioDeviceID dev) {
    auto a = addr(kAudioDevicePropertyNominalSampleRate);
    Float64 sr = 0;
    UInt32 size = sizeof(sr);
    if (!dev || AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &sr) != noErr) return 0;
    return sr;
}

int outputChannels(AudioDeviceID dev) {
    auto a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput);
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
                           AudioBufferList *io) ATRIUM_NONBLOCKING {
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

} // namespace

std::vector<DeviceInfo> listOutputDevices() {
    std::vector<DeviceInfo> out;
    const AudioDeviceID def = defaultOutputID();
    for (auto id : allDevices()) {
        const int ch = outputChannels(id);
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

double defaultOutputSampleRate() { return nominalRate(defaultOutputID()); }

} // namespace atrium
