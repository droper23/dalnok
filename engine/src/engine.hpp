// Engine: project model + undo (control thread) and live renderer (audio thread).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "atrium/atrium.h"
#include "device.hpp"
#include "json.hpp"
#include "render.hpp"

#include <atomic>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace atrium {

// ---- Project model (value type; copied wholesale for undo) ----------------

struct TrackState {
    AtriumTrackId id = 0;
    std::string name;
    int32_t color = 0;
    float gainDb = 0;
    float pan = 0;
    bool muted = false;
    std::shared_ptr<TrackRuntime> runtime; // shared across model copies
};

struct ClipState {
    AtriumClipId id = 0;
    AtriumTrackId track = 0;
    AtriumMediaId media = 0;
    int64_t start = 0, offset = 0, length = 0;
    std::string name;
};

struct Model {
    std::vector<TrackState> tracks; // display order
    std::vector<ClipState> clips;   // z-order: later = on top

    TrackState *track(AtriumTrackId id);
    const TrackState *track(AtriumTrackId id) const;
    ClipState *clip(AtriumClipId id);
    const ClipState *clip(AtriumClipId id) const;
};

struct PoolEntry {
    std::string path;                     // absolute source path ("" if generated)
    std::unique_ptr<AtriumMedia> handle;  // impl == nullptr when offline
    int64_t frames = 0;
    int32_t channels = 0;
};

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

    // Media pool
    AtriumMediaId poolAdd(std::shared_ptr<const Media> media, const std::string &path);
    const PoolEntry *poolEntry(AtriumMediaId id) const;

    // Model (read)
    const Model &model() const { return model_; }
    uint64_t revision() const { return revision_; }
    int64_t sessionLength() const;

    // Commands (each is an undo step unless inside a group). Return false and
    // set `err` on invalid input, leaving the model untouched.
    AtriumTrackId addTrack(const std::string &name, std::string &err);
    bool removeTrack(AtriumTrackId id, std::string &err);
    bool renameTrack(AtriumTrackId id, const std::string &name, std::string &err);
    bool setGainDb(AtriumTrackId id, float db, std::string &err);
    bool setPan(AtriumTrackId id, float pan, std::string &err);
    bool setMute(AtriumTrackId id, bool muted, std::string &err);
    AtriumClipId addClip(AtriumTrackId track, AtriumMediaId media, int64_t start, int64_t offset, int64_t length,
                         std::string &err);
    bool removeClip(AtriumClipId id, std::string &err);
    bool moveClip(AtriumClipId id, AtriumTrackId track, int64_t start, std::string &err);
    bool setClipRegion(AtriumClipId id, int64_t start, int64_t offset, int64_t length, std::string &err);
    AtriumClipId splitClip(AtriumClipId id, int64_t at, std::string &err);

    // Undo
    bool undo();
    bool redo();
    bool canUndo() const { return !undo_.empty(); }
    bool canRedo() const { return !redo_.empty(); }
    std::string undoName() const { return undo_.empty() ? "" : undo_.back().name; }
    std::string redoName() const { return redo_.empty() ? "" : redo_.back().name; }
    void beginGroup(const std::string &name);
    void endGroup();

    // Project
    void newProject();
    bool saveProject(const std::string &path, std::string &err);
    bool loadProject(const std::string &path, int32_t &missing, std::string &err);
    bool dirty() const { return revision_ != savedRevision_; }
    json::Value describe() const; // model as JSON (used by save and session.describe)

    // Transport
    void play() { playing_.store(true, std::memory_order_relaxed); }
    void pause() { playing_.store(false, std::memory_order_relaxed); }
    void seek(int64_t frame) { seekRequest_.store(std::max<int64_t>(0, frame), std::memory_order_relaxed); }
    bool playing() const { return playing_.load(std::memory_order_relaxed); }
    int64_t position() const { return position_.load(std::memory_order_relaxed); }

    // Offline
    bool renderOffline(int64_t start, int64_t frames, float *left, float *right);
    bool renderToWav(const std::string &path, int64_t start, int64_t frames, int32_t bits, std::string &err);

    void stats(AtriumStats &out) const;
    void resetStats();

private:
    struct UndoStep {
        std::string name;
        Model model;
    };

    // Runs `fn` against the model; on success records an undo step and publishes.
    template <typename F>
    bool edit(const char *name, bool structural, F &&fn);
    void restore(Model m);
    void syncRuntimes();
    std::unique_ptr<RenderState> compile() const;
    void commit();
    void resetModel();

    static void audioCallback(void *ctx, float *left, float *right, int frames) ATRIUM_NONBLOCKING;
    void process(float *left, float *right, int frames) ATRIUM_NONBLOCKING;

    double sampleRate_;

    // Control-thread state.
    Model model_;
    std::map<AtriumMediaId, PoolEntry> pool_;
    std::vector<UndoStep> undo_, redo_;
    int groupDepth_ = 0;
    bool groupRecorded_ = false;
    std::string groupName_;
    uint64_t revision_ = 1, savedRevision_ = 1;
    AtriumTrackId nextTrack_ = 1;
    AtriumClipId nextClip_ = 1;
    AtriumMediaId nextMedia_ = 1;
    int32_t nextColor_ = 0;
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

float dbToGain(float db);

} // namespace atrium
