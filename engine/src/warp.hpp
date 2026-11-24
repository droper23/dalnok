// Audio warp maps (audio quantize, API 47): a clip's source frames mapped onto its timeline by anchor points, each
// segment between two anchors playing at its own speed. Rendered off the audio thread like any stretch
// (stretch_cache.cpp): segments at 1:1 are copied as they are, the others time-stretched, with a short crossfade
// centred on every anchor. Control thread only.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <memory>
#include <vector>

namespace dalnok {

struct WarpPoint {
    int64_t source = 0; // frame in the clip's media
    int64_t time = 0;   // timeline frames from the clip's start
    bool operator==(const WarpPoint &) const = default;
};
using WarpList = std::vector<WarpPoint>;
using WarpMap = std::shared_ptr<const WarpList>; // immutable; shared across undo copies

/// Valid: at least two points, the first at time 0, times and sources strictly increasing, each segment's speed in
/// [0.25, 4].
bool warpValid(const WarpList &w);
/// The source frame at clip time `t` (linear inside a segment; 1:1 beyond the ends).
double warpSourceAt(const WarpList &w, double t);
/// The clip time where source frame `s` plays (inverse of warpSourceAt).
double warpTimeAt(const WarpList &w, double s);
/// The map for the clip times [t0, t1), rebased so t0 is time 0 (trims and splits). Beyond the old ends it continues
/// at 1:1. Returns an empty list when the result plays at one speed throughout (the clip needs no warp).
WarpList cropWarp(const WarpList &w, int64_t t0, int64_t t1);
uint64_t warpHash(const WarpList &w);
/// Half-width of the crossfade centred on each anchor (frames) at `sampleRate`.
inline int64_t warpCrossfade(double sampleRate) { return static_cast<int64_t>(sampleRate * 0.0025 + 0.5); }

} // namespace dalnok
