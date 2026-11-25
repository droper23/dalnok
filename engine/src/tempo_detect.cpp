// Tempo detection (see tempo_detect.hpp).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "tempo_detect.hpp"

#include <algorithm>
#include <cmath>

namespace dalnok {
namespace {
constexpr double kFrameRate = 200; // onset frames per second
constexpr double kMinBpm = 60, kMaxBpm = 200;

// The onset envelope: summed positive changes of RMS amplitude in low (< 150 Hz), mid and high (> 2 kHz) bands,
// less its local mean (half a second), floored at zero.
std::vector<double> onsets(const std::vector<float> &x, double sr) {
    const auto hop = static_cast<size_t>(std::max(1.0, std::round(sr / kFrameRate)));
    const size_t frames = x.size() / hop;
    std::vector<double> o(frames, 0.0);
    const double a1 = 1 - std::exp(-2 * M_PI * 150 / sr), a2 = 1 - std::exp(-2 * M_PI * 2000 / sr);
    double lp1 = 0, lp2 = 0;
    double prev[3] = {0, 0, 0};
    for (size_t f = 0; f < frames; ++f) {
        double e[3] = {0, 0, 0};
        for (size_t i = f * hop; i < (f + 1) * hop; ++i) {
            const double s = x[i];
            lp1 += a1 * (s - lp1);
            lp2 += a2 * (s - lp2);
            const double b[3] = {lp1, lp2 - lp1, s - lp2};
            for (int k = 0; k < 3; ++k) e[k] += b[k] * b[k];
        }
        double flux = 0;
        for (int k = 0; k < 3; ++k) {
            const double l = std::sqrt(e[k] / static_cast<double>(hop)); // amplitude: louder hits count for more
            if (f > 0) flux += std::max(0.0, l - prev[k]);
            prev[k] = l;
        }
        o[f] = flux;
    }
    const auto half = static_cast<size_t>(kFrameRate / 4);
    std::vector<double> prefix(frames + 1, 0.0);
    for (size_t f = 0; f < frames; ++f) prefix[f + 1] = prefix[f] + o[f];
    std::vector<double> out(frames);
    for (size_t f = 0; f < frames; ++f) {
        const size_t lo = f > half ? f - half : 0, hi = std::min(frames, f + half + 1);
        out[f] = std::max(0.0, o[f] - (prefix[hi] - prefix[lo]) / static_cast<double>(hi - lo));
    }
    return out;
}

double at(const std::vector<double> &o, double t) { // linear interpolation
    const auto i = static_cast<size_t>(t);
    if (i + 1 >= o.size()) return i < o.size() ? o[i] : 0.0;
    const double f = t - static_cast<double>(i);
    return o[i] + f * (o[i + 1] - o[i]);
}

// The pulse train of `period` frames through `phase`: mean onset strength on its beats (each beat takes the
// strongest onset within a frame either side, so a slightly early or late hit still counts).
double comb(const std::vector<double> &o, double period, double phase) {
    double sum = 0;
    int n = 0;
    for (double t = phase; t + 1 < static_cast<double>(o.size()); t += period, ++n)
        sum += std::max({at(o, t), at(o, std::max(0.0, t - 1)), at(o, t + 1)});
    return n > 0 ? sum / n : 0;
}
} // namespace

TempoEstimate detectTempo(const std::vector<float> &mono, double sr) {
    TempoEstimate r;
    if (sr <= 0 || static_cast<double>(mono.size()) < 4 * sr) return r;
    const auto o = onsets(mono, sr);
    const size_t n = o.size();
    // Coarse: autocorrelation with its second and fourth harmonics, times a mild preference for 120 BPM.
    const auto minLag = static_cast<size_t>(std::floor(kFrameRate * 60 / kMaxBpm));
    const auto maxLag = static_cast<size_t>(std::ceil(kFrameRate * 60 / kMinBpm));
    auto acf = [&](size_t lag) {
        if (lag >= n) return 0.0;
        double s = 0;
        for (size_t t = 0; t + lag < n; ++t) s += o[t] * o[t + lag];
        return s / static_cast<double>(n - lag);
    };
    double best = -1;
    size_t bestLag = 0;
    for (size_t lag = minLag; lag <= maxLag; ++lag) {
        const double bpm = kFrameRate * 60 / static_cast<double>(lag);
        const double prior = std::exp(-0.5 * std::pow(std::log2(bpm / 120) / 0.9, 2));
        const double score = (acf(lag) + 0.5 * acf(2 * lag) + 0.25 * acf(4 * lag)) * prior;
        if (score > best) { best = score; bestLag = lag; }
    }
    if (bestLag == 0 || best <= 0) return r;
    // Fine: period (±2 %, steps of 0.02 %) and phase (a tenth of a frame), lining the pulse train up over the file.
    double period = static_cast<double>(bestLag), phase = 0, top = -1;
    const double lo = period * 0.98, hi = period * 1.02;
    for (double p = lo; p <= hi; p += period * 0.0002)
        for (double ph = 0; ph < p; ph += 0.5) {
            const double c = comb(o, p, ph);
            if (c > top) { top = c; period = p; phase = ph; }
        }
    // The phase, finer and without the frame of slack either side (which would let it sit a frame early).
    double exact = -1, fine = phase;
    for (double ph = std::max(0.0, phase - 1); ph <= phase + 1; ph += 0.05) {
        double sum = 0;
        int k = 0;
        for (double t = ph; t + 1 < static_cast<double>(n); t += period, ++k) sum += at(o, t);
        if (k > 0 && sum / k > exact) { exact = sum / k; fine = ph; }
    }
    phase = std::fmod(fine, period);
    // Confidence: the onset envelope's autocovariance one beat apart, as a share of its variance (one or two beats
    // apart, the best of a frame either side): near 1 for a steady beat, near 0 for noise. (Not the fitted pulse train's own strength,
    // which a fine search can always find in noise.)
    double mean = 0;
    for (double v : o) mean += v;
    mean /= static_cast<double>(n);
    const double var = acf(0) - mean * mean;
    const auto lag = static_cast<size_t>(std::llround(period));
    const auto lag2 = static_cast<size_t>(std::llround(2 * period)); // a kick-snare beat repeats every two beats
    const double cov = std::max({acf(lag - 1), acf(lag), acf(lag + 1), acf(lag2 - 1), acf(lag2), acf(lag2 + 1)}) - mean * mean;
    r.confidence = var > 0 ? std::clamp(cov / var, 0.0, 1.0) : 0;
    r.bpm = kFrameRate * 60 / period;
    // A hit shows in the frame it falls in, so a beat is at its frame's start (within one hop, 5 ms).
    const double hop = std::max(1.0, std::round(sr / kFrameRate));
    r.firstBeat = std::llround(phase * hop);
    return r;
}

} // namespace dalnok
