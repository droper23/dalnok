// Audio quantize (Logic's Flex quantize, done with slices): find the transients of an audio clip, cut the clip just
// before each one, move every slice so its transient lands on the quantize grid (by the strength), and make each slice
// run exactly to the next one: no gaps, no doubled attacks. Transients are never stretched: each slice plays its
// attack (the first 50 ms) as it is, bit-exact, and only its decaying tail is time-stretched (Signalsmith Stretch,
// pitch kept) to take up the change. A stretcher smears whatever it stretches and blurs sounds near a region's edges;
// keeping attacks out of it keeps them sharp. Slices that barely move stay whole and unstretched. Every cut is a short
// linear crossfade in the quiet moment before an attack (or inside a decay), so no boundary cuts a sound.
//
// Transient detection: SuperFlux-style spectral flux (log-compressed magnitudes, a maximum filter across frequency on
// the previous frame so vibrato and slow glides don't read as onsets), adaptive mean threshold and local-maximum peak
// picking, then each onset is refined to the sample where its amplitude envelope starts to rise.
// Control thread only (reads media, may block on a streamed source's cache file).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"
#include "tempo_detect.hpp"
#include "engine_internal.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdlib>
#include <numeric>
#include <vector>

namespace dalnok {
using namespace detail;

namespace {

// In-place iterative radix-2 FFT (n a power of two).
void fft(std::vector<std::complex<float>> &a) {
    const size_t n = a.size();
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double ang = -2.0 * M_PI / static_cast<double>(len);
        const std::complex<float> wl(static_cast<float>(std::cos(ang)), static_cast<float>(std::sin(ang)));
        for (size_t i = 0; i < n; i += len) {
            std::complex<float> w(1, 0);
            for (size_t k = 0; k < len / 2; ++k) {
                const auto u = a[i + k], v = a[i + k + len / 2] * w;
                a[i + k] = u + v;
                a[i + k + len / 2] = u - v;
                w *= wl;
            }
        }
    }
}

} // namespace

std::vector<int64_t> detectTransients(const std::vector<float> &x, double sampleRate, double sensitivity) {
    std::vector<int64_t> out;
    const int64_t total = static_cast<int64_t>(x.size());
    if (total < 64 || !(sampleRate > 0)) return out;
    size_t n = 256;
    while (static_cast<double>(n) < sampleRate * 0.021) n <<= 1; // ~21 ms windows (1024 at 44.1 / 48 kHz)
    const size_t hop = n / 4;
    const int64_t frames = std::max<int64_t>(1, (total + static_cast<int64_t>(hop) - 1) / static_cast<int64_t>(hop));
    std::vector<float> window(n);
    for (size_t i = 0; i < n; ++i) window[i] = static_cast<float>(0.5 - 0.5 * std::cos(2 * M_PI * static_cast<double>(i) / static_cast<double>(n)));
    const size_t bins = n / 2 + 1;
    std::vector<float> prev(bins, 0), prevMax(bins, 0), cur(bins);
    std::vector<double> flux(static_cast<size_t>(frames), 0), level(static_cast<size_t>(frames), 0);
    std::vector<std::complex<float>> buf(n);
    const double minShare = 0.04 + 0.12 * (1.0 - std::clamp(sensitivity, 0.0, 1.0)); // 0.1 at sensitivity 0.5
    // Frame f's window ends at f * hop + hop, so the newest hop of audio in it is where an onset in frame f is.
    for (int64_t f = 0; f < frames; ++f) {
        const int64_t start = f * static_cast<int64_t>(hop) + static_cast<int64_t>(hop) - static_cast<int64_t>(n);
        double energy = 0;
        for (size_t i = 0; i < n; ++i) {
            const int64_t s = start + static_cast<int64_t>(i);
            const float v = s >= 0 && s < total ? x[static_cast<size_t>(s)] : 0.0f;
            energy += static_cast<double>(v) * v;
            buf[i] = {v * window[i], 0};
        }
        level[static_cast<size_t>(f)] = std::sqrt(energy / static_cast<double>(n));
        fft(buf);
        for (size_t k = 0; k < bins; ++k) cur[k] = std::log10(1.0f + 100.0f * std::abs(buf[k]));
        double d = 0;
        for (size_t k = 0; k < bins; ++k) d += std::max(0.0f, cur[k] - prevMax[k]);
        // Only new energy that is a real share of the frame counts: a steady tone's spectrum wobbles a little with
        // its phase against the window, which is never a large fraction of what sounds (an attack is most of it).
        double total = 0;
        for (size_t k = 0; k < bins; ++k) total += cur[k];
        flux[static_cast<size_t>(f)] = f == 0 || d < minShare * (total + 1e-6) ? 0 : d;
        prev = cur;
        for (size_t k = 0; k < bins; ++k)
            prevMax[k] = std::max({prev[k], k > 0 ? prev[k - 1] : 0.0f, k + 1 < bins ? prev[k + 1] : 0.0f});
    }
    // Normalize by a robust maximum (98th percentile of the nonzero flux) so the threshold means the same at any level.
    std::vector<double> sorted;
    for (double v : flux) if (v > 0) sorted.push_back(v);
    if (sorted.empty()) return out;
    std::sort(sorted.begin(), sorted.end());
    // A floor keeps rounding noise in steady sounds from being scaled up into onsets (a real attack's flux is ~50+).
    const double top = std::max(5.0, sorted[static_cast<size_t>(0.98 * static_cast<double>(sorted.size() - 1))]);
    for (double &v : flux) v /= top;
    const double peakLevel = *std::max_element(level.begin(), level.end());
    const double delta = 0.02 + 0.28 * (1.0 - std::clamp(sensitivity, 0.0, 1.0)); // sensitivity 0.5 -> 0.16
    const auto ms = [&](double t) { return std::max<int64_t>(1, std::llround(t * 0.001 * sampleRate / static_cast<double>(hop))); };
    const int64_t preMax = ms(30), postMax = ms(30), preAvg = ms(100), postAvg = ms(70), combine = ms(30);
    std::vector<int64_t> onsetFrames;
    for (int64_t f = 1; f < frames; ++f) {
        const double v = flux[static_cast<size_t>(f)];
        if (v <= 0) continue;
        bool isMax = true;
        for (int64_t g = std::max<int64_t>(0, f - preMax); g <= std::min(frames - 1, f + postMax) && isMax; ++g)
            if (flux[static_cast<size_t>(g)] > v || (flux[static_cast<size_t>(g)] == v && g < f)) isMax = false;
        if (!isMax) continue;
        double sum = 0;
        int64_t cnt = 0;
        for (int64_t g = std::max<int64_t>(0, f - preAvg); g <= std::min(frames - 1, f + postAvg); ++g, ++cnt) sum += flux[static_cast<size_t>(g)];
        if (v < sum / static_cast<double>(std::max<int64_t>(1, cnt)) + delta) continue;
        // Gate out noise: the frame must reach -54 dB below the clip's loudest frame and above -80 dBFS.
        const double lv = std::max(level[static_cast<size_t>(f)], f + 1 < frames ? level[static_cast<size_t>(f + 1)] : 0.0);
        if (lv < peakLevel * 0.002 || lv < 1e-4) continue;
        if (!onsetFrames.empty() && f - onsetFrames.back() < combine) continue;
        onsetFrames.push_back(f);
    }
    // Refine each onset to where its envelope starts to rise (the attack start): 0.25 ms peak blocks around the frame.
    const int64_t blk = std::max<int64_t>(1, std::llround(sampleRate * 0.00025));
    auto env = [&](int64_t b) {
        float m = 0;
        for (int64_t s = b * blk; s < std::min(total, (b + 1) * blk); ++s) m = std::max(m, std::fabs(x[static_cast<size_t>(s)]));
        return m;
    };
    int64_t last = -1;
    for (int64_t f : onsetFrames) {
        const int64_t newest = f * static_cast<int64_t>(hop); // the newest hop starts here
        const int64_t lo = std::max<int64_t>(0, newest - static_cast<int64_t>(hop) - std::llround(sampleRate * 0.004));
        const int64_t hi = std::min(total, newest + 2 * static_cast<int64_t>(hop));
        if (hi - lo < 4 * blk) continue;
        const int64_t b0 = lo / blk, b1 = std::max(b0 + 1, hi / blk);
        std::vector<float> e(static_cast<size_t>(b1 - b0));
        for (int64_t b = b0; b < b1; ++b) e[static_cast<size_t>(b - b0)] = env(b);
        // The steepest rise in the window is the attack; its peak follows it.
        size_t steep = 1;
        float best = -1;
        for (size_t i = 1; i < e.size(); ++i) {
            const float rise = e[i] - e[i - 1];
            if (rise > best) { best = rise; steep = i; }
        }
        size_t pk = steep;
        for (size_t i = steep; i < e.size() && i < steep + 40; ++i) if (e[i] > e[pk]) pk = i;
        float base = e[pk];
        for (size_t i = (pk > 80 ? pk - 80 : 0); i <= pk; ++i) base = std::min(base, e[i]);
        const float thr = base + 0.12f * (e[pk] - base);
        size_t a = pk;
        while (a > 0 && e[a - 1] > thr) --a;
        // Walk back to the last block at the floor: the sample where the attack leaves it.
        int64_t at = (b0 + static_cast<int64_t>(a)) * blk;
        for (int64_t s = at; s < std::min(total, at + blk); ++s)
            if (std::fabs(x[static_cast<size_t>(s)]) > thr) { at = s; break; }
        if (at <= last) continue;
        out.push_back(at);
        last = at;
    }
    return out;
}

std::vector<int64_t> Engine::audioTransients(DalnokClipId id, double sensitivity, std::string &err) const {
    const ClipState *c = model_.clip(id);
    if (!c) return fail(err, "no such clip"), std::vector<int64_t>{};
    if (c->midi()) return fail(err, "MIDI clips have no audio transients"), std::vector<int64_t>{};
    const PoolEntry *pe = poolEntry(c->media);
    if (!pe || !pe->handle->impl) return fail(err, "the clip's audio is offline"), std::vector<int64_t>{};
    const Media &m = *pe->handle->impl;
    const int64_t span = std::min(c->sourceLength(), m.frames() - c->offset);
    if (span <= 0) return {};
    std::vector<float> l(static_cast<size_t>(span)), r(static_cast<size_t>(span));
    m.read(c->offset, span, l.data(), r.data());
    for (size_t i = 0; i < l.size(); ++i) l[i] = 0.5f * (l[i] + r[i]);
    auto t = detectTransients(l, static_cast<double>(m.sampleRate()), sensitivity);
    for (auto &v : t) v += c->offset;
    return t;
}

bool Engine::clipTempo(DalnokClipId id, double &bpm, int64_t &firstBeat, double &confidence, std::string &err) const {
    bpm = 0, firstBeat = 0, confidence = 0;
    const ClipState *c = model_.clip(id);
    if (!c) return fail(err, "no such clip");
    if (c->midi()) return fail(err, "MIDI clips have no audio to analyze");
    const PoolEntry *pe = poolEntry(c->media);
    if (!pe || !pe->handle->impl) return fail(err, "the clip's audio is offline");
    const Media &m = *pe->handle->impl;
    const int64_t span = std::min(c->sourceLength(), m.frames() - c->offset);
    if (span < static_cast<int64_t>(4 * m.sampleRate())) return fail(err, "the clip is too short to hear a tempo (4 s at least)");
    std::vector<float> l(static_cast<size_t>(span)), r(static_cast<size_t>(span));
    m.read(c->offset, span, l.data(), r.data());
    for (size_t i = 0; i < l.size(); ++i) l[i] = 0.5f * (l[i] + r[i]);
    const TempoEstimate t = detectTempo(l, m.sampleRate());
    if (t.bpm <= 0) return fail(err, "no steady beat found");
    bpm = t.bpm, firstBeat = t.firstBeat, confidence = t.confidence;
    return true;
}

bool Engine::quantizeAudio(DalnokClipId id, double gridBeats, double strength, double sensitivity, std::string &err) {
    if (!(gridBeats > 0) || !(strength > 0) || strength > 1) return fail(err, "grid must be > 0 and strength in (0, 1]");
    const ClipState *src = model_.clip(id);
    if (!src) return fail(err, "no such clip");
    if (src->midi()) return fail(err, "use midi.quantize for MIDI clips");
    if (src->slot >= 0 || src->alt || src->folder != 0) return fail(err, "only arrangement clips outside take folders can be quantized");
    if (!src->preservePitch && std::fabs(src->rate - 1.0) > 1e-9) return fail(err, "varispeed clips can't be quantized");
    const ClipState c = *src;
    const PoolEntry *pe = poolEntry(c.media);
    if (!pe || !pe->handle->impl) return fail(err, "the clip's audio is offline");
    const double sr = static_cast<double>(pe->handle->impl->sampleRate());
    const auto transients = audioTransients(id, sensitivity, err);
    if (!err.empty()) return false;

    // Quantize from the performance as recorded (any earlier warp is replaced, not compounded): the source spread
    // evenly over the clip, as it plays without a warp.
    const int64_t span = c.warped() ? c.warp->back().source - c.warp->front().source : c.sourceLength();
    const double rate0 = static_cast<double>(span) / static_cast<double>(c.length);
    const auto clipTime = [&](double s) { return (s - static_cast<double>(c.offset)) / rate0; }; // from the clip's start
    const int64_t pre = std::llround(sr * 0.006);   // anchors sit this far before each attack (source frames)
    const int64_t head = std::llround(sr * 0.05);   // an attack's first 50 ms play at their own speed
    const int64_t minSeg = std::llround(sr * 0.02);
    const int64_t x = warpCrossfade(sr);
    const int64_t srcEnd = c.offset + span;
    // Cuts: (source frame, clip time after quantizing). The clip's start and end stay where they are.
    struct Cut { int64_t source; double time; };
    std::vector<Cut> cuts{{c.offset, 0.0}};
    const auto speedOk = [&](double ds, double dt) { return dt >= static_cast<double>(minSeg) / 2 && ds / dt >= 0.5 * rate0 && ds / dt <= 2 * rate0; };
    for (int64_t a : transients) {
        const double at = static_cast<double>(c.start) + clipTime(static_cast<double>(a));
        double beat;
        int64_t grid;
        if (!map_.frameToBeat(static_cast<int64_t>(std::llround(at)), beat) ||
            !map_.beatToFrame(std::round(beat / gridBeats) * gridBeats, grid)) continue;
        const double target = at + (static_cast<double>(grid) - at) * strength - static_cast<double>(c.start);
        const int64_t cut = a - pre;
        const double cutTime = target - static_cast<double>(pre) / rate0;
        if (cut - cuts.back().source < minSeg || srcEnd - cut < minSeg) continue;
        if (!speedOk(static_cast<double>(cut - cuts.back().source), cutTime - cuts.back().time)) continue;
        cuts.push_back({cut, cutTime});
    }
    while (cuts.size() > 1 && !speedOk(static_cast<double>(srcEnd - cuts.back().source), static_cast<double>(c.length) - cuts.back().time))
        cuts.pop_back();
    if (cuts.size() == 1) return fail(err, "no transients to quantize");
    cuts.push_back({srcEnd, static_cast<double>(c.length)});

    // Anchors: between two cuts, the head (the attack) at the clip's own speed and the rest stretched to fit. A span
    // that barely changes length plays at one speed throughout (copied when the clip isn't stretched).
    WarpList w;
    for (size_t k = 0; k + 1 < cuts.size(); ++k) {
        const int64_t s0 = cuts[k].source, s1 = cuts[k + 1].source;
        const int64_t t0 = std::llround(cuts[k].time), t1 = std::llround(cuts[k + 1].time);
        w.push_back({s0, t0});
        const double natural = static_cast<double>(s1 - s0) / rate0;
        const int64_t h = std::min<int64_t>(head, std::min<int64_t>(t1 - t0, static_cast<int64_t>(natural)) / 3);
        if (std::fabs(natural - static_cast<double>(t1 - t0)) >= static_cast<double>(x) / 2 && h > x * 2)
            w.push_back({s0 + std::llround(static_cast<double>(h) * rate0), t0 + h});
    }
    w.push_back({srcEnd, c.length});
    w.front() = {c.offset, 0};
    if (!warpValid(w)) return fail(err, "the quantized timing can't be played (transients too close together)");

    return edit("Quantize Audio", true, [&](Model &m) {
        ClipState *t = m.clip(id);
        if (!t) return fail(err, "no such clip");
        t->rate = rate0;
        t->preservePitch = true;
        t->warp = std::make_shared<const WarpList>(std::move(w));
        return true;
    });
}

bool Engine::setClipWarp(DalnokClipId id, WarpList w, std::string &err) {
    return edit(w.empty() ? "Remove Quantize" : "Warp Clip", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        if (c->midi()) return fail(err, "MIDI clips have no warp");
        if (w.empty()) {
            if (!c->warped()) return fail(err, "the clip has no warp");
            c->rate = static_cast<double>(c->warp->back().source - c->warp->front().source) / static_cast<double>(c->length);
            c->warp = nullptr;
            return true;
        }
        const PoolEntry *pe = poolEntry(c->media);
        if (!warpValid(w) || w.front().source != c->offset || w.back().time != c->length || !pe || w.back().source > pe->frames)
            return fail(err, "a warp starts at the clip's offset, ends at its length, inside its audio, speeds 0.25-4");
        c->rate = static_cast<double>(w.back().source - w.front().source) / static_cast<double>(c->length);
        c->preservePitch = true;
        c->warp = std::make_shared<const WarpList>(std::move(w));
        return true;
    });
}

} // namespace dalnok
