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

double TempoMap::beatToFrameExact(double beat) const {
    if (segments_.empty()) return 0;
    const auto next = std::upper_bound(segments_.begin(), segments_.end(), beat,
        [](double value, const Segment &s) { return value < s.beat; });
    const auto &s = next == segments_.begin() ? segments_.front() : *std::prev(next);
    return static_cast<double>(s.frame + (static_cast<long double>(beat) - s.beat) * s.framesPerBeat);
}

double TempoMap::frameToBeatExact(double frame) const {
    if (segments_.empty()) return 0;
    const long double position = frame;
    const auto next = std::upper_bound(segments_.begin(), segments_.end(), position,
        [](long double value, const Segment &s) { return value < s.frame; });
    const auto &s = next == segments_.begin() ? segments_.front() : *std::prev(next);
    return static_cast<double>(s.beat + (position - s.frame) / s.framesPerBeat);
}

bool validMeters(const std::vector<MeterChange> &meters, std::string &err) {
    if (meters.empty() || meters.front().bar != 0) return fail(err, "meter map must start at bar 1");
    for (size_t i = 0; i < meters.size(); ++i) {
        const auto &m = meters[i];
        if (m.num < 1 || m.num > 32 || (m.den != 1 && m.den != 2 && m.den != 4 && m.den != 8 && m.den != 16))
            return fail(err, "meter must be 1-32 over 1, 2, 4, 8 or 16");
        if (m.bar < 0 || m.bar > 100000) return fail(err, "meter bar out of range");
        if (i && m.bar <= meters[i - 1].bar) return fail(err, "meter bars must be strictly increasing");
    }
    return true;
}

namespace {
double barBeats(const MeterChange &m) { return m.num * 4.0 / m.den; }
} // namespace

double barToBeat(const std::vector<MeterChange> &meters, int32_t bar) {
    double beat = 0;
    for (size_t i = 0; i < meters.size(); ++i) {
        const int32_t end = i + 1 < meters.size() ? meters[i + 1].bar : INT32_MAX;
        const int32_t upto = std::min(bar, end);
        if (upto > meters[i].bar) beat += (upto - meters[i].bar) * barBeats(meters[i]);
        if (bar <= end) break;
    }
    if (bar < 0 && !meters.empty()) beat = bar * barBeats(meters.front());
    return beat;
}

void beatToBar(const std::vector<MeterChange> &meters, double beat, int32_t &bar, double &beatInBar, int32_t &num,
               int32_t &den) {
    MeterChange m = meters.empty() ? MeterChange{} : meters.front();
    double start = 0;
    for (size_t i = 1; i < meters.size(); ++i) {
        const double next = start + (meters[i].bar - m.bar) * barBeats(m);
        if (beat < next) break;
        start = next;
        m = meters[i];
    }
    const double bars = std::floor((beat - start) / barBeats(m) + 1e-9);
    bar = m.bar + static_cast<int32_t>(bars);
    beatInBar = std::max(0.0, (beat - start - bars * barBeats(m)) * m.den / 4.0);
    num = m.num;
    den = m.den;
}

} // namespace dalnok
