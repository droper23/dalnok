// SPDX-License-Identifier: GPL-3.0-or-later
#include "stretch_cache.hpp"

#include "dalnok_dsp.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>

namespace dalnok {

// A warp map: each segment copied (1:1) or stretched on its own, laid end to end with a linear crossfade of
// 2 x warpCrossfade centred on every anchor (each piece runs that far past its ends, as far as the source allows).
static std::shared_ptr<const Media> renderWarp(const StretchJob &job) {
    const Media &src = *job.source;
    const WarpList &w = *job.warp;
    const int32_t ch = src.channelCount();
    const int64_t total = job.key.outLength, frames = src.frames();
    if (total <= 0 || w.size() < 2) return nullptr;
    const int64_t x = warpCrossfade(src.sampleRate());
    const double semis = job.key.pitchCents / 100.0;
    std::vector<std::vector<float>> out(static_cast<size_t>(ch), std::vector<float>(static_cast<size_t>(total), 0.0f));
    std::vector<float> l, r;
    auto readSource = [&](int64_t start, int64_t n) { // zeros outside the media
        l.assign(static_cast<size_t>(n), 0.0f);
        r.assign(static_cast<size_t>(n), 0.0f);
        const int64_t a = std::max<int64_t>(0, start), b = std::min(frames, start + n);
        if (b > a) src.read(a, b - a, l.data() + (a - start), r.data() + (a - start));
    };
    for (size_t k = 0; k + 1 < w.size(); ++k) {
        const int64_t s0 = w[k].source, s1 = w[k + 1].source, t0 = w[k].time, t1 = std::min(total, w[k + 1].time);
        if (t1 <= t0) continue;
        const int64_t xl = k > 0 ? x : 0, xr = k + 2 < w.size() ? x : 0;
        const int64_t tlLen = t1 - t0 + xl + xr;
        const bool copy = semis == 0 && std::llabs((s1 - s0) - (t1 - t0)) < std::max<int64_t>(1, x / 2);
        std::vector<std::vector<float>> piece(static_cast<size_t>(ch));
        if (copy) {
            readSource(s0 - xl, tlLen);
            piece[0] = l;
            if (ch > 1) piece[1] = r;
        } else {
            const double rate = static_cast<double>(s1 - s0) / static_cast<double>(t1 - t0);
            const int64_t a = s0 - std::llround(static_cast<double>(xl) * rate), n = std::llround(static_cast<double>(tlLen) * rate);
            readSource(a, std::max<int64_t>(1, n));
            const float *in[2] = {l.data(), r.data()};
            for (auto &p : piece) p.assign(static_cast<size_t>(tlLen), 0.0f);
            float *op[2] = {piece[0].data(), ch > 1 ? piece[1].data() : nullptr};
            if (dalnok_dsp_render_stretch(in, ch, std::max<int64_t>(1, n), op, tlLen, src.sampleRate(), semis, job.key.preservePitch ? 1 : 0) != 0)
                return nullptr;
        }
        for (int64_t i = 0; i < tlLen; ++i) {
            const int64_t t = t0 - xl + i;
            if (t < 0 || t >= total) continue;
            float g = 1.0f;
            if (xl > 0 && t < t0 + xl) g = static_cast<float>(t - (t0 - xl) + 0.5) / static_cast<float>(2 * xl);
            if (xr > 0 && t >= t1 - xr) g *= static_cast<float>((t1 + xr) - t - 0.5) / static_cast<float>(2 * xr);
            for (int32_t c = 0; c < ch; ++c) out[static_cast<size_t>(c)][static_cast<size_t>(t)] += g * piece[static_cast<size_t>(c)][static_cast<size_t>(i)];
        }
    }
    return std::make_shared<const Media>(std::move(out), src.sampleRate());
}

std::shared_ptr<const Media> renderStretch(const StretchJob &job) {
    if (job.warp && !job.warp->empty()) return renderWarp(job);
    const Media &src = *job.source;
    const auto &k = job.key;
    const int32_t ch = src.channelCount();
    const int64_t n = std::min(k.sourceLength, src.frames() - k.offset);
    if (n <= 0 || k.outLength <= 0) return nullptr;
    std::vector<const float *> in(static_cast<size_t>(ch));
    std::vector<std::vector<float>> out(static_cast<size_t>(ch), std::vector<float>(static_cast<size_t>(k.outLength)));
    std::vector<float *> op(static_cast<size_t>(ch));
    std::vector<float> streamedL, streamedR; // a streamed source is read from its cache file (worker thread)
    if (src.streamed()) {
        streamedL.resize(static_cast<size_t>(n));
        streamedR.resize(static_cast<size_t>(n));
        src.read(k.offset, n, streamedL.data(), streamedR.data());
    }
    for (int32_t c = 0; c < ch; ++c) {
        in[static_cast<size_t>(c)] = src.streamed() ? (c == 0 ? streamedL.data() : streamedR.data()) : src.channel(c) + k.offset;
        op[static_cast<size_t>(c)] = out[static_cast<size_t>(c)].data();
    }
    if (dalnok_dsp_render_stretch(in.data(), ch, n, op.data(), k.outLength, src.sampleRate(), k.pitchCents / 100.0,
                                  k.preservePitch ? 1 : 0) != 0)
        return nullptr;
    return std::make_shared<const Media>(std::move(out), src.sampleRate());
}

StretchCache::StretchCache() : worker_([this] { work(); }) {}

StretchCache::~StretchCache() {
    {
        std::lock_guard lock(mu_);
        stop_ = true;
        queue_.clear();
    }
    cv_.notify_all();
    worker_.join();
}

std::shared_ptr<const Media> StretchCache::find(const StretchKey &k) const {
    auto it = cache_.find(k);
    return it == cache_.end() ? nullptr : it->second;
}

void StretchCache::insert(const StretchKey &k, std::shared_ptr<const Media> m) {
    if (m) cache_[k] = std::move(m);
}

void StretchCache::setNeeded(std::vector<StretchJob> jobs) {
    {
        std::lock_guard lock(mu_);
        queue_.clear();
        for (auto &j : jobs) {
            bool finished = false;
            for (const auto &d : done_) finished |= !(d.key < j.key) && !(j.key < d.key);
            j.generation = generation_;
            if (!cache_.count(j.key) && !finished) queue_.push_back(std::move(j));
        }
    }
    cv_.notify_all();
}

bool StretchCache::poll() {
    std::vector<Done> got;
    uint64_t gen;
    {
        std::lock_guard lock(mu_);
        got.swap(done_);
        gen = generation_;
    }
    bool any = false;
    for (auto &d : got)
        if (d.generation == gen) { insert(d.key, std::move(d.media)); any = true; }
    return any;
}

void StretchCache::computeNow(const std::vector<StretchJob> &jobs) {
    poll();
    for (const auto &j : jobs)
        if (!cache_.count(j.key)) insert(j.key, renderStretch(j));
}

int StretchCache::pending() const {
    std::lock_guard lock(mu_);
    return static_cast<int>(queue_.size()) + (busy_ ? 1 : 0) + static_cast<int>(done_.size());
}

void StretchCache::clear() {
    {
        std::lock_guard lock(mu_);
        queue_.clear();
        done_.clear();
        ++generation_;
    }
    cache_.clear();
}

void StretchCache::work() {
    for (;;) {
        StretchJob job;
        {
            std::unique_lock lock(mu_);
            cv_.wait(lock, [this] { return stop_ || !queue_.empty(); });
            if (stop_) return;
            job = std::move(queue_.front());
            queue_.pop_front();
            busy_ = true;
        }
        auto result = renderStretch(job);
        {
            std::lock_guard lock(mu_);
            busy_ = false;
            if (result) done_.push_back({job.key, std::move(result), job.generation});
        }
    }
}

} // namespace dalnok
