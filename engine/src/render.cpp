// SPDX-License-Identifier: GPL-3.0-or-later
#include "render.hpp"

#include <algorithm>
#include <cmath>

namespace dalnok {

namespace {

void clear(float *p, int n) DALNOK_NONBLOCKING {
    for (int i = 0; i < n; ++i) p[i] = 0.0f;
}

// Constant-power law compensated to unity at center (+3 dB at the extremes),
// approximated with a quarter-sine polynomial so it stays provably
// non-blocking (libm calls are not annotated). Max error ~1e-4.
float quarterSin(float x) DALNOK_NONBLOCKING { // x in [0, pi/2]
    const float x2 = x * x;
    return x * (1.0f - x2 / 6.0f * (1.0f - x2 / 20.0f * (1.0f - x2 / 42.0f * (1.0f - x2 / 72.0f))));
}

void panGains(const TrackRuntime &rt, bool mono, float &gl, float &gr) DALNOK_NONBLOCKING {
    const float g = rt.muted.load(std::memory_order_relaxed) ? 0.0f : rt.gain.load(std::memory_order_relaxed);
    const float p = std::clamp(rt.pan.load(std::memory_order_relaxed), -1.0f, 1.0f);
    if (mono) {
        constexpr float kHalfPi = 1.57079632679f, kSqrt2 = 1.41421356237f;
        const float theta = (p + 1.0f) * 0.5f * kHalfPi;
        gl = g * kSqrt2 * quarterSin(kHalfPi - theta);
        gr = g * kSqrt2 * quarterSin(theta);
    } else {
        gl = g * (p > 0.0f ? 1.0f - p : 1.0f);
        gr = g * (p < 0.0f ? 1.0f + p : 1.0f);
    }
}

void mixClip(const RenderClip &clip, int64_t pos, int frames, float *l, float *r) DALNOK_NONBLOCKING {
    const int64_t a = std::max(pos, clip.start);
    const int64_t e = std::min(pos + frames, clip.start + clip.length);
    if (a >= e) return;
    const Media &m = *clip.media;
    const int64_t src = clip.offset + (a - clip.start);
    const int n = static_cast<int>(e - a);
    const int o = static_cast<int>(a - pos);
    const float *sl = m.channel(0) + src;
    const float *sr = m.channelCount() > 1 ? m.channel(1) + src : sl;
    // Overwrite, not add: the top-most overlapping clip wins (z-order).
    for (int i = 0; i < n; ++i) {
        l[o + i] = sl[i];
        r[o + i] = sr[i];
    }
}

} // namespace

void renderBlock(const RenderState &state, int64_t pos, int frames, float *left, float *right,
                 Scratch &s, bool smooth) DALNOK_NONBLOCKING {
    clear(left, frames);
    clear(right, frames);
    for (const RenderTrack &t : state.tracks) {
        TrackRuntime &rt = *t.runtime;
        float gl, gr;
        panGains(rt, t.monoSource, gl, gr);

        bool any = false;
        for (const RenderClip &c : t.clips) {
            if (c.start >= pos + frames || c.start + c.length <= pos) continue;
            if (!any) {
                clear(s.trackL, frames);
                clear(s.trackR, frames);
                any = true;
            }
            mixClip(c, pos, frames, s.trackL, s.trackR);
        }

        if (!smooth) {
            if (any)
                for (int i = 0; i < frames; ++i) {
                    left[i] += s.trackL[i] * gl;
                    right[i] += s.trackR[i] * gr;
                }
            continue;
        }

        if (!rt.primed) {
            rt.curL = gl;
            rt.curR = gr;
            rt.primed = true;
        }
        // Linear ramp from the previous block's gain to the new target.
        const float dl = (gl - rt.curL) / static_cast<float>(frames);
        const float dr = (gr - rt.curR) / static_cast<float>(frames);
        if (any) {
            float cl = rt.curL, cr = rt.curR, pl = 0, pr = 0;
            for (int i = 0; i < frames; ++i) {
                cl += dl;
                cr += dr;
                const float vl = s.trackL[i] * cl, vr = s.trackR[i] * cr;
                left[i] += vl;
                right[i] += vr;
                pl = std::max(pl, std::fabs(vl));
                pr = std::max(pr, std::fabs(vr));
            }
            raisePeak(rt.peakL, pl);
            raisePeak(rt.peakR, pr);
        }
        rt.curL = gl;
        rt.curR = gr;
    }
}

} // namespace dalnok
