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

void panGains(const TrackRuntime &rt, bool mono, bool anySolo, float &gl, float &gr) DALNOK_NONBLOCKING {
    const bool silent = rt.muted.load(std::memory_order_relaxed) || (anySolo && !rt.solo.load(std::memory_order_relaxed));
    const float g = silent ? 0.0f : rt.gain.load(std::memory_order_relaxed);
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

float fadeShape(float x, int32_t curve) DALNOK_NONBLOCKING { // x in [0, 1]
    return curve == kFadeEqualPower ? quarterSin(x * 1.57079632679f) : x;
}

// A clip covers whatever is beneath it on the same track with weight `env`
// (its fade envelope). Inside the body env = 1: the top clip wins outright.
// Where the top clip fades over a lower clip, the result is a crossfade:
//   out = under * w + clip * env,  w = 1 - env (linear) or sqrt(1 - env^2) (equal power).
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
    const int64_t t0 = a - clip.start, len = clip.length;
    const bool faded = t0 < clip.fadeIn || t0 + n > len - clip.fadeOut;
    const float g = clip.gain;
    if (!faded) {
        for (int i = 0; i < n; ++i) {
            l[o + i] = sl[i] * g;
            r[o + i] = sr[i] * g;
        }
        return;
    }
    for (int i = 0; i < n; ++i) {
        const int64_t t = t0 + i;
        float env = 1.0f;
        if (t < clip.fadeIn)
            env *= fadeShape((static_cast<float>(t) + 0.5f) / static_cast<float>(clip.fadeIn), clip.curve);
        if (t >= len - clip.fadeOut)
            env *= fadeShape((static_cast<float>(len - t) - 0.5f) / static_cast<float>(clip.fadeOut), clip.curve);
        const float under = clip.curve == kFadeEqualPower ? __builtin_sqrtf(std::max(0.0f, 1.0f - env * env))
                                                          : 1.0f - env;
        l[o + i] = l[o + i] * under + sl[i] * g * env;
        r[o + i] = r[o + i] * under + sr[i] * g * env;
    }
}

} // namespace

namespace {
// Plays a track's notes for [pos, pos + frames) into out (mono, overwritten).
// Returns false if nothing sounded.
bool renderNotes(const RenderTrack &t, const SynthParams &p, SynthState &synth, int64_t pos, int frames,
                 float *out) DALNOK_NONBLOCKING {
    if (synth.expected != pos) synth.reset(); // seek: notes are not chased
    synth.expected = pos + frames;
    const auto first = std::lower_bound(t.notes.begin(), t.notes.end(), pos,
                                        [](const RenderNote &n, int64_t at) DALNOK_NONBLOCKING { return n.start < at; });
    if (!synth.active() && (first == t.notes.end() || first->start >= pos + frames)) return false;
    clear(out, frames);
    int done = 0;
    for (auto it = first; it != t.notes.end() && it->start < pos + frames; ++it) {
        const int at = static_cast<int>(it->start - pos);
        if (at > done) { synth.render(p, out + done, at - done, pos + done); done = at; }
        synth.noteOn(p, it->pitch, it->velocity, it->end);
    }
    if (frames > done) synth.render(p, out + done, frames - done, pos + done);
    return true;
}
} // namespace

void renderLiveInput(const RenderState &state, int frames, float *left, float *right, Scratch &s,
                     bool anySolo) DALNOK_NONBLOCKING {
    if (state.liveTrack < 0 || state.liveTrack >= static_cast<int32_t>(state.tracks.size())) return;
    const RenderTrack &t = state.tracks[static_cast<size_t>(state.liveTrack)];
    TrackRuntime &rt = *t.runtime;
    if (!rt.live.active()) return;
    clear(s.trackL, frames);
    rt.live.render(state.synth, s.trackL, frames, -1);
    float gl, gr;
    panGains(rt, true, anySolo, gl, gr);
    float pl = 0, pr = 0;
    for (int i = 0; i < frames; ++i) {
        const float vl = s.trackL[i] * gl, vr = s.trackL[i] * gr;
        left[i] += vl;
        right[i] += vr;
        pl = std::max(pl, std::fabs(vl));
        pr = std::max(pr, std::fabs(vr));
    }
    raisePeak(rt.peakL, pl);
    raisePeak(rt.peakR, pr);
}

void renderBlock(const RenderState &state, int64_t pos, int frames, float *left, float *right,
                 Scratch &s, bool smooth, bool anySolo, SynthState *synths) DALNOK_NONBLOCKING {
    clear(left, frames);
    clear(right, frames);
    size_t index = 0;
    for (const RenderTrack &t : state.tracks) {
        TrackRuntime &rt = *t.runtime;
        SynthState &synth = synths ? synths[index] : rt.play;
        ++index;
        float gl, gr;
        panGains(rt, t.monoSource, anySolo, gl, gr);

        bool any = false;
        if (t.instrument && renderNotes(t, state.synth, synth, pos, frames, s.trackL)) {
            for (int i = 0; i < frames; ++i) s.trackR[i] = s.trackL[i];
            any = true;
        }
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
