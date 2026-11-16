// Cache of time-stretched / pitch-shifted clip audio, rendered off the audio
// thread. The audio thread only ever sees finished, immutable Media.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "media.hpp"

#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace dalnok {

struct StretchKey {
    int32_t media;
    int64_t offset, sourceLength, outLength;
    int32_t pitchCents;
    bool preservePitch;
    bool operator<(const StretchKey &o) const {
        return std::tie(media, offset, sourceLength, outLength, pitchCents, preservePitch) <
               std::tie(o.media, o.offset, o.sourceLength, o.outLength, o.pitchCents, o.preservePitch);
    }
};

struct StretchJob {
    StretchKey key;
    std::shared_ptr<const Media> source;
    uint64_t generation = 0; // stamped by the cache; results from an older project are dropped
};

/// Renders one stretched region synchronously (any thread).
std::shared_ptr<const Media> renderStretch(const StretchJob &job);

class StretchCache {
public:
    StretchCache();
    ~StretchCache();

    std::shared_ptr<const Media> find(const StretchKey &k) const; // control thread
    void insert(const StretchKey &k, std::shared_ptr<const Media> m);
    /// Replaces the work queue with the jobs the current arrangement needs (stale jobs dropped).
    void setNeeded(std::vector<StretchJob> jobs);
    /// Moves finished renders into the cache. Returns true if anything arrived.
    bool poll();
    /// Renders everything still missing, synchronously (offline render/export).
    void computeNow(const std::vector<StretchJob> &jobs);
    int pending() const;
    void clear();

private:
    void work();
    std::map<StretchKey, std::shared_ptr<const Media>> cache_;
    mutable std::mutex mu_;
    std::condition_variable cv_;
    std::deque<StretchJob> queue_;
    struct Done { StretchKey key; std::shared_ptr<const Media> media; uint64_t generation; };
    std::vector<Done> done_;
    uint64_t generation_ = 1;
    bool busy_ = false, stop_ = false;
    std::thread worker_;
};

} // namespace dalnok
