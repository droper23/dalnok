// Engine: the clip launcher (split from engine.cpp, A-06).
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

DalnokClipId Engine::copyToSlot(DalnokClipId clip, int32_t slot, std::string &err) {
    const auto id = nextClip_;
    const bool ok = edit("Copy to Launcher", true, [&](Model &m) {
        const ClipState *c = m.clip(clip);
        if (!c || c->alt) return fail(err, "no such clip");
        if (slot < 0 || slot >= m.scenes) return fail(err, "no such launcher slot");
        std::erase_if(m.clips, [&](const ClipState &x) { return x.track == c->track && x.slot == slot; }); // replaces the slot
        c = m.clip(clip);
        if (!c) return fail(err, "that clip was in the slot");
        ClipState copy = *c;
        copy.id = id;
        copy.slot = slot;
        copy.folder = 0;
        copy.start = 0;
        m.clips.push_back(std::move(copy));
        return true;
    });
    if (!ok) return 0;
    ++nextClip_;
    return id;
}

DalnokClipId Engine::placeCopy(DalnokClipId clip, DalnokTrackId track, int64_t start, std::string &err) {
    const auto id = nextClip_;
    const bool ok = edit("Place Copy", true, [&](Model &m) {
        const ClipState *c = m.clip(clip);
        const TrackState *t = m.track(track);
        if (!c || !t) return fail(err, "no such clip or track");
        if (start < 0) return fail(err, "start must be >= 0");
        if (t->kind == kTrackBus || (t->kind == kTrackInstrument) != c->midi()) return fail(err, "that clip can't go on that track");
        ClipState copy = *c;
        copy.id = id;
        copy.track = track;
        copy.start = start;
        copy.slot = -1;
        copy.follow = 0;
        copy.folder = 0;
        copy.alt = false;
        m.clips.push_back(std::move(copy));
        return true;
    });
    if (!ok) return 0;
    ++nextClip_;
    return id;
}

namespace {
// Next bar start strictly after `frame` (or `frame` itself when it is a bar start).
int64_t nextBar(const Model &m, const TempoMap &map, int64_t frame) {
    double beat = 0;
    if (!map.frameToBeat(frame, beat)) return frame;
    int32_t bar, num, den; double inBar;
    beatToBar(m.meters, beat, bar, inBar, num, den);
    if (inBar < 1e-6) return frame;
    int64_t out = frame;
    map.beatToFrame(barToBeat(m.meters, bar + 1), out);
    return out;
}
} // namespace

DalnokClipId Engine::takeToSlot(const std::vector<DalnokClipId> &takes, int32_t slot, std::string &err) {
    const auto id = nextClip_;
    const bool ok = edit("Record to Slot", true, [&](Model &m) {
        const ClipState *c = takes.empty() ? nullptr : m.clip(takes.back());
        if (!c) return fail(err, "no take");
        if (slot < 0 || slot >= m.scenes) return fail(err, "no such launcher slot");
        ClipState copy = *c;
        // The whole bars the take covers: from the first bar line at or after its start to the last one before its end.
        const int64_t end = c->start + c->length;
        const int64_t a = nextBar(m, map_, c->start);
        double beat = 0;
        int64_t b = a;
        if (map_.frameToBeat(end, beat)) {
            int32_t bar, num, den; double inBar;
            beatToBar(m.meters, beat, bar, inBar, num, den);
            map_.beatToFrame(barToBeat(m.meters, bar), b);
        }
        if (b > a && a >= c->start) {
            if (copy.midi()) { // notes are relative to the clip start: shift them, drop what falls outside
                const int64_t shift = a - c->start;
                std::vector<MidiNote> notes;
                for (MidiNote n : *c->notes)
                    if (n.start >= shift && n.start < shift + (b - a)) { n.start -= shift; notes.push_back(n); }
                copy.notes = std::make_shared<const std::vector<MidiNote>>(std::move(notes));
            } else {
                copy.offset += a - c->start;
            }
            copy.length = b - a;
        }
        copy.id = id;
        copy.slot = slot;
        copy.folder = 0;
        copy.alt = false;
        copy.start = 0;
        const DalnokTrackId track = c->track;
        std::erase_if(m.clips, [&](const ClipState &x) {
            return (x.track == track && x.slot == slot) || std::find(takes.begin(), takes.end(), x.id) != takes.end();
        });
        m.clips.push_back(std::move(copy));
        return true;
    });
    if (!ok) return 0;
    ++nextClip_;
    return id;
}

bool Engine::launch(DalnokTrackId track, int32_t slot, std::string &err) {
    const TrackState *t = model_.track(track);
    if (!t) return fail(err, "no such track");
    if (slot >= 0 && std::none_of(model_.clips.begin(), model_.clips.end(), [&](const ClipState &c) { return c.track == track && c.slot == slot; }))
        return fail(err, "that slot is empty");
    // Launch times are timeline frames; the audio thread switches when the rendered position (the playhead
    // plus delay compensation) reaches them, so the change is heard exactly on the bar.
    const bool rolling = transport_.playing.load();
    const int64_t at = rolling ? nextBar(model_, map_, position() + 1) : position();
    t->runtime->launchTarget.store(slot, std::memory_order_relaxed);
    t->runtime->launchAt.store(at, std::memory_order_release);
    if (!rolling && slot >= 0) play();
    return true;
}

bool Engine::launchScene(int32_t slot, std::string &err) {
    if (slot < 0 || slot >= model_.scenes) return fail(err, "no such scene");
    bool any = false;
    for (const auto &t : model_.tracks) {
        const bool filled = std::any_of(model_.clips.begin(), model_.clips.end(), [&](const ClipState &c) { return c.track == t.id && c.slot == slot; });
        std::string ignored;
        if (filled) any = launch(t.id, slot, ignored) || any;
        else if (t.runtime->playingSlot.load() >= 0) launch(t.id, -1, ignored); // empty slot in the scene: that track stops its clip
    }
    return any || fail(err, "that scene is empty");
}

void Engine::stopLauncher() {
    std::string ignored;
    for (const auto &t : model_.tracks)
        if (t.runtime->playingSlot.load() >= 0 || t.runtime->launchAt.load() >= 0) launch(t.id, -1, ignored);
}

int64_t Engine::slotStart(DalnokTrackId track) const {
    const TrackState *t = model_.track(track);
    return t ? t->runtime->slotStart.load(std::memory_order_relaxed) : 0;
}

bool Engine::setFollowAction(DalnokClipId clip, int32_t action, int32_t loops, std::string &err) {
    if (action < 0 || action > 2 || loops < 1 || loops > 1024) return fail(err, "follow action is 0 none, 1 next, 2 stop; loops 1-1024");
    return edit("Follow Action", true, [&](Model &m) {
        ClipState *c = m.clip(clip);
        if (!c || c->slot < 0) return fail(err, "not a launcher clip");
        c->follow = action;
        c->followLoops = loops;
        return true;
    });
}

void Engine::setLauncherRecording(bool on) {
    if (on == launcherRecording_.load()) return;
    if (on) {
        LaunchEvent e;
        while (launchEvents_.pop(e)) {}
        launchLog_.clear();
        launcherRecordStart_ = position();
        // Tracks already playing a slot start their segment where recording began.
        for (const auto &t : model_.tracks)
            if (int32_t ps = t.runtime->playingSlot.load(); ps >= 0) launchLog_.push_back({t.id, ps, launcherRecordStart_});
        launcherRecording_.store(true);
        return;
    }
    launcherRecording_.store(false);
    LaunchEvent e;
    while (launchEvents_.pop(e)) launchLog_.push_back(e);
    const int64_t end = position();
    // Each track's segments: from a switch to the next switch (or the end); slot -1 = arrangement.
    struct Piece { DalnokTrackId track; int32_t slot; int64_t from, to, slotStart; };
    std::vector<Piece> pieces;
    std::map<DalnokTrackId, std::vector<LaunchEvent>> byTrack;
    for (const auto &ev : launchLog_) byTrack[ev.track].push_back(ev);
    for (auto &[track, evs] : byTrack) {
        std::stable_sort(evs.begin(), evs.end(), [](const LaunchEvent &a, const LaunchEvent &b) { return a.frame < b.frame; });
        for (size_t i = 0; i < evs.size(); ++i) {
            const int64_t to = i + 1 < evs.size() ? evs[i + 1].frame : end;
            if (evs[i].slot >= 0 && to > evs[i].frame) pieces.push_back({track, evs[i].slot, evs[i].frame, to, evs[i].frame});
        }
    }
    launchLog_.clear();
    if (pieces.empty()) return;
    std::string err;
    edit("Record Launcher", true, [&](Model &m) {
        for (const auto &p : pieces) {
            const auto src = std::find_if(m.clips.begin(), m.clips.end(), [&](const ClipState &c) { return c.track == p.track && c.slot == p.slot; });
            if (src == m.clips.end() || src->length <= 0) continue;
            const ClipState proto = *src;
            // One clip per loop pass, the last one trimmed where the performance moved on.
            for (int64_t at = p.from; at < p.to; at += proto.length) {
                ClipState c = proto;
                c.id = nextClip_++;
                c.slot = -1;
                c.follow = 0;
                c.start = at;
                c.length = std::min(proto.length, p.to - at);
                // Recorded material replaces whatever the arrangement had there.
                std::erase_if(m.clips, [&](const ClipState &x) {
                    return x.track == p.track && x.slot < 0 && !x.alt && x.start >= c.start && x.start + x.length <= c.start + c.length && x.id != c.id;
                });
                m.clips.push_back(std::move(c));
            }
        }
        return true;
    });
}

int32_t Engine::playingSlot(DalnokTrackId track) const {
    const TrackState *t = model_.track(track);
    return t ? t->runtime->playingSlot.load(std::memory_order_relaxed) : -1;
}

} // namespace dalnok
