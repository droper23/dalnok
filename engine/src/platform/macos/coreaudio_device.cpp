// Core Audio output via the default-output AudioUnit (AUHAL).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "device.hpp"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>

namespace atrium {

namespace {

std::string osStatusString(const char *what, OSStatus s) {
    return std::string(what) + " failed (OSStatus " + std::to_string(static_cast<int>(s)) + ")";
}

class CoreAudioOutput final : public AudioDevice {
public:
    explicit CoreAudioOutput(double sr) : sampleRate_(sr) {}
    ~CoreAudioOutput() override { stop(); }

    bool start(Callback cb, void *ctx, std::string &err) override {
        if (unit_) return true;
        cb_ = cb;
        ctx_ = ctx;

        AudioComponentDescription desc{};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_DefaultOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
        if (!comp) {
            err = "default output AudioUnit not found";
            return false;
        }
        OSStatus s = AudioComponentInstanceNew(comp, &unit_);
        if (s != noErr) return fail("AudioComponentInstanceNew", s, err);

        AudioStreamBasicDescription fmt{};
        fmt.mSampleRate = sampleRate_;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) | kAudioFormatFlagIsNonInterleaved;
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

    double sampleRate_;
    AudioComponentInstance unit_ = nullptr;
    Callback cb_ = nullptr;
    void *ctx_ = nullptr;
};

} // namespace

std::unique_ptr<AudioDevice> createDefaultOutputDevice(double sampleRate) {
    return std::make_unique<CoreAudioOutput>(sampleRate);
}

double defaultOutputSampleRate() {
    AudioObjectPropertyAddress addr{kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioDeviceID dev = 0;
    UInt32 size = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, &dev) != noErr || !dev)
        return 0;
    addr.mSelector = kAudioDevicePropertyNominalSampleRate;
    Float64 sr = 0;
    size = sizeof(sr);
    if (AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &sr) != noErr) return 0;
    return sr;
}

} // namespace atrium
