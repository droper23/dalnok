// Engine: compiling the model into immutable RenderState snapshots (split from engine.cpp, A-06).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"
#include "engine_internal.hpp"
#include "plugin_remote.hpp"

#include <algorithm>
#include <chrono>
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

// ---- Snapshot compilation -------------------------------------------------

StretchKey Engine::stretchKey(const ClipState &c) const { return stretchKeyOf(c); }

bool Engine::clipProcessing(const ClipState &c) const {
    if (!c.stretched()) return false;
    const PoolEntry *pe = poolEntry(c.media);
    return pe && pe->handle->impl && !cache_.find(stretchKey(c));
}

CompileInputs Engine::compileInputs(const PluginMap &plugins) const {
    return {model_, pool_, cache_, map_, sampleRate_, masterRuntime_, plugins};
}

int32_t Engine::snapshotMismatches() const { return compiler_.mismatches(compileInputs(pluginHost_.instances())); }

std::unique_ptr<RenderState> Engine::compile(std::vector<StretchJob> *needed, const PluginMap *pluginMap) const {
    return compiler_.compile(compileInputs(pluginMap ? *pluginMap : pluginHost_.instances()), needed, pluginMap == nullptr);
}

void Engine::commit() {
    std::vector<StretchJob> needed;
    auto state = compile(&needed);
    cache_.setNeeded(std::move(needed));
    updateStreamPlan(*state);
    // A snapshot replaced here was never observed by the audio thread, so it
    // is safe to delete immediately.
    delete pending_.exchange(state.release(), std::memory_order_acq_rel);
    collectGarbage();
    syncInput(); // undo, load or removing a track can change what monitors its input
}

void Engine::updateStreamPlan(const RenderState &state) {
    std::vector<StreamPlan::Segment> segments;
    for (const auto &t : state.tracks) {
        if (!t.content) continue;
        for (const auto &c : t.content->clips)
            if (c.media && c.media->streamed()) segments.push_back({c.media, c.start, c.offset, c.length});
        // Launcher clips: their first blocks stay resident for a launch, and the disk thread follows a launched slot's
        // own loop position through the track's launcher state.
        for (const auto &slot : t.content->slots)
            if (slot.clip.media && slot.clip.media->streamed())
                segments.push_back({slot.clip.media, 0, slot.clip.offset, slot.clip.length, t.runtime, slot.slot, slot.length});
    }
    if (segments.empty() && streamPlan_->segments.empty()) return;
    {
        std::lock_guard lock(streamPlan_->mu);
        streamPlan_->segments = std::move(segments);
        streamPlan_->lookahead = state.compensation;
    }
    StreamCache::shared().wake();
}

void Engine::leaseStreams(StreamCache::Lease &lease, const RenderState &state, int64_t from, int64_t n) {
    for (const auto &t : state.tracks) {
        if (!t.content) continue;
        for (const auto &c : t.content->clips) {
            if (!c.media || !c.media->streamed()) continue;
            const int64_t a = std::max(from, c.start), e = std::min(from + n, c.start + c.length);
            if (a < e) lease.need(c.media, c.offset + (a - c.start), e - a);
        }
    }
}

bool Engine::pollJobs() {
    if (!cache_.poll()) return false;
    commit();
    return true;
}

void Engine::renderPendingStretchesNow() {
    std::vector<StretchJob> needed;
    compile(&needed);
    if (needed.empty()) return;
    cache_.computeNow(needed);
    commit();
}

} // namespace dalnok
