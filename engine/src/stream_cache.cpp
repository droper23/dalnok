// SPDX-License-Identifier: GPL-3.0-or-later
#include "stream_cache.hpp"
#include "media.hpp"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

namespace dalnok {

struct StreamSource::Block {
    StreamSource *owner = nullptr;
    int64_t index = 0;
    uint64_t lastWanted = 0;
    int pins = 0; // leases holding it (offline renders)
    float data[2][kStreamBlockFrames];
};

namespace {
constexpr int64_t kHeaderBytes = 4096;
}

StreamSource::StreamSource(std::string path, int fd, int32_t channels, int64_t frames, double rate)
    : path_(std::move(path)), fd_(fd), channels_(std::clamp(channels, 1, 2)), frames_(frames),
      blocks_((frames + kStreamBlockFrames - 1) / kStreamBlockFrames), rate_(rate),
      table_(new std::atomic<Block *>[static_cast<size_t>(blocks_)]) {
    for (int64_t i = 0; i < blocks_; ++i) table_[i].store(nullptr, std::memory_order_relaxed);
}

StreamSource::~StreamSource() {
    StreamCache::shared().forget(this);
    if (fd_ >= 0) ::close(fd_);
}

int StreamSource::readResident(int64_t start, int n, float *l, float *r) const DALNOK_NONBLOCKING {
    // Shared() is constructed before any source exists (Media::loadFile), so this is a plain load.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    StreamCache &cache = StreamCache::shared();
#pragma clang diagnostic pop
    int missed = 0;
    cache.readers.fetch_add(1, std::memory_order_seq_cst);
    for (int done = 0; done < n;) {
        const int64_t at = start + done;
        const int64_t index = at / kStreamBlockFrames, off = at % kStreamBlockFrames;
        const int take = static_cast<int>(std::min<int64_t>(n - done, kStreamBlockFrames - off));
        const Block *b = at >= 0 && index < blocks_ ? table_[index].load(std::memory_order_seq_cst) : nullptr;
        if (b) {
            const float *s0 = b->data[0] + off, *s1 = b->data[channels_ > 1 ? 1 : 0] + off;
            for (int i = 0; i < take; ++i) { l[done + i] = s0[i]; r[done + i] = s1[i]; }
        } else {
            for (int i = 0; i < take; ++i) l[done + i] = r[done + i] = 0.0f;
            missed += take;
        }
        done += take;
    }
    cache.readers.fetch_sub(1, std::memory_order_release);
    if (missed) cache.countMissed(missed);
    return missed;
}

bool StreamSource::readBlock(int64_t index, float *dst0, float *dst1) const {
    const size_t bytes = sizeof(float) * kStreamBlockFrames;
    const off_t base = kHeaderBytes + static_cast<off_t>(index) * static_cast<off_t>(bytes) * channels_;
    float *dst[2] = {dst0, dst1};
    for (int c = 0; c < channels_; ++c) {
        size_t got = 0;
        while (got < bytes) {
            const ssize_t n = ::pread(fd_, reinterpret_cast<char *>(dst[c]) + got, bytes - got, base + static_cast<off_t>(c * bytes + got));
            if (n <= 0) { std::memset(reinterpret_cast<char *>(dst[c]) + got, 0, bytes - got); return false; }
            got += static_cast<size_t>(n);
        }
    }
    return true;
}

bool StreamSource::readFile(int64_t start, int64_t n, float *l, float *r) const {
    std::vector<float> a(kStreamBlockFrames), b(kStreamBlockFrames);
    bool ok = true;
    for (int64_t done = 0; done < n;) {
        const int64_t at = start + done;
        const int64_t index = at / kStreamBlockFrames, off = at % kStreamBlockFrames;
        const int64_t take = std::min(n - done, kStreamBlockFrames - off);
        if (at < 0 || index >= blocks_) {
            std::fill(l + done, l + done + take, 0.0f);
            if (r) std::fill(r + done, r + done + take, 0.0f);
        } else {
            ok = readBlock(index, a.data(), b.data()) && ok;
            std::copy(a.begin() + off, a.begin() + off + take, l + done);
            if (r) std::copy((channels_ > 1 ? b : a).begin() + off, (channels_ > 1 ? b : a).begin() + off + take, r + done);
        }
        done += take;
    }
    return ok;
}

// ---- Cache ------------------------------------------------------------------------------------------------------

StreamCache &StreamCache::shared() {
    static StreamCache *cache = new StreamCache(); // never destroyed: sources may outlive static destruction order
    return *cache;
}

StreamCache::StreamCache() {
    double seconds = 60;
    int32_t mb = 256;
    if (const char *s = std::getenv("DALNOK_STREAM_SECONDS"); s && std::atof(s) > 0) seconds = std::atof(s);
    if (const char *m = std::getenv("DALNOK_STREAM_CACHE_MB"); m && std::atoi(m) > 0) mb = std::atoi(m);
    setLimits(seconds, mb);
    thread_ = std::thread([this] { run(); });
}

StreamCache::~StreamCache() {
    { std::lock_guard lock(mu_); stop_ = true; }
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
}

void StreamCache::setLimits(double seconds, int32_t megabytes) {
    streamAfter_.store(seconds > 0 ? seconds : 60, std::memory_order_relaxed);
    {
        std::lock_guard lock(mu_);
        budgetBlocks_ = std::max<size_t>(8, static_cast<size_t>(std::max(1, megabytes)) * 1024 * 1024 / sizeof(StreamSource::Block));
    }
    wake();
}

std::string StreamCache::directory() const {
    if (const char *d = std::getenv("DALNOK_STREAM_DIR"); d && *d) return d;
    char buf[1024];
    const size_t n = confstr(_CS_DARWIN_USER_CACHE_DIR, buf, sizeof buf);
    std::string base = n > 0 && n <= sizeof buf ? std::string(buf) : std::string("/tmp/");
    if (!base.empty() && base.back() != '/') base += '/';
    return base + "dalnok-stream";
}

void StreamCache::addPlan(const std::shared_ptr<StreamPlan> &plan) {
    { std::lock_guard lock(mu_); plans_.push_back(plan); }
    wake();
}

void StreamCache::removePlan(const StreamPlan *plan) {
    std::lock_guard lock(mu_);
    std::erase_if(plans_, [&](const std::weak_ptr<StreamPlan> &w) { auto p = w.lock(); return !p || p.get() == plan; });
}

void StreamCache::wake() {
    { std::lock_guard lock(mu_); woken_ = true; }
    cv_.notify_all();
}

void StreamCache::release(StreamSource::Block *b) {
    if (b->owner) {
        b->owner->table_[b->index].store(nullptr, std::memory_order_seq_cst);
        // A reader that saw the block before it was unpublished finishes within one copy.
        while (readers.load(std::memory_order_seq_cst) != 0) std::this_thread::sleep_for(std::chrono::microseconds(20));
        b->owner = nullptr;
    }
    std::erase(resident_, b);
}

StreamSource::Block *StreamCache::takeBlock() {
    if (!free_.empty()) { auto *b = free_.back(); free_.pop_back(); return b; }
    if (allocated_ < budgetBlocks_) { ++allocated_; return new StreamSource::Block(); }
    StreamSource::Block *victim = nullptr;
    for (auto *b : resident_)
        if (b->pins == 0 && b->lastWanted < tick_ && (!victim || b->lastWanted < victim->lastWanted)) victim = b;
    if (!victim) return nullptr;
    release(victim);
    ++evicted_;
    return victim;
}

bool StreamCache::load(StreamSource *s, int64_t index, uint64_t tick, int pin) {
    StreamSource::Block *b = takeBlock();
    if (!b && pin) { ++allocated_; b = new StreamSource::Block(); } // an offline lease always gets its block
    if (!b) return false;
    s->readBlock(index, b->data[0], b->data[1]);
    b->owner = s;
    b->index = index;
    b->lastWanted = tick;
    b->pins = pin;
    resident_.push_back(b);
    s->table_[index].store(b, std::memory_order_seq_cst);
    ++loaded_;
    return true;
}

void StreamCache::forget(StreamSource *source) {
    std::lock_guard lock(mu_);
    for (auto *b : std::vector<StreamSource::Block *>(resident_))
        if (b->owner == source) { release(b); b->pins = 0; free_.push_back(b); }
}

void StreamCache::run() {
    struct Want { StreamSource *source; int64_t index; int64_t priority; };
    std::unique_lock lock(mu_);
    while (!stop_) {
        cv_.wait_for(lock, std::chrono::milliseconds(10), [&] { return stop_ || woken_; });
        if (stop_) break;
        woken_ = false;
        ++tick_;
        // What every engine is about to play: the next seconds after its playhead, then the first blocks of every clip.
        std::vector<std::shared_ptr<StreamPlan>> plans;
        for (auto &w : plans_) if (auto p = w.lock()) plans.push_back(std::move(p));
        std::vector<std::shared_ptr<const Media>> keep; // sources stay alive while we load for them
        std::vector<Want> wants;
        for (auto &plan : plans) {
            std::lock_guard planLock(plan->mu);
            const int64_t pos = plan->position ? plan->position->load(std::memory_order_relaxed) : 0;
            for (const auto &seg : plan->segments) {
                StreamSource *s = seg.media ? seg.media->source() : nullptr;
                if (!s) continue;
                keep.push_back(seg.media);
                const int64_t window = static_cast<int64_t>(6 * s->rate_) + plan->lookahead;
                const int64_t a = std::max(pos, seg.start), e = std::min(pos + window, seg.start + seg.length);
                if (a < e) {
                    const int64_t from = seg.offset + (a - seg.start), to = seg.offset + (e - seg.start);
                    for (int64_t i = from / kStreamBlockFrames; i <= (to - 1) / kStreamBlockFrames && i < s->blocks_; ++i)
                        wants.push_back({s, i, std::max<int64_t>(0, i * kStreamBlockFrames - from) + (a - pos)});
                }
                const int64_t head = seg.offset / kStreamBlockFrames, distance = std::llabs(seg.start - pos);
                for (int64_t i = head; i <= head + 1 && i < s->blocks_; ++i) wants.push_back({s, i, window + distance});
            }
        }
        std::sort(wants.begin(), wants.end(), [](const Want &x, const Want &y) { return x.priority < y.priority; });
        // Keep the most urgent ones that fit: mark them wanted now (never evicted this round), then load what's missing.
        size_t room = budgetBlocks_, kept = 0;
        std::vector<Want> missing;
        for (const auto &w : wants) {
            if (kept >= room) break;
            auto *b = w.source->table_[w.index].load(std::memory_order_relaxed);
            if (b && b->lastWanted == tick_) continue; // duplicate
            ++kept;
            if (b) b->lastWanted = tick_;
            else if (std::none_of(missing.begin(), missing.end(), [&](const Want &m) { return m.source == w.source && m.index == w.index; }))
                missing.push_back(w);
        }
        for (const auto &w : missing)
            if (!w.source->table_[w.index].load(std::memory_order_relaxed) && !load(w.source, w.index, tick_, 0)) break;
        // Over budget (it shrank, or an offline lease borrowed blocks): give memory back, least recently wanted first.
        while (allocated_ > budgetBlocks_) {
            if (!free_.empty()) { delete free_.back(); free_.pop_back(); --allocated_; continue; }
            StreamSource::Block *victim = nullptr;
            for (auto *b : resident_)
                if (b->pins == 0 && (!victim || b->lastWanted < victim->lastWanted)) victim = b;
            if (!victim) break;
            release(victim);
            ++evicted_;
            delete victim;
            --allocated_;
        }
        lock.unlock();
        keep.clear();
        lock.lock();
    }
}

StreamCache::Lease::~Lease() { clear(); }

void StreamCache::Lease::need(const std::shared_ptr<const Media> &media, int64_t from, int64_t n) {
    StreamSource *s = media ? media->source() : nullptr;
    if (!s || n <= 0) return;
    StreamCache &cache = shared();
    std::lock_guard lock(cache.mu_);
    const int64_t first = std::max<int64_t>(0, from / kStreamBlockFrames);
    const int64_t last = std::min(s->blocks_ - 1, (from + n - 1) / kStreamBlockFrames);
    for (int64_t i = first; i <= last; ++i) {
        if (std::any_of(pinned_.begin(), pinned_.end(), [&](const auto &p) { return p.first.get() == media.get() && p.second == i; })) continue;
        if (auto *b = s->table_[i].load(std::memory_order_relaxed)) ++b->pins;
        else cache.load(s, i, cache.tick_, 1);
        pinned_.push_back({media, i});
    }
}

void StreamCache::Lease::clear() {
    if (pinned_.empty()) return;
    StreamCache &cache = shared();
    std::lock_guard lock(cache.mu_);
    for (const auto &[media, i] : pinned_)
        if (auto *b = media->source()->table_[i].load(std::memory_order_relaxed); b && b->pins > 0) --b->pins;
    pinned_.clear();
}

StreamStats StreamCache::stats() {
    std::lock_guard lock(mu_);
    StreamStats s;
    s.residentBlocks = static_cast<uint32_t>(resident_.size());
    s.residentBytes = allocated_ * sizeof(StreamSource::Block);
    s.budgetBytes = budgetBlocks_ * sizeof(StreamSource::Block);
    s.blocksLoaded = loaded_;
    s.blocksEvicted = evicted_;
    s.missedFrames = missed_.load(std::memory_order_relaxed);
    return s;
}

} // namespace dalnok
