// Engine: track groups (Logic's Groups). Members share the linked settings; the setters in engine.cpp and
// engine_device.cpp apply a change to the other members through groupLinked, as one undo step.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"
#include "engine_internal.hpp"

#include <algorithm>

namespace dalnok {
using namespace detail;

std::vector<DalnokTrackId> Engine::groupLinked(DalnokTrackId id, bool TrackGroup::*what) const {
    std::vector<DalnokTrackId> out;
    const TrackState *t = model_.track(id);
    if (groupClutch_ || !t || !t->group) return out;
    const auto g = std::find_if(model_.groups.begin(), model_.groups.end(), [&](const TrackGroup &x) { return x.id == t->group; });
    if (g == model_.groups.end() || !((*g).*what)) return out;
    for (const auto &m : model_.tracks) if (m.group == t->group && m.id != id) out.push_back(m.id);
    return out;
}

int32_t Engine::createGroup(const std::string &name, const std::vector<DalnokTrackId> &members, std::string &err) {
    int32_t id = 1;
    for (const auto &g : model_.groups) id = std::max(id, g.id + 1);
    const bool ok = edit("New Group", false, [&](Model &m) {
        for (DalnokTrackId t : members) if (!m.track(t)) return fail(err, "no such track");
        TrackGroup g;
        g.id = id;
        g.name = name.empty() ? "Group " + std::to_string(id) : name;
        m.groups.push_back(g);
        for (DalnokTrackId t : members) m.track(t)->group = id;
        return true;
    });
    return ok ? id : 0;
}

bool Engine::removeGroup(int32_t id, std::string &err) {
    return edit("Delete Group", false, [&](Model &m) {
        const auto it = std::find_if(m.groups.begin(), m.groups.end(), [&](const TrackGroup &g) { return g.id == id; });
        if (it == m.groups.end()) return fail(err, "no such group");
        m.groups.erase(it);
        for (auto &t : m.tracks) if (t.group == id) t.group = 0;
        return true;
    });
}

bool Engine::setTrackGroup(DalnokTrackId track, int32_t group, std::string &err) {
    return edit(group ? "Add to Group" : "Remove from Group", false, [&](Model &m) {
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        if (group && std::none_of(m.groups.begin(), m.groups.end(), [&](const TrackGroup &g) { return g.id == group; }))
            return fail(err, "no such group");
        t->group = group;
        return true;
    });
}

bool Engine::setGroup(const TrackGroup &g, std::string &err) {
    return edit("Group Settings", false, [&](Model &m) {
        const auto it = std::find_if(m.groups.begin(), m.groups.end(), [&](const TrackGroup &x) { return x.id == g.id; });
        if (it == m.groups.end()) return fail(err, "no such group");
        if (g.name.empty()) return fail(err, "a group needs a name");
        *it = g;
        return true;
    });
}

} // namespace dalnok
