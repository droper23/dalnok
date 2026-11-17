// SPDX-License-Identifier: GPL-3.0-or-later
#include "tempo_map.hpp"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <limits>
#include <utility>

namespace dalnok {
namespace {
// On platforms where long double is only 64 bits, this bound still leaves
// enough precision for sub-sample rounding and substantial timeline headroom.
constexpr int64_t kMaxFrame = int64_t{1} << 48;

bool fail(std::string &err, const char *message) {
    err = message;
    return false;
}

bool roundedFrame(long double frame, int64_t &out) {
    if (!std::isfinite(frame) || std::fabs(frame) > static_cast<long double>(kMaxFrame) - 1)
        return false;
    out = static_cast<int64_t>(std::round(frame));
    return true;
}
} // namespace

bool TempoMap::build(double sampleRate, const std::vector<TempoPoint> &points, TempoMap &out, std::string &err) {
    if (!std::isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 768000)
        return fail(err, "sample rate must be 8000-768000 Hz");
    if (points.empty() || points.front().beat != 0)
        return fail(err, "tempo map must start at beat zero");

    TempoMap candidate;
    candidate.segments_.reserve(points.size());
    long double frame = 0;
    int64_t previousFrame = -1;
    for (size_t i = 0; i < points.size(); ++i) {
        const auto &point = points[i];
        if (!std::isfinite(point.beat) || point.beat < 0 || !std::isfinite(point.bpm) ||
            point.bpm < 20 || point.bpm > 400)
            return fail(err, "invalid tempo point");
        if (i != 0) {
            if (!(point.beat > points[i - 1].beat)) return fail(err, "tempo beats must be strictly increasing");
            frame += (static_cast<long double>(point.beat) - points[i - 1].beat) * candidate.segments_.back().framesPerBeat;
        }
        int64_t rounded;
        if (!roundedFrame(frame, rounded)) return fail(err, "tempo point is beyond the supported timeline");
        if (rounded <= previousFrame) return fail(err, "tempo points must occupy different frames");
        previousFrame = rounded;
        candidate.segments_.push_back({point.beat, frame, static_cast<long double>(sampleRate) * 60 / point.bpm});
    }
    out = std::move(candidate);
    err.clear();
    return true;
}

bool TempoMap::beatToFrame(double beat, int64_t &out) const {
    if (segments_.empty() || !std::isfinite(beat)) return false;
    const auto next = std::upper_bound(segments_.begin(), segments_.end(), beat,
        [](double value, const Segment &s) { return value < s.beat; });
    const auto &s = next == segments_.begin() ? segments_.front() : *std::prev(next);
    const long double frame = s.frame + (static_cast<long double>(beat) - s.beat) * s.framesPerBeat;
    return roundedFrame(frame, out);
}

bool TempoMap::frameToBeat(int64_t frame, double &out) const {
    if (segments_.empty() || frame <= -kMaxFrame || frame >= kMaxFrame) return false;
    const long double position = frame;
    const auto next = std::upper_bound(segments_.begin(), segments_.end(), position,
        [](long double value, const Segment &s) { return value < s.frame; });
    const auto &s = next == segments_.begin() ? segments_.front() : *std::prev(next);
    const long double beat = s.beat + (position - s.frame) / s.framesPerBeat;
    const double result = static_cast<double>(beat);
    if (!std::isfinite(result)) return false;
    out = result;
    return true;
}

} // namespace dalnok
