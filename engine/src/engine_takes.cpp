// Engine: take folders, comping and track stacks (split from engine.cpp, A-06).
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

int32_t Engine::makeTakeFolder(Model &m, DalnokTrackId track, std::vector<DalnokClipId> takes, std::string &err) {
    int32_t id = 1;
    for (const auto &f : m.folders) id = std::max(id, f.id + 1);
    TakeFolder f;
    f.id = id;
    f.track = track;
    f.takes = std::move(takes);
    // Default comp: later takes cover earlier ones (the newest pass plays wherever it was recorded).
    std::vector<CompSegment> comp;
    for (int32_t k = 0; k < static_cast<int32_t>(f.takes.size()); ++k) {
        ClipState *c = m.clip(f.takes[static_cast<size_t>(k)]);
        if (!c) return fail(err, "no such take"), 0;
        c->folder = id;
        c->alt = true;
        const int64_t a = c->start, b = c->start + c->length;
        std::vector<CompSegment> next;
        for (const auto &s : comp) { // cut existing segments around [a, b)
            if (s.to <= a || s.from >= b) { next.push_back(s); continue; }
            if (s.from < a) next.push_back({s.from, a, s.take});
            if (s.to > b) next.push_back({b, s.to, s.take});
        }
        next.push_back({a, b, k});
        std::sort(next.begin(), next.end(), [](const CompSegment &x, const CompSegment &y) { return x.from < y.from; });
        comp = std::move(next);
    }
    f.comp = std::move(comp);
    if (!realizeComp(m, f, nextClip_, err)) return 0;
    m.folders.push_back(std::move(f));
    return id;
}

int32_t Engine::addTakeFolder(DalnokTrackId track, std::vector<DalnokClipId> takes, std::string &err) {
    int32_t folder = 0;
    edit("Take Folder", true, [&](Model &m) {
        for (auto id : takes) {
            const ClipState *c = m.clip(id);
            if (!c || c->track != track || c->midi() || c->folder) return fail(err, "takes must be audio clips on the track, not in a folder");
        }
        folder = makeTakeFolder(m, track, std::move(takes), err);
        return folder != 0;
    });
    return folder;
}

bool Engine::setComp(int32_t folder, std::vector<CompSegment> comp, std::string &err) {
    std::sort(comp.begin(), comp.end(), [](const CompSegment &x, const CompSegment &y) { return x.from < y.from; });
    return edit("Comp", true, [&](Model &m) {
        auto it = std::find_if(m.folders.begin(), m.folders.end(), [&](const TakeFolder &f) { return f.id == folder; });
        if (it == m.folders.end()) return fail(err, "no such take folder");
        int64_t prev = INT64_MIN;
        for (const auto &seg : comp) {
            if (seg.take < 0 || seg.take >= static_cast<int32_t>(it->takes.size()) || seg.to <= seg.from || seg.from < prev)
                return fail(err, "comp segments must be ordered, non-overlapping and name a take");
            const ClipState *t = m.clip(it->takes[static_cast<size_t>(seg.take)]);
            if (!t || seg.from < t->start || seg.to > t->start + t->length) return fail(err, "a comp segment lies outside its take");
            prev = seg.to;
        }
        it->comp = std::move(comp);
        return realizeComp(m, *it, nextClip_, err);
    });
}

namespace {
// True when `track` is inside `stack` at any depth.
bool insideStack(const Model &m, DalnokTrackId track, DalnokTrackId stack) {
    for (const TrackState *t = m.track(track); t && t->stack; t = m.track(t->stack))
        if (t->stack == stack) return true;
    return false;
}
} // namespace

DalnokTrackId Engine::makeStack(const std::vector<DalnokTrackId> &members, const std::string &name, std::string &err) {
    const auto id = nextTrack_;
    const bool ok = edit("Create Track Stack", true, [&](Model &m) {
        if (members.empty()) return fail(err, "choose tracks for the stack");
        // Stacks nest: the members must share a parent (or none), and the new stack goes inside that parent.
        // A member that is itself a stack brings everything inside it along.
        const TrackState *first = m.track(members.front());
        if (!first) return fail(err, "no such track");
        const DalnokTrackId parent = first->stack;
        std::vector<size_t> at; // display indices of the members and everything inside them
        for (auto t : members) {
            auto it = std::find_if(m.tracks.begin(), m.tracks.end(), [t](const TrackState &x) { return x.id == t; });
            if (it == m.tracks.end()) return fail(err, "no such track");
            if (it->stack != parent) return fail(err, "tracks in a new stack must all be in the same stack (or in none)");
            const size_t i = static_cast<size_t>(it - m.tracks.begin());
            at.push_back(i);
            for (size_t j = i + 1; j < m.tracks.size() && insideStack(m, m.tracks[j].id, t); ++j) at.push_back(j);
        }
        std::sort(at.begin(), at.end());
        at.erase(std::unique(at.begin(), at.end()), at.end());
        TrackState stack;
        stack.id = id;
        stack.kind = kTrackBus;
        stack.isStack = true;
        stack.stack = parent;
        stack.name = name.empty() ? "Stack" : name;
        stack.color = m.tracks[at.front()].color;
        stack.output = m.tracks[at.front()].output; // the stack goes where its first member went
        stack.runtime = std::make_shared<TrackRuntime>();
        // Members (in their current order, with their contents) follow the stack, which takes the first one's place.
        std::vector<TrackState> moved;
        for (size_t i : at) moved.push_back(m.tracks[i]);
        for (auto it = at.rbegin(); it != at.rend(); ++it) m.tracks.erase(m.tracks.begin() + static_cast<long>(*it));
        for (auto &t : moved)
            if (std::find(members.begin(), members.end(), t.id) != members.end()) { t.output = id; t.stack = id; }
        const auto insertAt = m.tracks.begin() + static_cast<long>(at.front());
        moved.insert(moved.begin(), std::move(stack));
        m.tracks.insert(insertAt, moved.begin(), moved.end());
        if (m.track(id)->output && feedsBack(m, id, m.track(id)->output)) m.track(id)->output = 0;
        return true;
    });
    if (!ok) return 0;
    ++nextTrack_;
    return id;
}

bool Engine::setStackCollapsed(DalnokTrackId stack, bool collapsed, std::string &err) {
    return edit(collapsed ? "Close Stack" : "Open Stack", false, [&](Model &m) {
        TrackState *t = m.track(stack);
        if (!t || !t->isStack) return fail(err, "not a track stack");
        t->collapsed = collapsed;
        return true;
    });
}

bool Engine::setTrackHeight(DalnokTrackId track, float height, std::string &err) {
    if (!std::isfinite(height) || height < 0) return fail(err, "height must be 0 (default) or positive");
    const float h = height == 0 ? 0.0f : std::clamp(height, kMinTrackHeight, kMaxTrackHeight);
    if (track && !model_.track(track)) return fail(err, "no such track");
    return edit("Track Height", false, [&](Model &m) {
        for (auto &t : m.tracks) if (!track || t.id == track) t.height = h;
        return true;
    });
}

bool Engine::setTrackHidden(DalnokTrackId track, bool hidden, std::string &err) {
    if (track == 0 && !hidden) {
        if (std::none_of(model_.tracks.begin(), model_.tracks.end(), [](const TrackState &t) { return t.hidden; })) return fail(err, "no hidden tracks");
        return edit("Show All Tracks", false, [&](Model &m) { for (auto &t : m.tracks) t.hidden = false; return true; });
    }
    return edit(hidden ? "Hide Track" : "Show Track", false, [&](Model &m) {
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        if (t->hidden == hidden) return fail(err, hidden ? "already hidden" : "not hidden");
        t->hidden = hidden;
        return true;
    });
}

bool Engine::setPhaseInvert(DalnokTrackId track, bool on, std::string &err) {
    return edit(on ? "Invert Phase" : "Restore Phase", true, [&](Model &m) { // structural: the snapshot carries it
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        if (t->phaseInvert == on) return fail(err, on ? "already inverted" : "not inverted");
        t->phaseInvert = on;
        return true;
    });
}

bool Engine::ungroupStack(DalnokTrackId stack, std::string &err) {
    return edit("Ungroup Track Stack", true, [&](Model &m) {
        TrackState *t = m.track(stack);
        if (!t || !t->isStack) return fail(err, "not a track stack");
        const auto out = t->output, parent = t->stack;
        for (auto &x : m.tracks) {
            if (x.stack == stack) { x.stack = parent; if (x.output == stack) x.output = out; } // back to the parent stack
            std::erase_if(x.sends, [stack](const Send &s) { return s.bus == stack; });
            if (x.output == stack) x.output = out;
        }
        std::erase_if(m.tracks, [stack](const TrackState &x) { return x.id == stack; });
        return true;
    });
}

} // namespace dalnok
