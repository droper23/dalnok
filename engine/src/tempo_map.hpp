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
    // Unrounded conversions for drawing (valid maps only; extrapolate outside).
    double beatToFrameExact(double beat) const;
    double frameToBeatExact(double frame) const;
    bool valid() const { return !segments_.empty(); }
    struct Segment {
        double beat;
        long double frame;
        long double framesPerBeat;
    };
    const std::vector<Segment> &segments() const { return segments_; }

private:
    std::vector<Segment> segments_;
};

// A meter that starts at a bar (0-based). The first change is at bar 0; bars strictly increase.
struct MeterChange {
    int32_t bar = 0;
    int32_t num = 4, den = 4;
};

bool validMeters(const std::vector<MeterChange> &meters, std::string &err);
// Quarter-note beat at which a (0-based) bar starts.
double barToBeat(const std::vector<MeterChange> &meters, int32_t bar);
// Bar (0-based) containing `beat`, the position within it in meter units (0-based, fractional), and its meter.
void beatToBar(const std::vector<MeterChange> &meters, double beat, int32_t &bar, double &beatInBar, int32_t &num,
               int32_t &den);

} // namespace dalnok
