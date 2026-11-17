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
// Timeline notes (and live notes) for a plugin instrument in [pos, pos + frames), in time order.
// `starts` and `ends` are the same notes sorted by start and by end (may be empty).
void renderPluginNotes(PluginProcessor *plugin, const RenderNote *starts, const RenderNote *ends, size_t noteCount,
                       SynthState &state, int64_t pos, int frames, Scratch &s) DALNOK_NONBLOCKING {
    int count = 0;
    constexpr int cap = static_cast<int>(sizeof(s.events) / sizeof(s.events[0]));
    auto push = [&](int offset, bool on, uint8_t pitch, uint8_t velocity) DALNOK_NONBLOCKING {
        if (count < cap) s.events[count++] = PluginNote{offset, static_cast<uint8_t>(on ? 1 : 0), pitch, velocity};
    };
    if (state.pluginExpected != pos) { // seek or first block: end everything this render started
        for (int p = 0; p < 128; ++p)
            if (state.pluginHeld[static_cast<size_t>(p)]) { push(0, false, static_cast<uint8_t>(p), 0); state.pluginHeld[static_cast<size_t>(p)] = 0; }
    }
    state.pluginExpected = pos + frames;
    const auto end = pos + frames;
    for (auto it = std::lower_bound(ends, ends + noteCount, pos,
                                    [](const RenderNote &n, int64_t at) DALNOK_NONBLOCKING { return n.end < at; });
         it != ends + noteCount && it->end < end; ++it) {
        auto &held = state.pluginHeld[it->pitch];
        if (held) { --held; push(static_cast<int>(it->end - pos), false, it->pitch, 0); }
    }
    for (auto it = std::lower_bound(starts, starts + noteCount, pos,
                                    [](const RenderNote &n, int64_t at) DALNOK_NONBLOCKING { return n.start < at; });
         it != starts + noteCount && it->start < end; ++it) {
        auto &held = state.pluginHeld[it->pitch];
        if (held < 255) ++held;
        push(static_cast<int>(it->start - pos), true, it->pitch, it->velocity);
    }
    for (int i = 0; i < s.liveNoteCount; ++i) push(s.liveNotes[i].offset, s.liveNotes[i].on, s.liveNotes[i].pitch, s.liveNotes[i].velocity);
    // Stable insertion sort by offset; at equal offsets note-offs come first.
    for (int i = 1; i < count; ++i) {
        const PluginNote e = s.events[i];
        int j = i - 1;
        while (j >= 0 && (s.events[j].offset > e.offset || (s.events[j].offset == e.offset && s.events[j].on && !e.on))) {
            s.events[j + 1] = s.events[j];
            --j;
        }
        s.events[j + 1] = e;
    }
    clear(s.trackL, frames);
    clear(s.trackR, frames);
    plugin->process(s.trackL, s.trackR, frames, s.events, count);
}

void runInserts(const RenderTrack &t, int frames, Scratch &s) DALNOK_NONBLOCKING {
    for (PluginProcessor *p : t.inserts) p->process(s.trackL, s.trackR, frames, nullptr, 0);
}
} // namespace

void renderLiveInput(const RenderState &state, int frames, float *left, float *right, Scratch &s,
                     bool anySolo, bool transportStopped) DALNOK_NONBLOCKING {
    if (state.liveTrack < 0 || state.liveTrack >= static_cast<int32_t>(state.tracks.size())) return;
    const RenderTrack &t = state.tracks[static_cast<size_t>(state.liveTrack)];
    TrackRuntime &rt = *t.runtime;
    bool stereo = false;
    if (t.instrumentPlugin) {
        // A plugin instrument plays live input through renderBlock while the transport rolls.
        if (!transportStopped) return;
        // No timeline notes while stopped; the live notes are in the scratch. The timeline voice state
        // (rt.play) is left alone: resuming playback releases what the timeline started.
        SynthState idle;
        idle.pluginExpected = 0;
        renderPluginNotes(t.instrumentPlugin, nullptr, nullptr, 0, idle, 0, frames, s);
        runInserts(t, frames, s);
        stereo = true;
    } else {
        if (!rt.live.active()) return;
        clear(s.trackL, frames);
        rt.live.render(state.synth, s.trackL, frames, -1);
        if (!t.inserts.empty()) {
            if (!transportStopped) return; // live input already went through the inserts in renderBlock
            for (int i = 0; i < frames; ++i) s.trackR[i] = s.trackL[i];
            runInserts(t, frames, s);
            stereo = true;
        }
    }
    float gl, gr;
    panGains(rt, !t.instrumentPlugin, anySolo, gl, gr); // same pan law as renderBlock
    float pl = 0, pr = 0;
    for (int i = 0; i < frames; ++i) {
        const float vl = s.trackL[i] * gl, vr = (stereo ? s.trackR[i] : s.trackL[i]) * gr;
        left[i] += vl;
        right[i] += vr;
        pl = std::max(pl, std::fabs(vl));
        pr = std::max(pr, std::fabs(vr));
    }
    raisePeak(rt.peakL, pl);
    raisePeak(rt.peakR, pr);
}

namespace {
// Linear interpolation over breakpoints; held flat before the first and after the last point.
float autoAt(const std::vector<std::pair<int64_t, float>> &pts, int64_t frame) DALNOK_NONBLOCKING {
    if (frame <= pts.front().first) return pts.front().second;
    if (frame >= pts.back().first) return pts.back().second;
    size_t lo = 0, hi = pts.size() - 1;
    while (hi - lo > 1) { const size_t mid = (lo + hi) / 2; (pts[mid].first <= frame ? lo : hi) = mid; }
    const auto &a = pts[lo], &b = pts[hi];
    const float t = static_cast<float>(frame - a.first) / static_cast<float>(b.first - a.first);
    return a.second + (b.second - a.second) * t;
}

// Fader and pan gains at a frame for an automated track (mute and solo still apply).
void autoGains(const RenderTrack &t, const TrackRuntime &rt, bool mono, bool anySolo, int64_t frame,
               float &gl, float &gr) DALNOK_NONBLOCKING {
    const bool silent = rt.muted.load(std::memory_order_relaxed) || (anySolo && !rt.solo.load(std::memory_order_relaxed));
    float g = rt.gain.load(std::memory_order_relaxed);
    if (!t.volumeAuto.empty()) { const float v = autoAt(t.volumeAuto, frame); g = v * v * v * v; }
    if (silent) g = 0;
    const float p = std::clamp(t.panAuto.empty() ? rt.pan.load(std::memory_order_relaxed) : autoAt(t.panAuto, frame), -1.0f, 1.0f);
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
} // namespace

void renderBlock(const RenderState &state, int64_t pos, int frames, float *left, float *right,
                 Scratch &s, bool smooth, bool anySolo, SynthState *synths) DALNOK_NONBLOCKING {
    clear(left, frames);
    clear(right, frames);
    float *busL = state.busL.data(), *busR = state.busR.data();
    const size_t busCount = state.busL.size() / kMaxBlock;
    for (size_t b = 0; b < busCount; ++b) { clear(busL + b * kMaxBlock, frames); clear(busR + b * kMaxBlock, frames); }
    size_t index = 0;
    for (const RenderTrack &t : state.tracks) {
        TrackRuntime &rt = *t.runtime;
        SynthState &synth = synths ? synths[index] : rt.play;
        ++index;
        // Solo follows routing: a soloed bus keeps what feeds it audible, and a soloed source keeps its buses.
        bool linkedSolo = false;
        for (const TrackRuntime *l : t.soloLinks) linkedSolo = linkedSolo || l->solo.load(std::memory_order_relaxed);
        float gl, gr;
        // A mono source keeps its pan law through inserts, so a passthrough insert is transparent;
        // plugin instruments and buses are stereo sources (balance).
        panGains(rt, t.monoSource && !t.instrumentPlugin, anySolo && !linkedSolo, gl, gr);

        bool any = false;
        if (t.bus) {
            const float *inL = busL + static_cast<size_t>(t.busSlot) * kMaxBlock, *inR = busR + static_cast<size_t>(t.busSlot) * kMaxBlock;
            for (int i = 0; i < frames; ++i) { s.trackL[i] = inL[i]; s.trackR[i] = inR[i]; }
            any = true;
        } else if (t.instrumentPlugin) {
            // Plugin instruments run every block (tails, internal state); live notes join on the live track.
            const bool liveHere = !synths && static_cast<int32_t>(index - 1) == state.liveTrack;
            const PluginNote *live = s.liveNotes;
            const int liveCount = s.liveNoteCount;
            if (!liveHere) { s.liveNotes = nullptr; s.liveNoteCount = 0; }
            renderPluginNotes(t.instrumentPlugin, t.notes.data(), t.noteEnds.data(), t.notes.size(), synth, pos, frames, s);
            s.liveNotes = live;
            s.liveNoteCount = liveCount;
            any = true;
        } else if (t.instrument && renderNotes(t, state.synth, synth, pos, frames, s.trackL)) {
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
        if (!t.inserts.empty()) {
            if (!any) { clear(s.trackL, frames); clear(s.trackR, frames); any = true; }
            // Live input on a built-in-synth track with inserts goes through the inserts too.
            if (!synths && static_cast<int32_t>(index - 1) == state.liveTrack && !t.instrumentPlugin && rt.live.active()) {
                clear(s.tmp, frames);
                rt.live.render(state.synth, s.tmp, frames, -1);
                for (int i = 0; i < frames; ++i) { s.trackL[i] += s.tmp[i]; s.trackR[i] += s.tmp[i]; }
            }
            runInserts(t, frames, s); // every block, so reverb and delay tails continue after clips end
        }

        // Pre-fader sends take the signal before the fader and pan (still silenced by mute and solo).
        if (any) {
            const bool silent = rt.muted.load(std::memory_order_relaxed) ||
                                (anySolo && !linkedSolo && !rt.solo.load(std::memory_order_relaxed));
            for (const RenderSend &snd : t.sends) {
                if (!snd.pre || silent || snd.slot < 0) continue;
                float *dl = busL + static_cast<size_t>(snd.slot) * kMaxBlock, *dr = busR + static_cast<size_t>(snd.slot) * kMaxBlock;
                for (int i = 0; i < frames; ++i) { dl[i] += s.trackL[i] * snd.gain; dr[i] += s.trackR[i] * snd.gain; }
            }
        }
        float *outL = t.output < 0 ? left : busL + static_cast<size_t>(t.output) * kMaxBlock;
        float *outR = t.output < 0 ? right : busR + static_cast<size_t>(t.output) * kMaxBlock;
        // Post-fader sends receive the faded, panned signal.
        auto postSends = [&](int i, float vl, float vr) DALNOK_NONBLOCKING {
            for (const RenderSend &snd : t.sends) {
                if (snd.pre || snd.slot < 0) continue;
                busL[static_cast<size_t>(snd.slot) * kMaxBlock + static_cast<size_t>(i)] += vl * snd.gain;
                busR[static_cast<size_t>(snd.slot) * kMaxBlock + static_cast<size_t>(i)] += vr * snd.gain;
            }
        };
        // Automated volume or pan: 32-sample linear ramps between exact automation values (same live and offline).
        if (!t.volumeAuto.empty() || !t.panAuto.empty()) {
            const bool mono = t.monoSource && !t.instrumentPlugin, solo = anySolo && !linkedSolo;
            // Ramps run between exact values on a fixed 32-frame grid of the timeline, so every sample depends only
            // on its position: live playback (any block size) and exports produce the same samples.
            float pl = 0, pr = 0, al = 0, ar = 0;
            for (int i0 = 0; i0 < frames;) {
                const int64_t f = pos + i0, g0 = f - ((f % 32) + 32) % 32;
                const int n = static_cast<int>(std::min<int64_t>(frames - i0, g0 + 32 - f));
                float l0, r0, l1, r1;
                autoGains(t, rt, mono, solo, g0, l0, r0);
                autoGains(t, rt, mono, solo, g0 + 32, l1, r1);
                const float sl = (l1 - l0) / 32.0f, sr = (r1 - r0) / 32.0f;
                for (int k = 0; k < n && any; ++k) {
                    const int i = i0 + k;
                    const float off = static_cast<float>(f - g0 + k);
                    const float vl = s.trackL[i] * (l0 + sl * off), vr = s.trackR[i] * (r0 + sr * off);
                    outL[i] += vl;
                    outR[i] += vr;
                    postSends(i, vl, vr);
                    pl = std::max(pl, std::fabs(vl));
                    pr = std::max(pr, std::fabs(vr));
                }
                const float end = static_cast<float>(f - g0 + n);
                al = l0 + sl * end;
                ar = r0 + sr * end;
                i0 += n;
            }
            if (smooth) {
                raisePeak(rt.peakL, pl);
                raisePeak(rt.peakR, pr);
                rt.curL = al; rt.curR = ar; rt.primed = true; // leaving automation continues from here
            }
            continue;
        }

        if (!smooth) {
            if (any)
                for (int i = 0; i < frames; ++i) {
                    const float vl = s.trackL[i] * gl, vr = s.trackR[i] * gr;
                    outL[i] += vl;
                    outR[i] += vr;
                    postSends(i, vl, vr);
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
                outL[i] += vl;
                outR[i] += vr;
                postSends(i, vl, vr);
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
