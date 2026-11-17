// Piecewise-constant tempo conversion for the control thread.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace dalnok {

// Beats are quarter notes from the project origin. A tempo point takes effect
// at its beat; frames are rounded to the nearest sample, with half away from zero.
// Negative positions extrapolate backward using the initial tempo.
struct TempoPoint {
    double beat = 0;
    double bpm = 120;
};

class TempoMap {
public:
    // Points must be sorted, strictly increasing, and begin at beat zero.
    // Reject points that cannot be distinguished at the project sample rate.
    // On failure, `out` is unchanged. A default-constructed map is invalid.
    static bool build(double sampleRate, const std::vector<TempoPoint> &points, TempoMap &out, std::string &err);

    // Return false without changing `out` for an invalid map, non-finite
    // beats, or positions beyond the supported range.
    bool beatToFrame(double beat, int64_t &out) const;
    bool frameToBeat(int64_t frame, double &out) const;

private:
    struct Segment {
        double beat;
        long double frame;
        long double framesPerBeat;
    };
    std::vector<Segment> segments_;
};

} // namespace dalnok
