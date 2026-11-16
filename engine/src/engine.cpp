// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"

#include <algorithm>
#include <cmath>
#include <ctime>

namespace dalnok {

namespace {
constexpr double kTransportFadeSeconds = 0.005; // de-click ramp for play/pause/seek

// clock_gettime_nsec_np reads the commpage (no syscall, no locks) but is not
// annotated by the SDK, so the effect check is suppressed for this call only.
uint64_t nowNs() DALNOK_NONBLOCKING {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#pragma clang diagnostic pop
}

void atomicMax(std::atomic<uint64_t> &a, uint64_t v) DALNOK_NONBLOCKING {
    auto cur = a.load(std::memory_order_relaxed);
    while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {}
}
} // namespace

float dbToGain(float db) { return db <= -96.0f ? 0.0f : std::pow(10.0f, std::min(db, 12.0f) / 20.0f); }

// ---- Model lookups --------------------------------------------------------

TrackState *Model::track(DalnokTrackId id) {
    for (auto &t : tracks) if (t.id == id) return &t;
    return nullptr;
}
const TrackState *Model::track(DalnokTrackId id) const { return const_cast<Model *>(this)->track(id); }
ClipState *Model::clip(DalnokClipId id) {
    for (auto &c : clips) if (c.id == id) return &c;
    return nullptr;
}
const ClipState *Model::clip(DalnokClipId id) const { return const_cast<Model *>(this)->clip(id); }

// ---- Lifecycle ------------------------------------------------------------

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
    auto dev = createOutputDevice(outputUid_, sampleRate_, err);
    if (!dev || !dev->start(&Engine::audioCallback, this, err)) return false;
    device_ = std::move(dev);
    return true;
}

bool Engine::setOutputDevice(const std::string &uid, std::string &err) {
    if (uid == outputUid_ && device_ && device_->alive()) return true;
    const std::string previous = outputUid_;
    const bool wasRunning = device_ != nullptr;
    stopDevice();
    outputUid_ = uid;
    if (startDevice(err)) return true;
    // Fall back to what was running before (or the default if that is gone).
    outputUid_ = previous;
    std::string ignored;
    if (wasRunning && !startDevice(ignored)) {
        outputUid_.clear();
        startDevice(ignored);
    }
    return false;
}

bool Engine::pump(float *left, float *right, int frames) {
    if (device_ || !left || !right || frames <= 0) return false;
    process(left, right, frames);
    collectGarbage();
    return true;
}

bool Engine::readTrackMeter(DalnokTrackId id, float &l, float &r) {
    const TrackState *t = model_.track(id);
    if (!t) return false;
    l = t->runtime->peakL.exchange(0.0f, std::memory_order_relaxed);
    r = t->runtime->peakR.exchange(0.0f, std::memory_order_relaxed);
    return true;
}

void Engine::readMasterMeter(float &l, float &r) {
    l = masterPeakL_.exchange(0.0f, std::memory_order_relaxed);
    r = masterPeakR_.exchange(0.0f, std::memory_order_relaxed);
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

// ---- Media pool -----------------------------------------------------------

DalnokMediaId Engine::poolAdd(std::shared_ptr<const Media> media, const std::string &path) {
    if (!media) return 0;
    if (!path.empty())
        for (const auto &[id, e] : pool_)
            if (e.path == path && e.handle->impl) return id;
    const auto id = nextMedia_++;
    PoolEntry &e = pool_[id];
    e.path = path;
    e.frames = media->frames();
    e.channels = media->channelCount();
    e.handle = std::make_unique<DalnokMedia>(DalnokMedia{std::move(media)});
    return id;
}

const PoolEntry *Engine::poolEntry(DalnokMediaId id) const {
    auto it = pool_.find(id);
    return it == pool_.end() ? nullptr : &it->second;
}

int64_t Engine::sessionLength() const {
    int64_t end = 0;
    for (const auto &c : model_.clips) end = std::max(end, c.start + c.length);
    return end;
}

// ---- Edit machinery -------------------------------------------------------

namespace {
constexpr size_t kMaxUndo = 500;
}

template <typename F>
bool Engine::edit(const char *name, bool structural, F &&fn) {
    Model before = model_;
    if (!fn(model_)) {
        model_ = std::move(before);
        return false;
    }
    if (groupDepth_ == 0) {
        undo_.push_back({name, std::move(before)});
    } else if (!groupRecorded_) {
        undo_.push_back({groupName_.empty() ? name : groupName_, std::move(before)});
        groupRecorded_ = true;
    }
    if (undo_.size() > kMaxUndo) undo_.erase(undo_.begin());
    redo_.clear();
    ++revision_;
    syncRuntimes();
    if (structural) commit();
    return true;
}

void Engine::syncRuntimes() {
    int32_t solos = 0;
    for (const auto &t : model_.tracks) {
        t.runtime->gain.store(dbToGain(t.gainDb), std::memory_order_relaxed);
        t.runtime->pan.store(t.pan, std::memory_order_relaxed);
        t.runtime->muted.store(t.muted, std::memory_order_relaxed);
        t.runtime->solo.store(t.solo, std::memory_order_relaxed);
        solos += t.solo;
    }
    soloCount_.store(solos, std::memory_order_relaxed);
}

void Engine::restore(Model m) {
    model_ = std::move(m);
    syncRuntimes();
    ++revision_;
    commit();
}

bool Engine::undo() {
    groupDepth_ = 0;
    if (undo_.empty()) return false;
    UndoStep step = std::move(undo_.back());
    undo_.pop_back();
    redo_.push_back({step.name, model_});
    restore(std::move(step.model));
    return true;
}

bool Engine::redo() {
    groupDepth_ = 0;
    if (redo_.empty()) return false;
    UndoStep step = std::move(redo_.back());
    redo_.pop_back();
    undo_.push_back({step.name, model_});
    restore(std::move(step.model));
    return true;
}

void Engine::beginGroup(const std::string &name) {
    if (groupDepth_++ == 0) {
        groupName_ = name;
        groupRecorded_ = false;
    }
}

void Engine::endGroup() {
    if (groupDepth_ > 0) --groupDepth_;
}

void Engine::resetModel() {
    model_ = Model{};
    pool_.clear();
    undo_.clear();
    redo_.clear();
    groupDepth_ = 0;
    nextColor_ = 0;
    ++revision_;
    savedRevision_ = revision_;
}

void Engine::newProject() {
    resetModel();
    commit();
}

// ---- Commands -------------------------------------------------------------

namespace {
bool fail(std::string &err, const char *msg) {
    err = msg;
    return false;
}
std::string stem(const std::string &path) {
    const auto slash = path.find_last_of('/');
    std::string base = slash == std::string::npos ? path : path.substr(slash + 1);
    const auto dot = base.find_last_of('.');
    return dot == std::string::npos || dot == 0 ? base : base.substr(0, dot);
}
} // namespace

DalnokTrackId Engine::addTrack(const std::string &name, std::string &err) {
    const auto id = nextTrack_;
    const bool ok = edit("New Track", true, [&](Model &m) {
        TrackState t;
        t.id = id;
        t.name = name.empty() ? "Track " + std::to_string(m.tracks.size() + 1) : name;
        t.color = nextColor_;
        t.runtime = std::make_shared<TrackRuntime>();
        m.tracks.push_back(std::move(t));
        return true;
    });
    if (!ok) return fail(err, "could not add track"), 0;
    ++nextTrack_;
    ++nextColor_;
    return id;
}

bool Engine::removeTrack(DalnokTrackId id, std::string &err) {
    return edit("Delete Track", true, [&](Model &m) {
        if (!m.track(id)) return fail(err, "no such track");
        std::erase_if(m.tracks, [id](const TrackState &t) { return t.id == id; });
        std::erase_if(m.clips, [id](const ClipState &c) { return c.track == id; });
        return true;
    });
}

bool Engine::renameTrack(DalnokTrackId id, const std::string &name, std::string &err) {
    return edit("Rename Track", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        if (name.empty()) return fail(err, "name must not be empty");
        t->name = name;
        return true;
    });
}

bool Engine::setGainDb(DalnokTrackId id, float db, std::string &err) {
    return edit("Volume", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        if (std::isnan(db)) return fail(err, "gain is NaN");
        t->gainDb = db <= -96.0f ? -INFINITY : std::min(db, 12.0f);
        t->runtime->gain.store(dbToGain(t->gainDb), std::memory_order_relaxed);
        return true;
    });
}

bool Engine::setPan(DalnokTrackId id, float pan, std::string &err) {
    return edit("Pan", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        if (std::isnan(pan)) return fail(err, "pan is NaN");
        t->pan = std::clamp(pan, -1.0f, 1.0f);
        t->runtime->pan.store(t->pan, std::memory_order_relaxed);
        return true;
    });
}

bool Engine::setMute(DalnokTrackId id, bool muted, std::string &err) {
    return edit(muted ? "Mute" : "Unmute", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        t->muted = muted;
        t->runtime->muted.store(muted, std::memory_order_relaxed);
        return true;
    });
}

bool Engine::setSolo(DalnokTrackId id, bool solo, std::string &err) {
    return edit(solo ? "Solo" : "Unsolo", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        t->solo = solo;
        return true;
    });
}

bool Engine::moveTrack(DalnokTrackId id, int32_t index, std::string &err) {
    return edit("Move Track", true, [&](Model &m) {
        auto it = std::find_if(m.tracks.begin(), m.tracks.end(), [id](const TrackState &t) { return t.id == id; });
        if (it == m.tracks.end()) return fail(err, "no such track");
        if (index < 0 || index >= static_cast<int32_t>(m.tracks.size())) return fail(err, "index out of range");
        TrackState t = std::move(*it);
        m.tracks.erase(it);
        m.tracks.insert(m.tracks.begin() + index, std::move(t));
        return true;
    });
}

bool Engine::setClipFades(DalnokClipId id, int64_t fadeIn, int64_t fadeOut, int32_t curve, std::string &err) {
    return edit("Fade", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        if (fadeIn < 0 || fadeOut < 0) return fail(err, "fades must be >= 0");
        if (curve != kFadeLinear && curve != kFadeEqualPower) return fail(err, "unknown fade curve");
        c->fadeIn = fadeIn;
        c->fadeOut = fadeOut;
        c->fadeCurve = curve;
        return true;
    });
}

bool Engine::poolRelink(DalnokMediaId id, std::shared_ptr<const Media> media, const std::string &path,
                        std::string &err) {
    auto it = pool_.find(id);
    if (it == pool_.end()) return fail(err, "no such media");
    if (!media) return fail(err, "no media");
    it->second.path = path;
    it->second.frames = media->frames();
    it->second.channels = media->channelCount();
    it->second.handle = std::make_unique<DalnokMedia>(DalnokMedia{std::move(media)});
    ++revision_;
    commit();
    return true;
}

DalnokClipId Engine::addClip(DalnokTrackId track, DalnokMediaId media, int64_t start, int64_t offset, int64_t length,
                             std::string &err) {
    const PoolEntry *pe = poolEntry(media);
    const auto id = nextClip_;
    const bool ok = edit("Add Clip", true, [&](Model &m) {
        if (!m.track(track)) return fail(err, "no such track");
        if (!pe) return fail(err, "no such media");
        if (start < 0 || offset < 0 || offset >= pe->frames) return fail(err, "start/offset out of range");
        const int64_t avail = pe->frames - offset;
        ClipState c;
        c.id = id;
        c.track = track;
        c.media = media;
        c.start = start;
        c.offset = offset;
        c.length = length <= 0 ? avail : std::min(length, avail);
        c.name = pe->path.empty() ? "Audio" : stem(pe->path);
        m.clips.push_back(std::move(c));
        return true;
    });
    if (!ok) return 0;
    ++nextClip_;
    return id;
}

bool Engine::removeClip(DalnokClipId id, std::string &err) {
    return edit("Delete Clip", true, [&](Model &m) {
        if (!m.clip(id)) return fail(err, "no such clip");
        std::erase_if(m.clips, [id](const ClipState &c) { return c.id == id; });
        return true;
    });
}

bool Engine::moveClip(DalnokClipId id, DalnokTrackId track, int64_t start, std::string &err) {
    return edit("Move Clip", true, [&](Model &m) {
        auto it = std::find_if(m.clips.begin(), m.clips.end(), [id](const ClipState &c) { return c.id == id; });
        if (it == m.clips.end()) return fail(err, "no such clip");
        if (!m.track(track)) return fail(err, "no such track");
        if (start < 0) return fail(err, "start must be >= 0");
        ClipState c = *it;
        c.track = track;
        c.start = start;
        m.clips.erase(it);
        m.clips.push_back(std::move(c)); // moved clips come to the top
        return true;
    });
}

bool Engine::setClipRegion(DalnokClipId id, int64_t start, int64_t offset, int64_t length, std::string &err) {
    return edit("Trim Clip", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        const PoolEntry *pe = poolEntry(c->media);
        const int64_t frames = pe ? pe->frames : 0;
        if (start < 0 || offset < 0 || length <= 0 || offset + length > frames)
            return fail(err, "region out of range");
        c->start = start;
        c->offset = offset;
        c->length = length;
        return true;
    });
}

DalnokClipId Engine::splitClip(DalnokClipId id, int64_t at, std::string &err) {
    const auto rightId = nextClip_;
    const bool ok = edit("Split Clip", true, [&](Model &m) {
        auto it = std::find_if(m.clips.begin(), m.clips.end(), [id](const ClipState &c) { return c.id == id; });
        if (it == m.clips.end()) return fail(err, "no such clip");
        if (at <= it->start || at >= it->start + it->length) return fail(err, "split point not inside clip");
        ClipState right = *it;
        const int64_t leftLen = at - it->start;
        it->length = leftLen;
        right.id = rightId;
        right.start = at;
        right.offset += leftLen;
        right.length -= leftLen;
        right.fadeIn = 0;      // the right part keeps the original fade-out
        it->fadeOut = 0;       // the left part keeps the original fade-in
        m.clips.insert(it + 1, std::move(right)); // same z-level as the original
        return true;
    });
    if (!ok) return 0;
    ++nextClip_;
    return rightId;
}

// ---- Snapshot compilation -------------------------------------------------

std::unique_ptr<RenderState> Engine::compile() const {
    auto s = std::make_unique<RenderState>();
    for (const auto &t : model_.tracks) {
        RenderTrack rt;
        rt.runtime = t.runtime;
        for (const auto &c : model_.clips) {
            if (c.track != t.id) continue;
            const PoolEntry *pe = poolEntry(c.media);
            if (!pe || !pe->handle->impl) continue; // offline media renders silence
            const auto &media = pe->handle->impl;
            // Defensive clamp: never read past the decoded media.
            const int64_t len = std::min(c.length, media->frames() - c.offset);
            if (len <= 0) continue;
            // Fades longer than the clip are scaled down proportionally.
            int64_t fi = std::min(c.fadeIn, len), fo = std::min(c.fadeOut, len);
            if (fi + fo > len) {
                const double k = static_cast<double>(len) / static_cast<double>(fi + fo);
                fi = static_cast<int64_t>(static_cast<double>(fi) * k);
                fo = len - fi;
            }
            rt.clips.push_back({media, c.start, c.offset, len, fi, fo, c.fadeCurve});
            if (media->channelCount() > 1) rt.monoSource = false;
        }
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

void Engine::audioCallback(void *ctx, float *left, float *right, int frames) DALNOK_NONBLOCKING {
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

void Engine::process(float *left, float *right, int frames) DALNOK_NONBLOCKING {
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
            renderBlock(*current_, rtPosition_, n, l, r, scratch_, true, soloCount_.load(std::memory_order_relaxed) > 0);
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
        float pl = 0, pr = 0;
        for (int i = 0; i < n; ++i) {
            pl = std::max(pl, std::fabs(l[i]));
            pr = std::max(pr, std::fabs(r[i]));
        }
        raisePeak(masterPeakL_, pl);
        raisePeak(masterPeakR_, pr);
        rtPosition_ += n;
    }
    position_.store(pendingSeek_ >= 0 ? pendingSeek_ : rtPosition_, std::memory_order_relaxed);
}

// ---- Offline ------------------------------------------------------------

bool Engine::renderOffline(int64_t start, int64_t frames, float *left, float *right) {
    if (start < 0 || frames < 0 || !left || !right) return false;
    const auto state = compile();
    const bool anySolo = soloCount_.load() > 0;
    Scratch scratch{};
    for (int64_t done = 0; done < frames;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, frames - done));
        renderBlock(*state, start + done, n, left + done, right + done, scratch, false, anySolo);
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
            renderBlock(*state, start + done + o, n, l.data() + o, r.data() + o, scratch, false, soloCount_.load() > 0);
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

} // namespace dalnok
