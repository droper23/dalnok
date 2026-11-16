// Audio device abstraction. One implementation per platform (platform/<os>/).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "rt.hpp"

#include <memory>
#include <string>
#include <vector>

namespace atrium {

class AudioDevice {
public:
    // Called on the device's real-time thread with planar stereo output buffers.
    using Callback = void (*)(void *ctx, float *left, float *right, int frames) ATRIUM_NONBLOCKING;

    virtual ~AudioDevice() = default;
    virtual bool start(Callback cb, void *ctx, std::string &err) = 0;
    // Synchronous: when this returns the callback is no longer running.
    virtual void stop() = 0;
    // False once the hardware disappeared (e.g. unplugged). Control thread only.
    virtual bool alive() const = 0;
    // The device's own (hardware) sample rate; the engine rate is converted to it if different.
    virtual double hardwareSampleRate() const = 0;
};

struct DeviceInfo {
    std::string uid;  // stable identifier
    std::string name;
    double sampleRate = 0;
    int outputChannels = 0;
    bool isDefault = false;
};

std::vector<DeviceInfo> listOutputDevices();
// Empty uid = follow the system default output.
std::unique_ptr<AudioDevice> createOutputDevice(const std::string &uid, double sampleRate, std::string &err);
double defaultOutputSampleRate(); // 0 if unknown

} // namespace atrium
