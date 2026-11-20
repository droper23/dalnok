// SPDX-License-Identifier: GPL-3.0-or-later
#include "stretch_cache.hpp"

#include "dalnok_dsp.h"

namespace dalnok {

std::shared_ptr<const Media> renderStretch(const StretchJob &job) {
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
