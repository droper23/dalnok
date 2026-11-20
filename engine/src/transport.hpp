// Transport state shared by the control thread and the audio thread (A-06): play state, playhead, seek requests,
// cycle, punch, metronome and count-in. Everything is an atomic; the audio thread reads it at each callback.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <string>

namespace dalnok {

struct Transport {
    std::atomic<bool> playing{false};
    std::atomic<int64_t> seekRequest{-1}; // control thread asks; the audio thread moves the playhead at its next callback
    std::atomic<int64_t> position{0};     // the playhead (audio thread writes)
    std::atomic<bool> cycleOn{false};
    std::atomic<int64_t> cycleStart{0}, cycleEnd{0};
    std::atomic<int64_t> punchIn{INT64_MIN}, punchOut{INT64_MAX};
    std::atomic<bool> metronome{false};
    std::atomic<float> metronomeLevel{0.5f};
    std::atomic<int64_t> countInUntil{0};

    void play() { playing.store(true, std::memory_order_relaxed); }
    void pause() { playing.store(false, std::memory_order_relaxed); }
    void seek(int64_t frame) { seekRequest.store(std::max<int64_t>(0, frame), std::memory_order_relaxed); }

    // Cycle (loop) playback between two frames; (false, 0, 0) clears the region.
    bool setCycle(bool on, int64_t start, int64_t end, std::string &err) {
        if (!on && start == 0 && end == 0) {
            cycleOn.store(false, std::memory_order_release);
            cycleStart.store(0, std::memory_order_relaxed);
            cycleEnd.store(0, std::memory_order_relaxed);
            return true;
        }
        if (start < 0 || end - start < 64 || end > (int64_t{1} << 48)) {
            err = "cycle needs 0 <= start and end at least 64 frames after start";
            return false;
        }
        cycleOn.store(false, std::memory_order_release); // the audio thread never sees a half-updated range while on
        cycleStart.store(start, std::memory_order_relaxed);
        cycleEnd.store(end, std::memory_order_relaxed);
        cycleOn.store(on, std::memory_order_release);
        return true;
    }
    void cycle(bool &on, int64_t &start, int64_t &end) const {
        on = cycleOn.load(std::memory_order_relaxed);
        start = cycleStart.load(std::memory_order_relaxed);
        end = cycleEnd.load(std::memory_order_relaxed);
    }

    // Punch: a take only records [in, out).
    bool setPunch(bool on, int64_t in, int64_t out, std::string &err) {
        if (on && (in < 0 || out <= in)) { err = "punch needs 0 <= in < out"; return false; }
        punchIn.store(on ? in : INT64_MIN, std::memory_order_relaxed);
        punchOut.store(on ? out : INT64_MAX, std::memory_order_relaxed);
        return true;
    }
    void punch(bool &on, int64_t &in, int64_t &out) const {
        in = punchIn.load(std::memory_order_relaxed);
        out = punchOut.load(std::memory_order_relaxed);
        on = in != INT64_MIN;
    }

    void setMetronome(bool on, float level) {
        metronomeLevel.store(std::clamp(level, 0.0f, 1.0f), std::memory_order_relaxed);
        metronome.store(on, std::memory_order_relaxed);
    }
    void setCountIn(int64_t frame) { countInUntil.store(std::max<int64_t>(0, frame), std::memory_order_relaxed); }
};

} // namespace dalnok
