// Real-time helpers shared across the engine.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <array>
#include <atomic>
#include <cstddef>

// Functions on the audio thread's path are marked DALNOK_NONBLOCKING. Clang
// verifies at compile time (-Wfunction-effects) that they do not allocate,
// lock, throw, or call anything not itself proven non-blocking.
#if defined(__clang__) && __has_cpp_attribute(clang::nonblocking)
#define DALNOK_NONBLOCKING noexcept [[clang::nonblocking]]
#else
#define DALNOK_NONBLOCKING noexcept
#endif

namespace dalnok {

// Wait-free single-producer / single-consumer ring of trivially copyable values.
template <typename T, std::size_t Capacity>
class SpscQueue {
    static_assert((Capacity & (Capacity - 1)) == 0, "Capacity must be a power of two");

public:
    bool push(const T &v) DALNOK_NONBLOCKING {
        const auto w = write_.load(std::memory_order_relaxed);
        if (w - read_.load(std::memory_order_acquire) == Capacity) return false;
        slots_[w & (Capacity - 1)] = v;
        write_.store(w + 1, std::memory_order_release);
        return true;
    }
    bool pop(T &out) DALNOK_NONBLOCKING {
        const auto r = read_.load(std::memory_order_relaxed);
        if (r == write_.load(std::memory_order_acquire)) return false;
        out = slots_[r & (Capacity - 1)];
        read_.store(r + 1, std::memory_order_release);
        return true;
    }
    bool full() const DALNOK_NONBLOCKING {
        return write_.load(std::memory_order_acquire) - read_.load(std::memory_order_acquire) == Capacity;
    }
    std::size_t size() const DALNOK_NONBLOCKING {
        const auto r = read_.load(std::memory_order_acquire);
        const auto depth = write_.load(std::memory_order_acquire) - r;
        // An observer that is neither producer nor consumer can sample a stale
        // read index while both endpoints advance; never report more than capacity.
        return depth > Capacity ? Capacity : depth;
    }

private:
    std::array<T, Capacity> slots_{};
    alignas(64) std::atomic<std::size_t> write_{0};
    alignas(64) std::atomic<std::size_t> read_{0};
};

} // namespace dalnok
