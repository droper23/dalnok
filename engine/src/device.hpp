// Audio device abstraction. One implementation per platform (platform/<os>/).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "rt.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace dalnok {

class AudioDevice {
public:
    // Called on the device's real-time thread with planar stereo output buffers.
    using Callback = void (*)(void *ctx, float *left, float *right, int frames) DALNOK_NONBLOCKING;

    virtual ~AudioDevice() = default;
    virtual bool start(Callback cb, void *ctx, std::string &err) = 0;
    // Synchronous: when this returns the callback is no longer running.
    virtual void stop() = 0;
    // False once the hardware disappeared (e.g. unplugged). Control thread only.
    virtual bool alive() const = 0;
    // The device's own (hardware) sample rate; the engine rate is converted to it if different.
    virtual double hardwareSampleRate() const = 0;
    // A new Mach send right for the audio workgroup of the device's I/O thread (os_workgroup_copy_port), or 0.
    // Control thread, while started. Isolated plug-in hosts join it (ADR-0014 stage 2).
    virtual uint32_t workgroupPort() const { return 0; }
};

// Internal full-duplex path. Input and output are clocked by the same device.
// `inputs` holds one mono buffer per device input channel (`inputCount` of them). Null inputs indicate
// a capture failure; the callback must not block.
class AudioDuplexDevice {
public:
    using Callback = void (*)(void *ctx, float *left, float *right, const float *const *inputs, int inputCount,
                              int frames) DALNOK_NONBLOCKING;
    virtual ~AudioDuplexDevice() = default;
    virtual bool start(Callback cb, void *ctx, std::string &err) = 0;
    virtual uint32_t workgroupPort() const { return 0; } // as AudioDevice::workgroupPort
    virtual void stop() = 0;
    virtual bool captureFailed() const = 0;
    virtual bool alive() const = 0;
    virtual double hardwareSampleRate() const = 0;
    // Device-reported input + output latency in frames (device, safety offset, stream,
    // and one buffer each way). An estimate until measured with a loopback.
    virtual int64_t roundTripLatency() const = 0;
};

struct DeviceInfo {
    std::string uid;  // stable identifier
    std::string name;
    double sampleRate = 0;
    int outputChannels = 0;
    int inputChannels = 0;
    bool isDefault = false;
};

std::vector<DeviceInfo> listOutputDevices();
std::vector<DeviceInfo> listInputDevices();
// Empty uid = follow the system default output.
std::unique_ptr<AudioDevice> createOutputDevice(const std::string &uid, double sampleRate, std::string &err);
// Input from device `uid` (inputChannel is zero-based) and output to `outputUid` (empty = the system default), on one
// clock: the same device, or a private aggregate of the two with the output as the clock and the input drift-corrected.
std::unique_ptr<AudioDuplexDevice> createDuplexDevice(const std::string &uid, const std::string &outputUid,
                                                      double sampleRate, int inputChannel, std::string &err);
double defaultOutputSampleRate(); // 0 if unknown

} // namespace dalnok
