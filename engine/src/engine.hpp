// Engine: session model (control thread) + live renderer (audio thread).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "atrium/atrium.h"
#include "device.hpp"
#include "render.hpp"

#include <atomic>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace atrium {

class Engine {
public:
    explicit Engine(double sampleRate);
    ~Engine();

    double sampleRate() const { return sampleRate_; }

    // Device
    bool startDevice(std::string &err);
    void stopDevice();
    bool deviceRunning() const { return device_ != nullptr; }
    void collectGarbage();

    // Session model
    AtriumTrackId addTrack(const std::string &name);
    bool removeTrack(AtriumTrackId id);
    bool setGainDb(AtriumTrackId id, float db);
    bool setPan(AtriumTrackId id, float pan);
    bool setMute(AtriumTrackId id, bool muted);
    AtriumClipId addClip(AtriumTrackId track, std::shared_ptr<const Media> media, int64_t start, int64_t offset,
                         int64_t length);
    bool removeClip(AtriumClipId id);
    int64_t sessionLength() const;

    // Transport
    void play() { playing_.store(true, std::memory_order_relaxed); }
    void pause() { playing_.store(false, std::memory_order_relaxed); }
    void seek(int64_t frame) { seekRequest_.store(std::max<int64_t>(0, frame), std::memory_order_relaxed); }
    bool playing() const { return playing_.load(std::memory_order_relaxed); }
    int64_t position() const { return position_.load(std::memory_order_relaxed); }

    // Offline
    std::unique_ptr<RenderState> compile() const;
    bool renderOffline(int64_t start, int64_t frames, float *left, float *right);
    bool renderToWav(const std::string &path, int64_t start, int64_t frames, int32_t bits, std::string &err);

    void stats(AtriumStats &out) const;
    void resetStats();

private:
    struct Track {
        std::string name;
        std::shared_ptr<TrackRuntime> runtime = std::make_shared<TrackRuntime>();
    };
    struct Clip {
        AtriumTrackId track;
        std::shared_ptr<const Media> media;
        int64_t start, offset, length;
    };

    void commit();
    static void audioCallback(void *ctx, float *left, float *right, int frames) ATRIUM_NONBLOCKING;
    void process(float *left, float *right, int frames) ATRIUM_NONBLOCKING;

    double sampleRate_;

    // Control-thread state.
    std::map<AtriumTrackId, Track> tracks_; // id order == creation order
    std::map<AtriumClipId, Clip> clips_;
    AtriumTrackId nextTrack_ = 1;
    AtriumClipId nextClip_ = 1;
    std::unique_ptr<AudioDevice> device_;

    // Control -> audio handoff.
    std::atomic<RenderState *> pending_{nullptr};
    SpscQueue<RenderState *, 64> retired_;

    // Audio-thread state.
    RenderState *current_ = nullptr;
    Scratch scratch_{};
    float transportGain_ = 0.0f;
    int64_t pendingSeek_ = -1;
    int64_t rtPosition_ = 0;

    // Shared atomics.
    std::atomic<bool> playing_{false};
    std::atomic<int64_t> seekRequest_{-1};
    std::atomic<int64_t> position_{0};

    // Diagnostics (written by the audio thread).
    std::atomic<uint64_t> callbacks_{0}, framesRendered_{0}, maxCallbackNs_{0}, lastCallbackNs_{0};
    std::atomic<uint32_t> maxFrames_{0}, overloads_{0}, swaps_{0};
};

} // namespace atrium
