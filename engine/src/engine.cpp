// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"

#include <algorithm>
#include <cmath>
#include <ctime>

namespace atrium {

namespace {
constexpr double kTransportFadeSeconds = 0.005; // de-click ramp for play/pause/seek

// clock_gettime_nsec_np reads the commpage (no syscall, no locks) but is not
// annotated by the SDK, so the effect check is suppressed for this call only.
uint64_t nowNs() ATRIUM_NONBLOCKING {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#pragma clang diagnostic pop
}

void atomicMax(std::atomic<uint64_t> &a, uint64_t v) ATRIUM_NONBLOCKING {
    auto cur = a.load(std::memory_order_relaxed);
    while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {}
}
} // namespace

Engine::Engine(double sampleRate) : sampleRate_(sampleRate) {
    if (sampleRate_ <= 0) sampleRate_ = defaultOutputSampleRate();
    if (sampleRate_ <= 0) sampleRate_ = 48000.0;
    commit();
}

Engine::~Engine() {
    stopDevice();
    collectGarbage();
    delete current_;
    delete pending_.exchange(nullptr);
}

// ---- Device -------------------------------------------------------------

bool Engine::startDevice(std::string &err) {
    if (device_) return true;
    auto dev = createDefaultOutputDevice(sampleRate_);
    if (!dev->start(&Engine::audioCallback, this, err)) return false;
    device_ = std::move(dev);
    return true;
}

void Engine::stopDevice() {
    if (!device_) return;
    device_->stop(); // synchronous: the audio thread is no longer inside process()
    device_.reset();
}

void Engine::collectGarbage() {
    RenderState *s = nullptr;
    while (retired_.pop(s)) delete s;
}

// ---- Session model ------------------------------------------------------

AtriumTrackId Engine::addTrack(const std::string &name) {
    const auto id = nextTrack_++;
    tracks_[id].name = name;
    commit();
    return id;
}

bool Engine::removeTrack(AtriumTrackId id) {
    if (!tracks_.erase(id)) return false;
    std::erase_if(clips_, [id](const auto &kv) { return kv.second.track == id; });
    commit();
    return true;
}

bool Engine::setGainDb(AtriumTrackId id, float db) {
    auto it = tracks_.find(id);
    if (it == tracks_.end()) return false;
    db = std::min(db, 12.0f);
    const float lin = db <= -96.0f ? 0.0f : std::pow(10.0f, db / 20.0f);
    it->second.runtime->gain.store(lin, std::memory_order_relaxed);
    return true;
}

bool Engine::setPan(AtriumTrackId id, float pan) {
    auto it = tracks_.find(id);
    if (it == tracks_.end() || std::isnan(pan)) return false;
    it->second.runtime->pan.store(std::clamp(pan, -1.0f, 1.0f), std::memory_order_relaxed);
    return true;
}

bool Engine::setMute(AtriumTrackId id, bool muted) {
    auto it = tracks_.find(id);
    if (it == tracks_.end()) return false;
    it->second.runtime->muted.store(muted, std::memory_order_relaxed);
    return true;
}

AtriumClipId Engine::addClip(AtriumTrackId track, std::shared_ptr<const Media> media, int64_t start, int64_t offset,
                             int64_t length) {
    if (!tracks_.count(track) || !media || start < 0 || offset < 0 || offset >= media->frames()) return 0;
    const int64_t avail = media->frames() - offset;
    length = length <= 0 ? avail : std::min(length, avail);
    const auto id = nextClip_++;
    clips_[id] = Clip{track, std::move(media), start, offset, length};
    commit();
    return id;
}

bool Engine::removeClip(AtriumClipId id) {
    if (!clips_.erase(id)) return false;
    commit();
    return true;
}

int64_t Engine::sessionLength() const {
    int64_t end = 0;
    for (const auto &[_, c] : clips_) end = std::max(end, c.start + c.length);
    return end;
}

std::unique_ptr<RenderState> Engine::compile() const {
    auto s = std::make_unique<RenderState>();
    for (const auto &[id, t] : tracks_) {
        RenderTrack rt;
        rt.runtime = t.runtime;
        for (const auto &[_, c] : clips_) {
            if (c.track != id) continue;
            rt.clips.push_back({c.media, c.start, c.offset, c.length});
            if (c.media->channelCount() > 1) rt.monoSource = false;
        }
        std::sort(rt.clips.begin(), rt.clips.end(), [](auto &a, auto &b) { return a.start < b.start; });
        s->tracks.push_back(std::move(rt));
    }
    return s;
}

void Engine::commit() {
    // A snapshot replaced here was never observed by the audio thread, so it
    // is safe to delete immediately.
    delete pending_.exchange(compile().release(), std::memory_order_acq_rel);
    collectGarbage();
}

// ---- Audio thread -------------------------------------------------------

void Engine::audioCallback(void *ctx, float *left, float *right, int frames) ATRIUM_NONBLOCKING {
    auto *self = static_cast<Engine *>(ctx);
    const uint64_t t0 = nowNs();
    self->process(left, right, frames);
    const uint64_t dt = nowNs() - t0;

    self->callbacks_.fetch_add(1, std::memory_order_relaxed);
    self->framesRendered_.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed);
    self->lastCallbackNs_.store(dt, std::memory_order_relaxed);
    atomicMax(self->maxCallbackNs_, dt);
    if (static_cast<uint32_t>(frames) > self->maxFrames_.load(std::memory_order_relaxed))
        self->maxFrames_.store(static_cast<uint32_t>(frames), std::memory_order_relaxed);
    if (static_cast<double>(dt) > static_cast<double>(frames) / self->sampleRate_ * 1e9)
        self->overloads_.fetch_add(1, std::memory_order_relaxed);
}

void Engine::process(float *left, float *right, int frames) ATRIUM_NONBLOCKING {
    // Adopt the newest snapshot only if the previous one can be retired.
    if (!retired_.full()) {
        if (RenderState *s = pending_.exchange(nullptr, std::memory_order_acq_rel)) {
            if (current_) retired_.push(current_);
            current_ = s;
            swaps_.fetch_add(1, std::memory_order_relaxed);
        }
    }
    const int64_t seek = seekRequest_.exchange(-1, std::memory_order_relaxed);
    if (seek >= 0) pendingSeek_ = seek;
    const bool play = playing_.load(std::memory_order_relaxed);
    const float step = static_cast<float>(1.0 / (kTransportFadeSeconds * sampleRate_));

    for (int off = 0; off < frames;) {
        const int n = std::min(kMaxBlock, frames - off);
        float *l = left + off, *r = right + off;
        off += n;

        if (pendingSeek_ >= 0 && transportGain_ == 0.0f) {
            rtPosition_ = pendingSeek_;
            pendingSeek_ = -1;
        }
        const float target = (play && pendingSeek_ < 0) ? 1.0f : 0.0f;

        if (transportGain_ == 0.0f && target == 0.0f) {
            for (int i = 0; i < n; ++i) l[i] = r[i] = 0.0f;
            continue;
        }
        if (current_) {
            renderBlock(*current_, rtPosition_, n, l, r, scratch_, true);
        } else {
            for (int i = 0; i < n; ++i) l[i] = r[i] = 0.0f;
        }
        float g = transportGain_;
        if (g != target) {
            for (int i = 0; i < n; ++i) {
                g = target > g ? std::min(target, g + step) : std::max(target, g - step);
                l[i] *= g;
                r[i] *= g;
            }
            transportGain_ = g;
        }
        rtPosition_ += n;
    }
    position_.store(pendingSeek_ >= 0 ? pendingSeek_ : rtPosition_, std::memory_order_relaxed);
}

// ---- Offline ------------------------------------------------------------

bool Engine::renderOffline(int64_t start, int64_t frames, float *left, float *right) {
    if (start < 0 || frames < 0 || !left || !right) return false;
    const auto state = compile();
    Scratch scratch{};
    for (int64_t done = 0; done < frames;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, frames - done));
        renderBlock(*state, start + done, n, left + done, right + done, scratch, false);
        done += n;
    }
    return true;
}

bool Engine::renderToWav(const std::string &path, int64_t start, int64_t frames, int32_t bits, std::string &err) {
    if (start < 0 || frames <= 0) {
        err = "invalid range";
        return false;
    }
    std::unique_ptr<WavWriter> w(openWavWriter(path, sampleRate_, bits, err));
    if (!w) return false;
    const auto state = compile();
    Scratch scratch{};
    std::vector<float> l(kMaxBlock * 64), r(kMaxBlock * 64);
    for (int64_t done = 0; done < frames;) {
        const auto chunk = std::min<int64_t>(static_cast<int64_t>(l.size()), frames - done);
        for (int64_t o = 0; o < chunk;) {
            const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, chunk - o));
            renderBlock(*state, start + done + o, n, l.data() + o, r.data() + o, scratch, false);
            o += n;
        }
        if (!w->write(l.data(), r.data(), chunk, err)) return false;
        done += chunk;
    }
    return w->close(err);
}

// ---- Diagnostics --------------------------------------------------------

void Engine::stats(AtriumStats &o) const {
    o.callbacks = callbacks_.load(std::memory_order_relaxed);
    o.frames_rendered = framesRendered_.load(std::memory_order_relaxed);
    o.max_callback_ns = maxCallbackNs_.load(std::memory_order_relaxed);
    o.last_callback_ns = lastCallbackNs_.load(std::memory_order_relaxed);
    o.max_frames_per_callback = maxFrames_.load(std::memory_order_relaxed);
    o.overloads = overloads_.load(std::memory_order_relaxed);
    o.snapshot_swaps = swaps_.load(std::memory_order_relaxed);
}

void Engine::resetStats() {
    callbacks_ = 0;
    framesRendered_ = 0;
    maxCallbackNs_ = 0;
    lastCallbackNs_ = 0;
    maxFrames_ = 0;
    overloads_ = 0;
    swaps_ = 0;
}

} // namespace atrium
