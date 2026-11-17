// Off-thread drain for the recording capture buffer.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "capture_ring.hpp"
#include <atomic>
#include <chrono>
#include <cstdint>
#include <thread>
#include <vector>

namespace dalnok {

// The sink and this worker are owned by the control thread; write and finish
// are called exclusively by the writer thread. A failed sink retains its data.
class CaptureSink {
public:
    virtual ~CaptureSink() = default;
    virtual bool write(const float *interleaved, uint32_t frames) = 0;
    virtual bool finish() = 0;
};

class CaptureWriter {
public:
    enum class Error : uint32_t { none = 0, overflow = 1, write = 2, finalize = 4 };

    CaptureWriter(uint32_t capacity, uint32_t channels, CaptureSink &sink)
        : ring_(capacity, channels), sink_(sink), scratch_(static_cast<size_t>(channels) * 256) {}
    CaptureWriter(const CaptureWriter &) = delete;
    CaptureWriter &operator=(const CaptureWriter &) = delete;
    ~CaptureWriter() { stop(); }

    // Start and stop only from the control thread. Stop the device callback
    // before stop(), so there is no producer after the drain begins.
    void start() { thread_ = std::thread([this] { drain(); }); }
    void stop() {
        stopping_.store(true, std::memory_order_release);
        if (thread_.joinable()) thread_.join();
    }
    bool push(const float *samples, uint32_t frames) DALNOK_NONBLOCKING {
        if (error_.load(std::memory_order_acquire) != 0 || stopping_.load(std::memory_order_acquire)) {
            rejected_.fetch_add(frames, std::memory_order_relaxed);
            return false;
        }
        if (!ring_.push(samples, frames)) {
            error_.fetch_or(static_cast<uint32_t>(Error::overflow), std::memory_order_release);
            return false;
        }
        captured_.fetch_add(frames, std::memory_order_relaxed);
        return true;
    }
    bool hasError(Error value) const { return (error_.load(std::memory_order_acquire) & static_cast<uint32_t>(value)) != 0; }
    bool ok() const { return error_.load(std::memory_order_acquire) == 0; }
    uint64_t capturedFrames() const { return captured_.load(std::memory_order_relaxed); }
    uint64_t writtenFrames() const { return written_.load(std::memory_order_relaxed); }
    uint64_t droppedFrames() const { return ring_.droppedFrames() + rejected_.load(std::memory_order_relaxed); }

private:
    void setError(Error value) {
        error_.fetch_or(static_cast<uint32_t>(value), std::memory_order_release);
    }
    void drain() {
        bool writeOK = true;
        while (writeOK) {
            // Observe stop before checking the queue. Once the producer has
            // stopped, this acquire makes its final published block visible.
            const bool stopping = stopping_.load(std::memory_order_acquire);
            const uint32_t frames = ring_.pop(scratch_.data(), 256);
            if (frames) {
                if (!sink_.write(scratch_.data(), frames)) { setError(Error::write); writeOK = false; }
                else written_.fetch_add(frames, std::memory_order_relaxed);
            } else if (stopping) {
                break;
            } else {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
        if (!sink_.finish()) setError(Error::finalize);
    }
    static_assert(std::atomic<uint32_t>::is_always_lock_free && std::atomic<bool>::is_always_lock_free);
    CaptureRing ring_;
    CaptureSink &sink_;
    std::vector<float> scratch_;
    std::thread thread_;
    std::atomic<bool> stopping_{false};
    std::atomic<uint32_t> error_{0};
    std::atomic<uint64_t> captured_{0}, written_{0}, rejected_{0};
};

} // namespace dalnok
