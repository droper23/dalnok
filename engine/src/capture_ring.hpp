// Bounded single-producer/single-consumer interleaved audio capture buffer.
// Storage is allocated before capture; neither side allocates while operating.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "rt.hpp"
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace dalnok {

class CaptureRing {
public:
    // A power-of-two capacity preserves indexing across uint64_t counter wrap.
    CaptureRing(uint32_t capacityFrames, uint32_t channels)
        : capacity_(capacityFrames), channels_(channels), samples_(checkedSize(capacityFrames, channels)) {}

    // A block is accepted in full or rejected in full. The caller must stop the
    // take on rejection; the dropped count makes the failure observable.
    bool push(const float *interleaved, uint32_t frames) DALNOK_NONBLOCKING {
        const auto w = write_.load(std::memory_order_relaxed);
        const auto r = read_.load(std::memory_order_acquire);
        if (frames > capacity_ - (w - r)) {
            dropped_.fetch_add(frames, std::memory_order_relaxed);
            return false;
        }
        for (uint32_t i = 0; i < frames; ++i)
            for (uint32_t c = 0; c < channels_; ++c)
                samples_[((w + i) & (capacity_ - 1)) * channels_ + c] = interleaved[static_cast<size_t>(i) * channels_ + c];
        write_.store(w + frames, std::memory_order_release);
        return true;
    }

    // Consumer provides storage for at least maxFrames * channels samples.
    uint32_t pop(float *out, uint32_t maxFrames) DALNOK_NONBLOCKING {
        const auto r = read_.load(std::memory_order_relaxed);
        const auto w = write_.load(std::memory_order_acquire);
        const auto count = static_cast<uint32_t>(std::min<uint64_t>(maxFrames, w - r));
        for (uint32_t i = 0; i < count; ++i)
            for (uint32_t c = 0; c < channels_; ++c)
                out[static_cast<size_t>(i) * channels_ + c] = samples_[((r + i) & (capacity_ - 1)) * channels_ + c];
        read_.store(r + count, std::memory_order_release);
        return count;
    }

    uint64_t droppedFrames() const DALNOK_NONBLOCKING { return dropped_.load(std::memory_order_relaxed); }

private:
    static size_t checkedSize(uint32_t frames, uint32_t channels) {
        if (!frames || (frames & (frames - 1)) || !channels || channels > 64 || frames > 16'777'216)
            throw std::invalid_argument("invalid capture ring dimensions");
        return static_cast<size_t>(frames) * channels;
    }
    static_assert(std::atomic<uint64_t>::is_always_lock_free, "capture requires lock-free counters");
    const uint32_t capacity_, channels_;
    std::vector<float> samples_;
    alignas(64) std::atomic<uint64_t> write_{0};
    alignas(64) std::atomic<uint64_t> read_{0};
    std::atomic<uint64_t> dropped_{0};
};

} // namespace dalnok
