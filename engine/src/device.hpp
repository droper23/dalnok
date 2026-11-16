// Audio device abstraction. One implementation per platform (platform/<os>/).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "rt.hpp"

#include <memory>
#include <string>

namespace atrium {

class AudioDevice {
public:
    // Called on the device's real-time thread with planar stereo output buffers.
    using Callback = void (*)(void *ctx, float *left, float *right, int frames) ATRIUM_NONBLOCKING;

    virtual ~AudioDevice() = default;
    virtual bool start(Callback cb, void *ctx, std::string &err) = 0;
    // Synchronous: when this returns the callback is no longer running.
    virtual void stop() = 0;
};

std::unique_ptr<AudioDevice> createDefaultOutputDevice(double sampleRate);
double defaultOutputSampleRate(); // 0 if unknown

} // namespace atrium
