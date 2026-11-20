// Streaming audio from disk (A-09). Long media are decoded once into a block-structured cache file at the engine rate;
// a process-wide cache keeps a bounded set of blocks resident. A disk thread loads blocks ahead of each engine's
// playhead and keeps the first blocks of every clip, so starts and seeks are covered. The audio thread only copies
// resident blocks (a missing block plays silence and is counted); it never reads files or allocates. Offline renders
// lease the blocks they need before rendering, so they go through the same read path.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "rt.hpp"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace dalnok {

class Media;

inline constexpr int64_t kStreamBlockFrames = 32768;

// The cache file behind one streamed Media. Created by Media::loadFile; immutable afterwards except for which of its
// blocks are resident.
class StreamSource {
public:
    StreamSource(std::string path, int fd, int32_t channels, int64_t frames, double rate);
    ~StreamSource();
    int32_t channels() const { return channels_; }
    int64_t frames() const { return frames_; }
    int64_t blockCount() const { return blocks_; }
    const std::string &path() const { return path_; }

    // Audio thread: copies frames [start, start + n) from resident blocks (n <= kMaxBlock); frames whose block is not
    // resident are zero. `r` may equal `l` for mono. Returns the number of frames that were missing.
    int readResident(int64_t start, int n, float *l, float *r) const DALNOK_NONBLOCKING;
    // Any thread that may block: reads straight from the file (offline work, stretching, close-up peaks).
    bool readFile(int64_t start, int64_t n, float *l, float *r) const;

private:
    friend class StreamCache;
    struct Block;
    bool readBlock(int64_t index, float *dst0, float *dst1) const; // one block from the file

    std::string path_;
    int fd_;
    int32_t channels_;
    int64_t frames_, blocks_;
    double rate_;
    std::unique_ptr<std::atomic<Block *>[]> table_; // resident block per index, or null
};

struct StreamStats {
    uint64_t residentBytes = 0, budgetBytes = 0, blocksLoaded = 0, blocksEvicted = 0, missedFrames = 0;
    uint32_t residentBlocks = 0, sources = 0;
};

// What one engine is about to play: its streamed clip segments and its playhead (registered by the Engine).
struct TrackRuntime;

struct StreamPlan {
    struct Segment {
        std::shared_ptr<const Media> media;
        int64_t start, offset, length; // timeline frame, frame within media, frames
        // Launcher slots: the track's launcher state. The slot loops every `loop` frames from where it was launched,
        // so its blocks are prefetched along its own position (`start` is unused).
        std::shared_ptr<const TrackRuntime> runtime;
        int32_t slot = -1;
        int64_t loop = 0;
    };
    std::mutex mu;                 // guards segments (control thread writes, disk thread reads)
    std::vector<Segment> segments;
    const std::atomic<int64_t> *position = nullptr; // the engine's playhead
    int64_t lookahead = 0;         // timeline frames rendered ahead of the playhead (delay compensation)
};

class StreamCache {
public:
    static StreamCache &shared();
    // Media longer than `seconds` stream from disk (default 60 s); the cache keeps at most `megabytes` resident
    // (default 256). DALNOK_STREAM_SECONDS and DALNOK_STREAM_CACHE_MB set the defaults.
    void setLimits(double seconds, int32_t megabytes);
    double streamAfterSeconds() const { return streamAfter_.load(std::memory_order_relaxed); }
    std::string directory() const;

    void addPlan(const std::shared_ptr<StreamPlan> &plan);
    void removePlan(const StreamPlan *plan);
    void wake(); // a plan changed or the playhead jumped

    // Blocks pinned for the lease's lifetime, loaded on the calling thread (offline renders).
    class Lease {
    public:
        ~Lease();
        // Makes every block that `media` frames [from, from + n) need resident and pinned.
        void need(const std::shared_ptr<const Media> &media, int64_t from, int64_t n);
        void clear();
    private:
        std::vector<std::pair<std::shared_ptr<const Media>, int64_t>> pinned_;
    };

    void countMissed(int frames) DALNOK_NONBLOCKING { missed_.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed); }
    StreamStats stats();
    void forget(StreamSource *source); // a source is being destroyed: drop its blocks

    std::atomic<int32_t> readers{0}; // audio threads inside readResident (blocks are reused only at zero)

private:
    StreamCache();
    ~StreamCache();
    void run();
    bool load(StreamSource *s, int64_t index, uint64_t tick, int pin); // with mu_ held
    StreamSource::Block *takeBlock();                                 // with mu_ held; may evict
    void release(StreamSource::Block *b);                             // unpublish, wait for readers, recycle

    std::mutex mu_;
    std::condition_variable cv_;
    std::vector<std::weak_ptr<StreamPlan>> plans_;
    std::vector<StreamSource::Block *> resident_, free_;
    std::vector<StreamSource *> sources_;
    size_t budgetBlocks_ = 0, allocated_ = 0;
    std::atomic<double> streamAfter_{60};
    uint64_t tick_ = 0, loaded_ = 0, evicted_ = 0;
    std::atomic<uint64_t> missed_{0};
    bool stop_ = false, woken_ = false;
    std::thread thread_;
};

} // namespace dalnok
