// Engine: clip edits, copy and the clipboard (split from engine.cpp, A-06).
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

bool Engine::setClipFades(DalnokClipId id, int64_t fadeIn, int64_t fadeOut, int32_t curve, std::string &err) {
    return edit("Fade", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        if (c->midi()) return fail(err, "not available for MIDI clips");
        if (fadeIn < 0 || fadeOut < 0) return fail(err, "fades must be >= 0");
        if (curve != kFadeLinear && curve != kFadeEqualPower) return fail(err, "unknown fade curve");
        c->fadeIn = fadeIn;
        c->fadeOut = fadeOut;
        c->fadeCurve = curve;
        return true;
    });
}

bool Engine::setClipStretch(DalnokClipId id, int64_t length, double rate, float pitch, bool preservePitch,
                            std::string &err) {
    return edit("Time Stretch", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        if (c->midi()) return fail(err, "not available for MIDI clips");
        if (!(rate >= 0.05 && rate <= 20) || !(pitch >= -48 && pitch <= 48) || length <= 0)
            return fail(err, "rate must be 0.05–20, pitch −48…48 semitones, length > 0");
        const PoolEntry *pe = poolEntry(c->media);
        const auto span = static_cast<int64_t>(std::llround(static_cast<double>(length) * rate));
        if (!pe || c->offset + span > pe->frames + 1) return fail(err, "stretch reads past the end of the source");
        c->length = length;
        c->rate = rate;
        c->pitch = preservePitch ? pitch : 0;
        c->preservePitch = preservePitch;
        return true;
    });
}

bool Engine::setClipMuted(DalnokClipId id, bool muted, std::string &err) {
    return edit(muted ? "Mute Clip" : "Unmute Clip", true, [&](Model &m) {
        ClipState *clip = m.clip(id);
        if (!clip) return fail(err, "no such clip");
        if (clip->muted == muted) return fail(err, "clip is already in that mute state");
        clip->muted = muted;
        return true;
    });
}

bool Engine::setClipGain(DalnokClipId id, float gainDb, std::string &err) {
    return edit("Clip Gain", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        if (c->midi()) return fail(err, "not available for MIDI clips");
        if (std::isnan(gainDb)) return fail(err, "gain is NaN");
        c->gainDb = gainDb <= -96.0f ? -INFINITY : std::min(gainDb, 24.0f);
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
    cache_.clear();
    bumpRevisionAll();
    commit();
    return true;
}

DalnokClipId Engine::addClip(DalnokTrackId track, DalnokMediaId media, int64_t start, int64_t offset, int64_t length,
                             std::string &err) {
    const PoolEntry *pe = poolEntry(media);
    const auto id = nextClip_;
    const bool ok = edit("Add Clip", true, [&](Model &m) {
        if (!m.track(track)) return fail(err, "no such track");
        if (m.track(track)->kind != kTrackAudio) return fail(err, "audio clips go on audio tracks");
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
        if (m.track(track)->kind == kTrackBus) return fail(err, "buses don't hold clips");
        if ((m.track(track)->kind == kTrackInstrument) != it->midi())
            return fail(err, it->midi() ? "MIDI clips go on instrument tracks" : "audio clips go on audio tracks");
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
        const int64_t frames = c->midi() ? INT64_MAX / 2 : (pe ? pe->frames : 0); // MIDI clips can extend freely
        const auto span = static_cast<int64_t>(std::llround(static_cast<double>(length) * c->rate));
        if (start < 0 || offset < 0 || length <= 0 || offset + span > frames)
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
        right.offset += static_cast<int64_t>(std::llround(static_cast<double>(leftLen) * it->rate));
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

std::vector<DalnokClipId> Engine::copyClips(const std::vector<DalnokClipId> &ids, int64_t start, int32_t trackShift, std::string &err) {
    if (ids.empty()) { fail(err, "no clips selected"); return {}; }
    if (start < 0) { fail(err, "start must be >= 0"); return {}; }
    std::set<DalnokClipId> unique;
    int64_t earliest = INT64_MAX;
    for (auto id : ids) {
        const ClipState *c = model_.clip(id);
        if (!c) { fail(err, "no such clip"); return {}; }
        if (c->slot >= 0 || c->alt) { fail(err, "only arrangement clips can be copied"); return {}; }
        if (!unique.insert(id).second) { fail(err, "duplicate clip id"); return {}; }
        earliest = std::min(earliest, c->start);
    }
    std::vector<DalnokClipId> out;
    const auto first = nextClip_;
    const bool ok = edit(ids.size() == 1 ? "Paste Clip" : "Paste Clips", true, [&](Model &m) {
        std::vector<DalnokTrackId> order;
        for (const auto &t : m.tracks) order.push_back(t.id);
        DalnokClipId next = first;
        for (auto id : ids) {
            ClipState c = *m.clip(id);
            const auto at = std::find(order.begin(), order.end(), c.track);
            const auto idx = static_cast<int64_t>(at - order.begin()) + trackShift;
            if (at == order.end() || idx < 0 || idx >= static_cast<int64_t>(order.size())) return fail(err, "there is no track there to paste onto");
            const TrackState *t = m.track(order[static_cast<size_t>(idx)]);
            if (t->kind == kTrackBus) return fail(err, "buses don't hold clips");
            if ((t->kind == kTrackInstrument) != c.midi())
                return fail(err, c.midi() ? "MIDI clips go on instrument tracks" : "audio clips go on audio tracks");
            const int64_t rel = c.start - earliest;
            if (rel > INT64_MAX - start - c.length) return fail(err, "paste exceeds the supported timeline");
            c.id = next++;
            c.track = t->id;
            c.start = start + rel;
            c.folder = 0;
            m.clips.push_back(std::move(c)); // copies come to the top
        }
        return true;
    });
    if (!ok) return {};
    nextClip_ = first + static_cast<DalnokClipId>(ids.size());
    out.clear();
    for (size_t i = 0; i < ids.size(); ++i) out.push_back(first + static_cast<DalnokClipId>(i));
    return out;
}

bool Engine::copyToClipboard(const std::vector<DalnokClipId> &ids, std::string &err) {
    if (ids.empty()) return fail(err, "no clips selected");
    std::vector<DalnokTrackId> order;
    for (const auto &t : model_.tracks) order.push_back(t.id);
    std::vector<ClipboardEntry> out;
    std::set<DalnokClipId> unique;
    int32_t top = INT32_MAX;
    int64_t earliest = INT64_MAX;
    for (auto id : ids) {
        const ClipState *c = model_.clip(id);
        if (!c) return fail(err, "no such clip");
        if (c->slot >= 0 || c->alt) return fail(err, "only arrangement clips can be copied");
        if (!unique.insert(id).second) return fail(err, "duplicate clip id");
        const auto row = static_cast<int32_t>(std::find(order.begin(), order.end(), c->track) - order.begin());
        out.push_back({*c, row});
        top = std::min(top, row);
        earliest = std::min(earliest, c->start);
    }
    for (auto &e : out) { e.row -= top; e.clip.start -= earliest; e.clip.folder = 0; }
    clipboard_ = std::move(out);
    return true;
}

std::vector<DalnokClipId> Engine::pasteClipboard(DalnokTrackId track, int64_t start, std::string &err) {
    if (clipboard_.empty()) { fail(err, "nothing to paste"); return {}; }
    if (start < 0) { fail(err, "start must be >= 0"); return {}; }
    const auto first = nextClip_;
    const bool ok = edit(clipboard_.size() == 1 ? "Paste Clip" : "Paste Clips", true, [&](Model &m) {
        std::vector<DalnokTrackId> order;
        for (const auto &t : m.tracks) order.push_back(t.id);
        const auto base = std::find(order.begin(), order.end(), track);
        if (base == order.end()) return fail(err, "no such track");
        DalnokClipId next = first;
        for (const auto &e : clipboard_) {
            const auto idx = static_cast<size_t>(base - order.begin()) + static_cast<size_t>(e.row);
            if (idx >= order.size()) return fail(err, "there is no track there to paste onto");
            const TrackState *t = m.track(order[idx]);
            if (t->kind == kTrackBus) return fail(err, "buses don't hold clips");
            if ((t->kind == kTrackInstrument) != e.clip.midi())
                return fail(err, e.clip.midi() ? "MIDI clips go on instrument tracks" : "audio clips go on audio tracks");
            if (e.clip.start > INT64_MAX - start - e.clip.length) return fail(err, "paste exceeds the supported timeline");
            ClipState c = e.clip;
            c.id = next++;
            c.track = t->id;
            c.start += start;
            m.clips.push_back(std::move(c));
        }
        return true;
    });
    if (!ok) return {};
    nextClip_ = first + static_cast<DalnokClipId>(clipboard_.size());
    std::vector<DalnokClipId> out;
    for (size_t i = 0; i < clipboard_.size(); ++i) out.push_back(first + static_cast<DalnokClipId>(i));
    return out;
}

// ---- Offline ------------------------------------------------------------

} // namespace dalnok
