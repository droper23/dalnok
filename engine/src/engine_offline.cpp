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
    // Streamed media (A-09): pin the blocks each second needs before rendering it.
    StreamCache::Lease lease;
    const int64_t window = static_cast<int64_t>(sampleRate_);
    int64_t leasedTo = start;
    const auto lease_ = [&](int64_t pos, int n) {
        if (pos + n <= leasedTo) return;
        lease.clear();
        leaseStreams(lease, *state, pos, window + n);
        leasedTo = pos + window + n;
    };
    float discardL[kMaxBlock], discardR[kMaxBlock];
    for (int64_t done = 0; done < m;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, m - done));
        lease_(start + done, n);
        renderBlock(*state, start + done, n, discardL, discardR, *scratch, false, anySolo, synths.data());
        done += n;
    }
    for (int64_t done = 0; done < frames;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, frames - done));
        lease_(start + m + done, n);
        renderBlock(*state, start + m + done, n, left + done, right + done, *scratch, false, anySolo, synths.data());
        done += n;
    }
    return true;
}

int32_t Engine::compensation() const {
    return compile(nullptr, &pluginHost_.instances())->compensation; // a throwaway snapshot with fresh delay lines (no live state touched)
}

bool Engine::renderToWav(const std::string &path, int64_t start, int64_t frames, int32_t bits, std::string &err,
                         int64_t maxTail, int64_t *tailWritten) {
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
    StreamCache::Lease lease; // streamed media (A-09), as in renderOffline
    const int64_t window = static_cast<int64_t>(sampleRate_);
    int64_t leasedTo = start;
    const auto lease_ = [&](int64_t pos, int64_t n) {
        if (pos + n <= leasedTo) return;
        lease.clear();
        leaseStreams(lease, *state, pos, window + n);
        leasedTo = pos + window + n;
    };
    for (int64_t done = 0; done < m;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, m - done));
        lease_(start + done, n);
        renderBlock(*state, start + done, n, l.data(), r.data(), *scratch, false, soloCount_.load() > 0, synths.data());
        done += n;
    }
    for (int64_t done = 0; done < frames;) {
        const auto chunk = std::min<int64_t>(static_cast<int64_t>(l.size()), frames - done);
        for (int64_t o = 0; o < chunk;) {
            const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, chunk - o));
            lease_(start + m + done + o, n);
            renderBlock(*state, start + m + done + o, n, l.data() + o, r.data() + o, *scratch, false, soloCount_.load() > 0,
                        synths.data());
            o += n;
        }
        if (!w->write(l.data(), r.data(), chunk, err)) return false;
        done += chunk;
    }
    // Tail: keep rendering past the end (synth releases, delay and reverb decay, compressor release) until half a
    // second stays below -100 dBFS or `maxTail` frames are rendered, so an export never ends in a hard cut. Quiet
    // blocks are held back and only written once something audible follows, so the file ends at the last audible
    // block: a mix that already ends in silence exports at exactly its length.
    int64_t tail = 0, rendered = 0, quiet = 0;
    const int64_t quietNeeded = static_cast<int64_t>(sampleRate_ * 0.5);
    std::vector<float> heldL, heldR;
    while (rendered < maxTail && quiet < quietNeeded) {
        const int n = static_cast<int>(std::min<int64_t>({kMaxBlock, maxTail - rendered}));
        lease_(start + m + frames + rendered, n);
        renderBlock(*state, start + m + frames + rendered, n, l.data(), r.data(), *scratch, false,
                    soloCount_.load() > 0, synths.data());
        rendered += n;
        float peak = 0;
        for (int i = 0; i < n; ++i) peak = std::max({peak, std::fabs(l[i]), std::fabs(r[i])});
        if (peak < 1e-5f) {
            quiet += n;
            heldL.insert(heldL.end(), l.data(), l.data() + n);
            heldR.insert(heldR.end(), r.data(), r.data() + n);
            continue;
        }
        quiet = 0;
        if (!heldL.empty()) {
            if (!w->write(heldL.data(), heldR.data(), static_cast<int64_t>(heldL.size()), err)) return false;
            tail += static_cast<int64_t>(heldL.size());
            heldL.clear();
            heldR.clear();
        }
        if (!w->write(l.data(), r.data(), n, err)) return false;
        tail += n;
    }
    if (tailWritten) *tailWritten = tail;
    return w->close(err);
}

DalnokTrackId Engine::bounceInPlace(DalnokTrackId track, const std::string &path, std::string &err) {
    [[maybe_unused]] const FlushDenormals flushDenormals;
    const TrackState *src = model_.track(track);
    if (!src) return fail(err, "no such track"), 0;
    if (src->kind == kTrackBus) return fail(err, "buses can't be bounced in place (bounce their tracks)"), 0;
    int64_t start = INT64_MAX, end = 0;
    for (const auto &c : model_.clips)
        if (c.track == track && c.slot < 0 && !c.alt && !c.muted) {
            start = std::min(start, c.start);
            end = std::max(end, c.start + c.length);
        }
    if (end <= start) return fail(err, "the track has no clips to bounce"), 0;

    renderPendingStretchesNow();
    const auto offline = pluginHost_.offlineCopies(model_);
    const auto state = compile(nullptr, &offline);
    size_t index = state->tracks.size();
    for (size_t i = 0; i < state->tracks.size(); ++i) if (state->tracks[i].id == static_cast<int32_t>(track)) index = i;
    if (index == state->tracks.size()) return fail(err, "the track is not rendered"), 0;
    const int64_t latency = state->tracks[index].latency; // the track's plug-ins delay its output by this much
    auto scratch = std::make_unique<Scratch>();
    std::vector<SynthState> synths(state->tracks.size());
    std::vector<float> l(kMaxBlock), r(kMaxBlock);
    std::vector<float> outL, outR;
    StreamCache::Lease lease;
    const int64_t window = static_cast<int64_t>(sampleRate_);
    int64_t leasedTo = start;
    const int64_t body = end - start + latency, maxTail = static_cast<int64_t>(sampleRate_ * 10);
    const int64_t quietNeeded = static_cast<int64_t>(sampleRate_ * 0.5);
    int64_t lastLoud = 0, quiet = 0;
    for (int64_t done = 0; done < body || (done < body + maxTail && quiet < quietNeeded);) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, (done < body ? body : body + maxTail) - done));
        const int64_t pos = start + done;
        if (pos + n > leasedTo) {
            lease.clear();
            leaseStreams(lease, *state, pos, window + n);
            leasedTo = pos + window + n;
        }
        renderBlock(*state, pos, n, l.data(), r.data(), *scratch, false, false, synths.data());
        const float *cl = state->chainL.data() + index * kMaxBlock, *cr = state->chainR.data() + index * kMaxBlock;
        outL.insert(outL.end(), cl, cl + n);
        outR.insert(outR.end(), cr, cr + n);
        float peak = 0;
        for (int i = 0; i < n; ++i) peak = std::max({peak, std::fabs(cl[i]), std::fabs(cr[i])});
        done += n;
        if (peak >= 1e-5f) { lastLoud = done; quiet = 0; } else if (done > body) quiet += n;
    }
    // Drop the plug-ins' latency (the bounce lines up with the clips) and the silent end of the tail.
    const int64_t keep = std::max(end - start, lastLoud - latency);
    const auto from = static_cast<size_t>(std::min<int64_t>(latency, static_cast<int64_t>(outL.size())));
    const auto to = std::min(outL.size(), from + static_cast<size_t>(keep));
    std::unique_ptr<WavWriter> w(openWavWriter(path, sampleRate_, 32, err));
    if (!w || !w->write(outL.data() + from, outR.data() + from, static_cast<int64_t>(to - from), err) || !w->close(err)) return 0;
    auto media = Media::loadFile(path, sampleRate_, err);
    if (!media) return 0;
    const DalnokMediaId mid = poolAdd(media, path);

    const TrackState copy = *src;
    beginGroup("Bounce in Place");
    DalnokTrackId out = addTrack(copy.name + " Bounce", err);
    int32_t at = 0;
    for (size_t i = 0; i < model_.tracks.size(); ++i) if (model_.tracks[i].id == track) at = static_cast<int32_t>(i) + 1;
    const bool ok = out && moveTrack(out, at, err) && addClip(out, mid, start, 0, static_cast<int64_t>(to - from), err) &&
                    setTrackOutput(out, copy.output, err) && setGainDb(out, copy.gainDb, err) && setPan(out, copy.pan, err) &&
                    setMute(track, true, err);
    endGroup();
    if (!ok) {
        if (out) undo();
        return 0;
    }
    return out;
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
