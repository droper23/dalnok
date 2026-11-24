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
#include "engine_internal.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
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

std::vector<DalnokClipId> Engine::quantizeAudio(DalnokClipId id, double gridBeats, double strength, double sensitivity,
                                                std::string &err) {
    if (!(gridBeats > 0) || !(strength > 0) || strength > 1) return fail(err, "grid must be > 0 and strength in (0, 1]"), std::vector<DalnokClipId>{};
    const ClipState *src = model_.clip(id);
    if (!src) return fail(err, "no such clip"), std::vector<DalnokClipId>{};
    if (src->midi()) return fail(err, "use midi.quantize for MIDI clips"), std::vector<DalnokClipId>{};
    if (src->slot >= 0 || src->alt || src->folder != 0) return fail(err, "only arrangement clips outside take folders can be quantized"), std::vector<DalnokClipId>{};
    const ClipState c = *src;
    const PoolEntry *pe = poolEntry(c.media);
    if (!pe || !pe->handle->impl) return fail(err, "the clip's audio is offline"), std::vector<DalnokClipId>{};
    const int64_t mediaFrames = pe->handle->impl->frames();
    const double sr = static_cast<double>(pe->handle->impl->sampleRate());
    const auto transients = audioTransients(id, sensitivity, err);
    if (!err.empty()) return {};

    // Times: source frames -> the clip's timeline (at its current rate) -> the grid.
    const double rate0 = c.rate;
    const auto toTimeline = [&](double s) { return static_cast<double>(c.start) + (s - static_cast<double>(c.offset)) / rate0; };
    const int64_t pre = std::llround(sr * 0.006);  // the cut sits this far before the attack (source frames)
    const int64_t fade = std::llround(sr * 0.0025); // crossfade at each cut (timeline frames)
    const int64_t minSeg = std::llround(sr * 0.02);
    const int64_t srcEnd = c.offset + c.sourceLength();
    struct Anchor { int64_t cut; double target; }; // source frame of the cut, its timeline frame after quantizing
    std::vector<Anchor> anchors;
    anchors.push_back({c.offset, static_cast<double>(c.start)});
    bool firstMoves = false; // a transient at the clip's start moves the start with it
    for (int64_t a : transients) {
        const double at = toTimeline(static_cast<double>(a));
        double beat;
        int64_t grid;
        if (!map_.frameToBeat(static_cast<int64_t>(std::llround(at)), beat) ||
            !map_.beatToFrame(std::round(beat / gridBeats) * gridBeats, grid)) continue;
        const double target = at + (static_cast<double>(grid) - at) * strength;
        const int64_t cut = std::max(c.offset, a - pre);
        const double cutTarget = target - static_cast<double>(a - cut) / rate0;
        if (a - c.offset < minSeg + pre) { // at the very start: the slice starts here and moves with its transient
            if (anchors.size() == 1 && !firstMoves && cutTarget >= 0) {
                anchors[0] = {c.offset, cutTarget - static_cast<double>(cut - c.offset) / rate0};
                firstMoves = true;
            }
            continue;
        }
        if (srcEnd - cut < minSeg) continue; // too near the end to make a slice
        const Anchor &p = anchors.back();
        const double srcSpan = static_cast<double>(cut - p.cut), tlSpan = cutTarget - p.target;
        // Keep timing sane: slices stretch at most 2x either way, and transients keep their order.
        if (cut - p.cut < minSeg || tlSpan < static_cast<double>(minSeg) / 2 || srcSpan / tlSpan / rate0 > 2.0 || srcSpan / tlSpan / rate0 < 0.5)
            continue;
        anchors.push_back({cut, cutTarget});
    }
    const double endTarget = static_cast<double>(c.start + c.length);
    while (anchors.size() > 1) { // the last slice must still fit before the clip's (fixed) end
        const double srcSpan = static_cast<double>(srcEnd - anchors.back().cut), tlSpan = endTarget - anchors.back().target;
        if (tlSpan >= static_cast<double>(minSeg) / 2 && srcSpan / tlSpan / rate0 <= 2.0 && srcSpan / tlSpan / rate0 >= 0.5) break;
        anchors.pop_back();
    }
    if (anchors.size() == 1 && !firstMoves) return fail(err, "no transients to quantize"), std::vector<DalnokClipId>{};

    // Each slice: a head played as it is (the attack) and, when the slice must change length, a stretched tail. Every
    // piece after the first runs on under the next piece's fade-in (later pieces lie on top: the crossfade).
    std::vector<ClipState> slices;
    const int64_t headMax = std::llround(sr * 0.05);
    auto piece = [&](int64_t t0, int64_t s0, int64_t len, double rate, bool fadeInHere, bool runOn) {
        ClipState s = c;
        s.start = t0;
        s.offset = s0;
        s.rate = rate;
        s.fadeIn = slices.empty() ? c.fadeIn : (fadeInHere ? fade : 0);
        s.fadeOut = 0;
        s.fadeCurve = slices.empty() ? c.fadeCurve : 0;
        if (rate != 1.0) s.preservePitch = s.preservePitch || std::fabs(rate0 - 1.0) < 1e-9; // keep pitch unless varispeed
        if (runOn) { // as far as the source allows
            const double room = static_cast<double>(mediaFrames - s0) / rate - static_cast<double>(len);
            len += std::clamp<int64_t>(static_cast<int64_t>(room), 0, fade);
        }
        s.length = std::max<int64_t>(1, len);
        slices.push_back(std::move(s));
    };
    for (size_t k = 0; k < anchors.size(); ++k) {
        const bool last = k + 1 == anchors.size();
        const int64_t s0 = anchors[k].cut, s1 = last ? srcEnd : anchors[k + 1].cut;
        const int64_t t0 = std::llround(anchors[k].target), t1 = last ? c.start + c.length : std::llround(anchors[k + 1].target);
        if (t0 < 0) return fail(err, "the quantized clip would start before the timeline"), std::vector<DalnokClipId>{};
        const int64_t srcLen = s1 - s0, tlLen = std::max<int64_t>(1, t1 - t0);
        const bool plain = std::fabs(rate0 - 1.0) < 1e-9 && c.pitch == 0;
        // Barely moved: the whole slice as it is, when the timing error stays inside the crossfade.
        if (plain && std::llabs(srcLen - tlLen) < fade / 2) {
            piece(t0, s0, last ? std::min(tlLen, mediaFrames - s0) : srcLen, 1.0, true, !last); // the clip's end stays put
            if (last) slices.back().fadeOut = c.fadeOut, slices.back().fadeCurve = c.fadeCurve;
            continue;
        }
        // The head keeps the attack; the tail (at least as long as the head) takes up the difference.
        const int64_t head = plain ? std::min<int64_t>(headMax, std::min(srcLen, tlLen) / 3) : 0;
        if (head > 0) piece(t0, s0, head, 1.0, true, true);
        const int64_t ts0 = s0 + head, tt0 = t0 + head;
        const double rate = static_cast<double>(srcLen - head) / static_cast<double>(tlLen - head); // source per timeline frame
        piece(tt0, ts0, tlLen - head, rate, true, !last);
        if (last) slices.back().fadeOut = c.fadeOut, slices.back().fadeCurve = c.fadeCurve;
    }
    for (const auto &s : slices)
        if (s.offset + s.sourceLength() > mediaFrames + 1) return fail(err, "a slice runs past the clip's audio"), std::vector<DalnokClipId>{};

    const DalnokClipId first = nextClip_;
    const bool ok = edit("Quantize Audio", true, [&](Model &m) {
        auto it = std::find_if(m.clips.begin(), m.clips.end(), [id](const ClipState &x) { return x.id == id; });
        if (it == m.clips.end()) return fail(err, "no such clip");
        const std::string name = it->name;
        m.clips.erase(it);
        DalnokClipId next = first;
        for (auto &s : slices) { s.id = next++; s.name = name; m.clips.push_back(s); } // later slices on top (crossfades)
        return true;
    });
    if (!ok) return {};
    nextClip_ = first + static_cast<DalnokClipId>(slices.size());
    std::vector<DalnokClipId> out;
    for (size_t i = 0; i < slices.size(); ++i) out.push_back(first + static_cast<DalnokClipId>(i));
    return out;
}

} // namespace dalnok
