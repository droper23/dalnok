// SPDX-License-Identifier: GPL-3.0-or-later
#include "warp.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>

namespace dalnok {

bool warpValid(const WarpList &w) {
    if (w.size() < 2 || w.front().time != 0 || w.front().source < 0) return false;
    for (size_t i = 1; i < w.size(); ++i) {
        const int64_t ds = w[i].source - w[i - 1].source, dt = w[i].time - w[i - 1].time;
        if (ds <= 0 || dt <= 0) return false;
        const double r = static_cast<double>(ds) / static_cast<double>(dt);
        if (r < 0.25 || r > 4) return false;
    }
    return true;
}

double warpSourceAt(const WarpList &w, double t) {
    if (w.empty()) return t;
    if (t <= static_cast<double>(w.front().time)) return static_cast<double>(w.front().source) + (t - static_cast<double>(w.front().time));
    for (size_t i = 1; i < w.size(); ++i) {
        if (t <= static_cast<double>(w[i].time)) {
            const auto &a = w[i - 1], &b = w[i];
            return static_cast<double>(a.source) + (t - static_cast<double>(a.time)) * static_cast<double>(b.source - a.source) /
                                                       static_cast<double>(b.time - a.time);
        }
    }
    return static_cast<double>(w.back().source) + (t - static_cast<double>(w.back().time));
}

double warpTimeAt(const WarpList &w, double s) {
    if (w.empty()) return s;
    if (s <= static_cast<double>(w.front().source)) return static_cast<double>(w.front().time) + (s - static_cast<double>(w.front().source));
    for (size_t i = 1; i < w.size(); ++i) {
        if (s <= static_cast<double>(w[i].source)) {
            const auto &a = w[i - 1], &b = w[i];
            return static_cast<double>(a.time) + (s - static_cast<double>(a.source)) * static_cast<double>(b.time - a.time) /
                                                     static_cast<double>(b.source - a.source);
        }
    }
    return static_cast<double>(w.back().time) + (s - static_cast<double>(w.back().source));
}

WarpList cropWarp(const WarpList &w, int64_t t0, int64_t t1) {
    WarpList out;
    if (w.empty() || t1 <= t0) return out;
    out.push_back({static_cast<int64_t>(std::llround(warpSourceAt(w, static_cast<double>(t0)))), 0});
    for (const auto &p : w)
        if (p.time > t0 && p.time < t1) out.push_back({p.source, p.time - t0});
    out.push_back({static_cast<int64_t>(std::llround(warpSourceAt(w, static_cast<double>(t1)))), t1 - t0});
    // Drop points that leave a segment empty, then anchors between two segments of the same speed.
    WarpList clean;
    for (const auto &p : out)
        if (clean.empty() || (p.source > clean.back().source && p.time > clean.back().time)) clean.push_back(p);
    if (clean.size() < 2) return {};
    WarpList merged{clean.front()};
    for (size_t i = 1; i + 1 < clean.size(); ++i) {
        const auto &a = merged.back(), &b = clean[i], &c = clean[i + 1];
        const double r1 = static_cast<double>(b.source - a.source) / static_cast<double>(b.time - a.time);
        const double r2 = static_cast<double>(c.source - b.source) / static_cast<double>(c.time - b.time);
        if (std::fabs(r1 - r2) > 1e-6) merged.push_back(b);
    }
    merged.push_back(clean.back());
    if (merged.size() == 2) return {}; // one speed: an ordinary (maybe stretched) clip
    return merged;
}

uint64_t warpHash(const WarpList &w) {
    uint64_t h = 1469598103934665603ULL;
    auto mix = [&](int64_t v) { for (int i = 0; i < 8; ++i) { h ^= static_cast<uint64_t>(v >> (8 * i)) & 0xFF; h *= 1099511628211ULL; } };
    for (const auto &p : w) { mix(p.source); mix(p.time); }
    return h;
}

} // namespace dalnok
