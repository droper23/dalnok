// Engine: offline rendering, export and statistics (split from engine.cpp, A-06).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"
#include "engine_internal.hpp"

#include <algorithm>
#include <cmath>
#include <set>
#include <unordered_map>
#include <utility>

namespace dalnok {
using detail::kTransportFadeSeconds;
using detail::nowNs;
using detail::atomicMax;
using detail::FlushDenormals;
using namespace detail;

bool Engine::renderOffline(int64_t start, int64_t frames, float *left, float *right) {
    [[maybe_unused]] const FlushDenormals flushDenormals;
    if (start < 0 || frames < 0 || !left || !right) return false;
    renderPendingStretchesNow();
    const auto offline = pluginHost_.offlineCopies(model_);
    const auto state = compile(nullptr, &offline);
    const bool anySolo = soloCount_.load() > 0;
    auto scratch = std::make_unique<Scratch>();
    std::vector<SynthState> synths(state->tracks.size());
    // Delay compensation: render the timeline ahead by the compensation and pre-roll that much first, so
    // output frame j is timeline frame start + j exactly as heard live.
    const int64_t m = state->compensation;
    float discardL[kMaxBlock], discardR[kMaxBlock];
    for (int64_t done = 0; done < m;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, m - done));
        renderBlock(*state, start + done, n, discardL, discardR, *scratch, false, anySolo, synths.data());
        done += n;
    }
    for (int64_t done = 0; done < frames;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, frames - done));
        renderBlock(*state, start + m + done, n, left + done, right + done, *scratch, false, anySolo, synths.data());
        done += n;
    }
    return true;
}

int32_t Engine::compensation() const {
    return compile(nullptr, &pluginHost_.instances())->compensation; // a throwaway snapshot with fresh delay lines (no live state touched)
}

bool Engine::renderToWav(const std::string &path, int64_t start, int64_t frames, int32_t bits, std::string &err) {
    [[maybe_unused]] const FlushDenormals flushDenormals;
    if (start < 0 || frames <= 0) {
        err = "invalid range";
        return false;
    }
    std::unique_ptr<WavWriter> w(openWavWriter(path, sampleRate_, bits, err));
    if (!w) return false;
    renderPendingStretchesNow();
    const auto offline = pluginHost_.offlineCopies(model_);
    const auto state = compile(nullptr, &offline);
    auto scratch = std::make_unique<Scratch>();
    std::vector<SynthState> synths(state->tracks.size());
    std::vector<float> l(kMaxBlock * 64), r(kMaxBlock * 64);
    const int64_t m = state->compensation; // pre-roll, as in renderOffline
    for (int64_t done = 0; done < m;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, m - done));
        renderBlock(*state, start + done, n, l.data(), r.data(), *scratch, false, soloCount_.load() > 0, synths.data());
        done += n;
    }
    for (int64_t done = 0; done < frames;) {
        const auto chunk = std::min<int64_t>(static_cast<int64_t>(l.size()), frames - done);
        for (int64_t o = 0; o < chunk;) {
            const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, chunk - o));
            renderBlock(*state, start + m + done + o, n, l.data() + o, r.data() + o, *scratch, false, soloCount_.load() > 0,
                        synths.data());
            o += n;
        }
        if (!w->write(l.data(), r.data(), chunk, err)) return false;
        done += chunk;
    }
    return w->close(err);
}

// ---- Diagnostics --------------------------------------------------------

void Engine::stats(DalnokStats &o) const {
    o.callbacks = callbacks_.load(std::memory_order_relaxed);
    o.frames_rendered = framesRendered_.load(std::memory_order_relaxed);
    o.max_callback_ns = maxCallbackNs_.load(std::memory_order_relaxed);
    o.last_callback_ns = lastCallbackNs_.load(std::memory_order_relaxed);
    o.max_frames_per_callback = maxFrames_.load(std::memory_order_relaxed);
    o.overloads = overloads_.load(std::memory_order_relaxed);
    o.snapshot_swaps = swaps_.load(std::memory_order_relaxed);
    o.retired_queue_depth = static_cast<uint32_t>(retired_.size());
    o.retired_queue_high_water = retiredHighWater_.load(std::memory_order_relaxed);
    o.pending_snapshot_callbacks = pendingSnapshotCallbacks_.load(std::memory_order_relaxed);
    o.snapshot_adoption_skips = adoptionSkips_.load(std::memory_order_relaxed);
}

void Engine::resetStats() {
    callbacks_ = 0;
    framesRendered_ = 0;
    maxCallbackNs_ = 0;
    lastCallbackNs_ = 0;
    maxFrames_ = 0;
    overloads_ = 0;
    swaps_ = 0;
    retiredHighWater_ = static_cast<uint32_t>(retired_.size());
    pendingSnapshotCallbacks_ = 0;
    adoptionSkips_ = 0;
}

#ifdef DALNOK_TEST_HOOKS
// Compiled only for the explicit saturation test build. Reproduce publication
// and the device callback without the normal control-thread collection calls.
void handoffSaturationFixture(uint64_t *out) {
    Engine engine(48000);
    float left[64]{}, right[64]{};
    engine.process(left, right, 64); // adopt the constructor's initial snapshot
    engine.resetStats();
    for (int i = 0; i < 100; ++i) {
        auto state = engine.compile();
        delete engine.pending_.exchange(state.release(), std::memory_order_acq_rel);
        engine.process(left, right, 64);
    }
    DalnokStats stats{};
    auto record = [&](int offset) {
        engine.stats(stats);
        out[offset] = stats.retired_queue_depth;
        out[offset + 1] = stats.retired_queue_high_water;
        out[offset + 2] = stats.pending_snapshot_callbacks;
        out[offset + 3] = stats.snapshot_adoption_skips;
        out[offset + 4] = stats.snapshot_swaps;
    };
    record(0);
    engine.resetStats();
    record(5);
    for (int i = 0; i < 3; ++i) engine.process(left, right, 64);
    record(10);
    engine.collectGarbage();
    record(15);
    engine.process(left, right, 64);
    record(20);
    engine.resetStats();
    record(25);
}
#endif

} // namespace dalnok
