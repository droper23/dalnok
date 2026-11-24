// SPDX-License-Identifier: GPL-3.0-or-later
#include "render.hpp"
#include "vec.hpp"

#include <algorithm>
#include <cmath>

namespace dalnok {

namespace {

void clear(float *p, int n) DALNOK_NONBLOCKING {
    for (int i = 0; i < n; ++i) p[i] = 0.0f;
}

// Block meters (A-13). The meter's DC tracker (meterLevel's one-pole, k = 5e-4) ran per sample, a serial recursion
// that kept the fader loop of every track from vectorizing. Per block: the peak is measured against the tracker's
// value at the block start, and the tracker advances by the same recursion in closed form,
//   dc_n = a^n dc_0 + k sum(a^(n-1-i) v_i),  a = 1 - k,
// as a dot product with precomputed weights. Only what the meter shows changes (by at most k of a sample), never
// the audio.
struct MeterTables {
    static constexpr float k = 5e-4f;
    float decay[kMaxBlock + 1]; // a^n
    float weight[kMaxBlock];    // weight[m] = k a^(kMaxBlock - 1 - m): a block of n uses weight + kMaxBlock - n
    MeterTables() {
        for (int n = 0; n <= kMaxBlock; ++n) decay[n] = static_cast<float>(std::pow(1.0 - k, n));
        for (int m = 0; m < kMaxBlock; ++m) weight[m] = static_cast<float>(k * std::pow(1.0 - k, kMaxBlock - 1 - m));
    }
};
const MeterTables kMeterTables; // built at load, never on the audio thread

float blockMeter(const float *v, int n, float &dc) DALNOK_NONBLOCKING {
    if (n <= 0) return 0.0f;
    if (n > kMaxBlock) { // never happens (blocks are split to kMaxBlock); keep the per-sample form for safety
        float p = 0;
        for (int i = 0; i < n; ++i) p = std::max(p, meterLevel(v[i], dc));
        return p;
    }
    float lo, hi;
    vec::minMax(v, n, lo, hi);
    const float raw = std::max(std::fabs(hi), std::fabs(lo)); // full scale or over reads as itself (see meterLevel)
    const float peak = raw >= 1.0f ? raw : std::max(std::fabs(hi - dc), std::fabs(lo - dc));
    dc = kMeterTables.decay[n] * dc + vec::dot(v, kMeterTables.weight + (kMaxBlock - n), n);
    return peak;
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
    // Streamed media (A-09): copy from the stream cache's resident blocks; a block not loaded in time plays silence.
    float streamL[kMaxBlock], streamR[kMaxBlock];
    const float *sl, *sr;
    if (m.streamed()) {
        m.readResident(src, n, streamL, streamR);
        sl = streamL;
        sr = streamR;
    } else {
        sl = m.channel(0) + src;
        sr = m.channelCount() > 1 ? m.channel(1) + src : sl;
    }
    const int64_t t0 = a - clip.start, len = clip.length;
    const bool faded = t0 < clip.fadeIn || t0 + n > len - clip.fadeOut;
    const float g = clip.gain;
    if (!faded) {
        vec::scale(sl, g, l + o, n);
        vec::scale(sr, g, r + o, n);
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
bool renderNotes(const std::vector<RenderNote> &notes, const SynthParams &p, SynthState &synth, int64_t pos, int frames,
                 float *out, const std::vector<RenderCC> *ccs = nullptr) DALNOK_NONBLOCKING {
    if (synth.expected != pos) synth.reset(); // seek: notes are not chased
    synth.expected = pos + frames;
    const auto first = std::lower_bound(notes.begin(), notes.end(), pos,
                                        [](const RenderNote &n, int64_t at) DALNOK_NONBLOCKING { return n.start < at; });
    auto cc = ccs ? std::lower_bound(ccs->begin(), ccs->end(), pos, [](const RenderCC &c, int64_t at) DALNOK_NONBLOCKING { return c.at < at; })
                  : std::vector<RenderCC>::const_iterator{};
    const bool anyCC = ccs && cc != ccs->end() && cc->at < pos + frames;
    if (!synth.active() && !anyCC && (first == notes.end() || first->start >= pos + frames)) return false;
    clear(out, frames);
    int done = 0;
    // Controllers at a frame come before the notes starting there (a note starts with its bend already set).
    auto controllersUntil = [&](int64_t until) DALNOK_NONBLOCKING {
        for (; ccs && cc != ccs->end() && cc->at < until; ++cc) {
            const int at = static_cast<int>(cc->at - pos);
            if (at > done) { synth.render(p, out + done, at - done, pos + done); done = at; }
            if (cc->kind == kEventPitchBend) synth.pitchBend(cc->d1 | (cc->d2 << 7));
            else synth.control(p, cc->d1, cc->d2);
        }
    };
    for (auto it = first; it != notes.end() && it->start < pos + frames; ++it) {
        controllersUntil(it->start + 1);
        const int at = static_cast<int>(it->start - pos);
        if (at > done) { synth.render(p, out + done, at - done, pos + done); done = at; }
        synth.noteOn(p, it->pitch, it->velocity, it->end);
    }
    controllersUntil(pos + frames);
    if (frames > done) synth.render(p, out + done, frames - done, pos + done);
    return true;
}
// Timeline notes (and live notes) for a plugin instrument in [pos, pos + frames), in time order.
// `starts` and `ends` are the same notes sorted by start and by end (may be empty).
// Starts the instrument's block into outL/outR; returns true while its result is still to come (an isolated plug-in:
// finishProcess, then afterPlugin). In-process instruments are done on return (afterPlugin has run).
bool renderPluginNotes(PluginProcessor *plugin, const RenderNote *starts, const RenderNote *ends, size_t noteCount,
                       SynthState &state, int64_t pos, int frames, Scratch &s, float *outL, float *outR,
                       const RenderCC *ccs = nullptr, size_t ccCount = 0) DALNOK_NONBLOCKING;
void afterPlugin(PluginProcessor *p, const float *l, const float *r, int frames) DALNOK_NONBLOCKING {
    raisePeaks(p->meterOut, l, r, frames);
    if (PluginProcessor::Tap *tap = p->tap.load(std::memory_order_acquire)) {
        writeTapStereo(*tap, l, r, frames);
        writeTap(tap->out, tap->pos, l, r, frames, true);
    }
}
void beforeInsert(PluginProcessor *p, const float *l, const float *r, int frames) DALNOK_NONBLOCKING {
    raisePeaks(p->meterIn, l, r, frames);
    if (PluginProcessor::Tap *tap = p->tap.load(std::memory_order_acquire)) writeTap(tap->in, tap->pos, l, r, frames, false);
}
bool renderPluginNotes(PluginProcessor *plugin, const RenderNote *starts, const RenderNote *ends, size_t noteCount,
                       SynthState &state, int64_t pos, int frames, Scratch &s, float *outL, float *outR,
                       const RenderCC *ccs, size_t ccCount) DALNOK_NONBLOCKING {
    int count = 0;
    constexpr int cap = static_cast<int>(sizeof(s.events) / sizeof(s.events[0]));
    auto push = [&](int offset, uint8_t kind, uint8_t pitch, uint8_t velocity) DALNOK_NONBLOCKING {
        if (count < cap) s.events[count++] = PluginNote{offset, kind, pitch, velocity};
    };
    if (state.pluginExpected != pos) { // seek or first block: end everything this render started
        for (int p = 0; p < 128; ++p)
            if (state.pluginHeld[static_cast<size_t>(p)]) { push(0, kEventNoteOff, static_cast<uint8_t>(p), 0); state.pluginHeld[static_cast<size_t>(p)] = 0; }
        if (ccCount) { // a track with controller events starts from neutral: bend centred, sustain up
            push(0, kEventPitchBend, 0, 64);
            push(0, kEventControl, 64, 0);
        }
    }
    state.pluginExpected = pos + frames;
    const auto end = pos + frames;
    const int cleanupCount = count;
    for (auto it = std::lower_bound(ends, ends + noteCount, pos,
                                    [](const RenderNote &n, int64_t at) DALNOK_NONBLOCKING { return n.end < at; });
         it != ends + noteCount && it->end < end; ++it)
        push(static_cast<int>(it->end - pos), kEventNoteOff, it->pitch, 0);
    for (auto it = std::lower_bound(starts, starts + noteCount, pos,
                                    [](const RenderNote &n, int64_t at) DALNOK_NONBLOCKING { return n.start < at; });
         it != starts + noteCount && it->start < end; ++it)
        push(static_cast<int>(it->start - pos), kEventNoteOn, it->pitch, it->velocity);
    for (auto it = std::lower_bound(ccs, ccs + ccCount, pos, [](const RenderCC &c, int64_t at) DALNOK_NONBLOCKING { return c.at < at; });
         it != ccs + ccCount && it->at < end; ++it)
        push(static_cast<int>(it->at - pos), it->kind, it->d1, it->d2);
    // Sort timeline events before tracking held notes: an onset and its release can share a block. At one frame:
    // note-offs, then controllers (a note starts with its bend and sustain already set), then note-ons.
    auto rank = [](uint8_t kind) DALNOK_NONBLOCKING { return kind == kEventNoteOff ? 0 : kind == kEventNoteOn ? 2 : 1; };
    auto sortEvents = [&](int begin) DALNOK_NONBLOCKING {
        for (int i = begin + 1; i < count; ++i) {
            const PluginNote e = s.events[i];
            int j = i - 1;
            while (j >= begin && (s.events[j].offset > e.offset || (s.events[j].offset == e.offset && rank(s.events[j].on) > rank(e.on)))) {
                s.events[j + 1] = s.events[j];
                --j;
            }
            s.events[j + 1] = e;
        }
    };
    sortEvents(cleanupCount);
    int written = cleanupCount;
    for (int i = cleanupCount; i < count; ++i) {
        const PluginNote e = s.events[i];
        if (e.on == kEventNoteOn || e.on == kEventNoteOff) {
            auto &held = state.pluginHeld[e.pitch];
            if (e.on == kEventNoteOn) { if (held < 255) ++held; }
            else { if (!held) continue; --held; }
        }
        s.events[written++] = e;
    }
    count = written;
    for (int i = 0; i < s.liveNoteCount; ++i) push(s.liveNotes[i].offset, s.liveNotes[i].on, s.liveNotes[i].pitch, s.liveNotes[i].velocity);
    sortEvents(0);
    clear(outL, frames);
    clear(outR, frames);
    plugin->setDeadline(s.deadlineNs, &s.isolatedWaitNs);
    if (plugin->beginProcess(outL, outR, frames, s.events, count)) return true;
    afterPlugin(plugin, outL, outR, frames);
    return false;
}
// Synchronous forms (live input while stopped): wait for an isolated plug-in at once.
void renderPluginNotesNow(PluginProcessor *plugin, const RenderNote *starts, const RenderNote *ends, size_t noteCount,
                          SynthState &state, int64_t pos, int frames, Scratch &s) DALNOK_NONBLOCKING {
    if (renderPluginNotes(plugin, starts, ends, noteCount, state, pos, frames, s, s.trackL, s.trackR)) {
        plugin->finishProcess(s.trackL, s.trackR, frames);
        afterPlugin(plugin, s.trackL, s.trackR, frames);
    }
}
void runInserts(const RenderTrack &t, int frames, Scratch &s) DALNOK_NONBLOCKING {
    for (PluginProcessor *p : t.inserts) {
        beforeInsert(p, s.trackL, s.trackR, frames);
        p->setDeadline(s.deadlineNs, &s.isolatedWaitNs);
        p->process(s.trackL, s.trackR, frames, nullptr, 0);
        afterPlugin(p, s.trackL, s.trackR, frames);
    }
}
} // namespace


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
    if (!t.volumeAuto.empty() && !rt.holdVolume.load(std::memory_order_relaxed)) { const float v = autoAt(t.volumeAuto, frame); g = v * v * v * v; }
    if (silent) g = 0;
    const bool panHeld = rt.holdPan.load(std::memory_order_relaxed);
    const float p = std::clamp(t.panAuto.empty() || panHeld ? rt.pan.load(std::memory_order_relaxed) : autoAt(t.panAuto, frame), -1.0f, 1.0f);
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

namespace {
enum : uint8_t { kStepSource, kStepInstrumentWait, kStepClips, kStepInserts, kStepInsertWait, kStepReady };
}

void renderBlock(const RenderState &state, int64_t pos, int frames, float *left, float *right,
                 Scratch &s, bool smooth, bool anySolo, SynthState *synths) DALNOK_NONBLOCKING {
    clear(left, frames);
    clear(right, frames);
    float *busL = state.busL.data(), *busR = state.busR.data();
    const size_t busCount = state.busL.size() / kMaxBlock;
    for (size_t b = 0; b < busCount; ++b) { clear(busL + b * kMaxBlock, frames); clear(busR + b * kMaxBlock, frames); }
    const size_t count = state.tracks.size();
    if (state.steps.size() < count || state.chainL.size() < count * kMaxBlock) return; // not compiled for rendering
    for (size_t i = 0; i < s.stemTracks; ++i) { clear(s.stemL + i * kMaxBlock, frames); clear(s.stemR + i * kMaxBlock, frames); }
    TrackStep *steps = state.steps.data();
    for (size_t i = 0; i < count; ++i) steps[i] = TrackStep{};

    // Runs track i as far as it can without waiting: its source (bus input, instrument, notes, launcher slot, clips)
    // and its inserts. It stops at an isolated plug-in whose block is in flight (waiting) and resumes after
    // finishPending. Tracks fed by other tracks (buses, sidechain listeners) start only once everything before them
    // in processing order has been delivered (`cursor`). Returns false when it could not move.
    auto advance = [&](size_t i, size_t cursor) DALNOK_NONBLOCKING -> bool {
        const RenderTrack &t = state.tracks[i];
        TrackStep &st = steps[i];
        TrackRuntime &rt = *t.runtime;
        SynthState &synth = synths ? synths[i] : rt.play;
        float *L = state.chainL.data() + i * kMaxBlock, *R = state.chainR.data() + i * kMaxBlock;
        if (st.stage == kStepSource) {
            if ((t.bus || !t.sidechainFeeds.empty()) && i != cursor) return false;
            const bool monitoring = !synths && monitorsInput(t, s);
            const bool liveTrack = !synths && static_cast<int32_t>(i) == s.liveTrack && (t.instrument || t.instrumentPlugin);
            if (s.timelineOff && !t.bus && !monitoring && !liveTrack) {
                // Stopped, monitoring input elsewhere: this track is silent (its plug-ins got their idle call).
                if (t.scSlot >= 0) {
                    clear(state.scL.data() + static_cast<size_t>(t.scSlot) * kMaxBlock, frames);
                    clear(state.scR.data() + static_cast<size_t>(t.scSlot) * kMaxBlock, frames);
                }
                st.stage = kStepReady;
                return true;
            }
            if (synth.mutedMidiSignature != t.mutedMidiSignature) {
                // Stop notes that may have belonged to a newly muted clip, including hosted instruments.
                synth.reset(); synth.pluginExpected = -1; synth.mutedMidiSignature = t.mutedMidiSignature;
            }
            // Solo follows routing: a soloed bus keeps what feeds it audible, and a soloed source keeps its buses.
            for (const TrackRuntime *l : t.soloLinks) st.linkedSolo = st.linkedSolo || l->solo.load(std::memory_order_relaxed);
            // A mono source keeps its pan law through inserts, so a passthrough insert is transparent;
            // plugin instruments and buses are stereo sources (balance).
            panGains(rt, t.monoSource && !t.instrumentPlugin, anySolo && !st.linkedSolo, st.gl, st.gr);
            // Sidechain inputs for this block (their sources were rendered earlier in this block). Every insert is
            // reset first: a disconnected sidechain must hear silence, not a buffer of an earlier (freed) snapshot.
            for (PluginProcessor *p : t.inserts) p->setSidechain(nullptr, nullptr);
            for (const auto &[plugin, idx] : t.sidechainFeeds)
                plugin->setSidechain(state.scL.data() + static_cast<size_t>(idx) * kMaxBlock, state.scR.data() + static_cast<size_t>(idx) * kMaxBlock);
            // Plug-in parameter automation for this block (before the plug-ins run).
            for (const auto &lane : t.pluginAuto) {
                const float v = autoAt(lane.pts, pos);
                lane.plugin->automate(lane.param, lane.lo + static_cast<double>(v) * (lane.hi - lane.lo));
            }
            // Clip launcher (live only): a playing slot replaces this track's timeline clips and notes.
            if (!synths && !s.timelineOff && !t.content->slots.empty()) {
                const int32_t ps = rt.playingSlot.load(std::memory_order_relaxed);
                for (const RenderSlot &sl : t.content->slots) if (sl.slot == ps && sl.length > 0) st.slot = &sl;
            }
            const RenderSlot *slot = st.slot;
            const bool liveHere = !synths && static_cast<int32_t>(i) == s.liveTrack;
            // Plugin instruments: live notes join only on the live track.
            auto instrument = [&](const RenderNote *starts, const RenderNote *ends, size_t n, int64_t at,
                                  const RenderCC *cc = nullptr, size_t ccn = 0) DALNOK_NONBLOCKING -> bool {
                const PluginNote *live = s.liveNotes;
                const int liveCount = s.liveNoteCount;
                if (!liveHere) { s.liveNotes = nullptr; s.liveNoteCount = 0; }
                const bool inflight = renderPluginNotes(t.instrumentPlugin, starts, ends, n, synth, at, frames, s, L, R, cc, ccn);
                s.liveNotes = live;
                s.liveNoteCount = liveCount;
                return inflight;
            };
            bool inflight = false;
            if (s.timelineOff && liveTrack) {
                // Stopped: only live input. The timeline voice state (rt.play) is left alone:
                // resuming playback releases what the timeline started.
                if (t.instrumentPlugin) {
                    SynthState idle;
                    idle.pluginExpected = 0;
                    inflight = renderPluginNotes(t.instrumentPlugin, nullptr, nullptr, 0, idle, 0, frames, s, L, R);
                    st.any = true;
                } else { clear(L, frames); clear(R, frames); st.any = true; } // the built-in synth joins below
                if (inflight) { st.stage = kStepInstrumentWait; st.waiting = true; st.pending = t.instrumentPlugin; return true; }
                st.stage = kStepClips;
            } else if (slot) {
                const int64_t start0 = rt.slotStart.load(std::memory_order_relaxed);
                const int64_t rel = ((pos - start0) % slot->length + slot->length) % slot->length; // block ends by the loop end
                if (slot->muted) {
                    clear(L, frames); clear(R, frames);
                    if (t.instrumentPlugin) inflight = instrument(nullptr, nullptr, 0, rel);
                    st.any = true;
                } else if (slot->hasAudio) {
                    clear(L, frames); clear(R, frames);
                    mixClip(slot->clip, rel, frames, L, R);
                    st.any = true;
                } else if (t.instrumentPlugin) {
                    inflight = instrument(slot->notes.data(), slot->noteEnds.data(), slot->notes.size(), rel);
                    st.any = true;
                } else if (t.instrument && renderNotes(slot->notes, state.synth, synth, rel, frames, L)) {
                    for (int k = 0; k < frames; ++k) R[k] = L[k];
                    st.any = true;
                }
            } else if (t.bus) {
                const float *inL = busL + static_cast<size_t>(t.busSlot) * kMaxBlock, *inR = busR + static_cast<size_t>(t.busSlot) * kMaxBlock;
                for (int k = 0; k < frames; ++k) { L[k] = inL[k]; R[k] = inR[k]; }
                st.any = true;
            } else if (t.instrumentPlugin) {
                // Plugin instruments run every block (tails, internal state).
                inflight = instrument(t.content->notes.data(), t.content->noteEnds.data(), t.content->notes.size(), pos,
                                      t.content->controllers.data(), t.content->controllers.size());
                st.any = true;
            } else if (t.instrument && renderNotes(t.content->notes, state.synth, synth, pos, frames, L, &t.content->controllers)) {
                for (int k = 0; k < frames; ++k) R[k] = L[k];
                st.any = true;
            }
            if (inflight) { st.stage = kStepInstrumentWait; st.waiting = true; st.pending = t.instrumentPlugin; return true; }
            st.stage = kStepClips;
        }
        if (st.stage == kStepClips) {
            for (const RenderClip &c : t.content->clips) {
                if (st.slot || s.timelineOff) break; // the launcher clip plays instead of the arrangement
                if (c.start >= pos + frames || c.start + c.length <= pos) continue;
                if (!st.any) { clear(L, frames); clear(R, frames); st.any = true; }
                mixClip(c, pos, frames, L, R);
            }
            // Input Monitoring: the device input joins the track's source, before its inserts, fader and pan.
            if (!synths && monitorsInput(t, s)) {
                if (!st.any) { clear(L, frames); clear(R, frames); st.any = true; }
                const float *in = s.liveInputs[t.inputChannel];
                for (int k = 0; k < frames; ++k) { L[k] += in[k]; R[k] += in[k]; }
            }
            // Live input on the built-in synth: through the track's inserts, fader and routing like everything else.
            if (!synths && static_cast<int32_t>(i) == s.liveTrack && t.instrument && !t.instrumentPlugin && rt.live.active()) {
                if (!st.any) { clear(L, frames); clear(R, frames); st.any = true; }
                clear(s.tmp, frames);
                rt.live.render(state.synth, s.tmp, frames, -1);
                for (int k = 0; k < frames; ++k) { L[k] += s.tmp[k]; R[k] += s.tmp[k]; }
            }
            if (!t.inserts.empty() && !st.any) { clear(L, frames); clear(R, frames); st.any = true; }
            // Phase invert: the whole source (clips, instrument, bus input, live input) flips before the inserts.
            if (t.invert && st.any) { vec::scale(L, -1.0f, L, frames); vec::scale(R, -1.0f, R, frames); }
            st.stage = kStepInserts;
            st.insert = 0;
        }
        if (st.stage == kStepInserts) {
            // Every block, so reverb and delay tails continue after clips end.
            while (st.insert < static_cast<int32_t>(t.inserts.size())) {
                PluginProcessor *p = t.inserts[static_cast<size_t>(st.insert)];
                beforeInsert(p, L, R, frames);
                p->setDeadline(s.deadlineNs, &s.isolatedWaitNs);
                if (p->beginProcess(L, R, frames, nullptr, 0)) { st.stage = kStepInsertWait; st.waiting = true; st.pending = p; return true; }
                afterPlugin(p, L, R, frames);
                ++st.insert;
            }
            // A sidechain source publishes its post-insert, pre-fader signal (silence when it has none).
            if (t.scSlot >= 0) {
                float *dl = state.scL.data() + static_cast<size_t>(t.scSlot) * kMaxBlock, *dr = state.scR.data() + static_cast<size_t>(t.scSlot) * kMaxBlock;
                if (st.any) for (int k = 0; k < frames; ++k) { dl[k] = L[k]; dr[k] = R[k]; }
                else { clear(dl, frames); clear(dr, frames); }
            }
            st.stage = kStepReady;
            return true;
        }
        return false;
    };

    // Collects the block of the isolated plug-in track i is waiting on, and moves it past that plug-in.
    auto finishPending = [&](size_t i) DALNOK_NONBLOCKING {
        TrackStep &st = steps[i];
        float *L = state.chainL.data() + i * kMaxBlock, *R = state.chainR.data() + i * kMaxBlock;
        st.pending->finishProcess(L, R, frames);
        afterPlugin(st.pending, L, R, frames);
        st.waiting = false;
        st.pending = nullptr;
        if (st.stage == kStepInstrumentWait) st.stage = kStepClips;
        else { ++st.insert; st.stage = kStepInserts; }
    };

    // Fader, pan and automation, then delivery to the output bus or master and to the sends (in processing order).
    auto deliverTrack = [&](size_t i) DALNOK_NONBLOCKING {
        const RenderTrack &t = state.tracks[i];
        TrackStep &st = steps[i];
        TrackRuntime &rt = *t.runtime;
        float *L = state.chainL.data() + i * kMaxBlock, *R = state.chainR.data() + i * kMaxBlock;
        bool any = st.any;
        const bool linkedSolo = st.linkedSolo;
        const float gl = st.gl, gr = st.gr;
        // A track with delay compensation keeps its delay lines running even while silent.
        bool delayed = t.outDelay != nullptr;
        for (const RenderSend &x : t.sends) delayed = delayed || x.delay != nullptr;
        if (delayed && !any) { clear(L, frames); clear(R, frames); any = true; }
        float *outL = t.output < 0 ? left : busL + static_cast<size_t>(t.output) * kMaxBlock;
        float *outR = t.output < 0 ? right : busR + static_cast<size_t>(t.output) * kMaxBlock;
        const bool silentPre = rt.muted.load(std::memory_order_relaxed) ||
                               (anySolo && !linkedSolo && !rt.solo.load(std::memory_order_relaxed));
        // Adds `src * gain` to a destination, through the connection's compensation delay if it has one.
        auto addTo = [&](float *dl, float *dr, const float *srcL, const float *srcR, float gain, DelayLine *delay) DALNOK_NONBLOCKING {
            if (!delay) {
                vec::addScaled(srcL, gain, dl, frames);
                vec::addScaled(srcR, gain, dr, frames);
                return;
            }
            vec::scale(srcL, gain, s.edgeL, frames);
            vec::scale(srcR, gain, s.edgeR, frames);
            delay->process(s.edgeL, s.edgeR, frames);
            vec::addScaled(s.edgeL, 1.0f, dl, frames);
            vec::addScaled(s.edgeR, 1.0f, dr, frames);
        };
        // Delivers the faded signal (s.fade*) to the output and post-fader sends, and the pre-fader signal
        // (the chain buffer, silenced by mute and solo) to pre-fader sends.
        auto deliver = [&]() DALNOK_NONBLOCKING {
            addTo(outL, outR, s.fadeL, s.fadeR, 1.0f, t.outDelay);
            if (i < s.stemTracks) {
                vec::addScaled(s.fadeL, 1.0f, s.stemL + i * kMaxBlock, frames);
                vec::addScaled(s.fadeR, 1.0f, s.stemR + i * kMaxBlock, frames);
            }
            for (const RenderSend &snd : t.sends) {
                if (snd.slot < 0) continue;
                float *dl = busL + static_cast<size_t>(snd.slot) * kMaxBlock, *dr = busR + static_cast<size_t>(snd.slot) * kMaxBlock;
                if (snd.pre) addTo(dl, dr, L, R, silentPre ? 0.0f : snd.gain, snd.delay);
                else addTo(dl, dr, s.fadeL, s.fadeR, snd.gain, snd.delay);
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
                    const int j = i0 + k;
                    const float off = static_cast<float>(f - g0 + k);
                    const float vl = L[j] * (l0 + sl * off), vr = R[j] * (r0 + sr * off);
                    s.fadeL[j] = vl;
                    s.fadeR[j] = vr;
                    pl = std::max(pl, meterLevel(vl, rt.meterDcL));
                    pr = std::max(pr, meterLevel(vr, rt.meterDcR));
                }
                const float end = static_cast<float>(f - g0 + n);
                al = l0 + sl * end;
                ar = r0 + sr * end;
                i0 += n;
            }
            if (any) deliver();
            if (smooth) {
                raisePeak(rt.peakL, pl);
                raisePeak(rt.peakR, pr);
                rt.curL = al; rt.curR = ar; rt.primed = true; // leaving automation continues from here
            }
            return;
        }

        if (!smooth) {
            if (any) {
                vec::scale(L, gl, s.fadeL, frames);
                vec::scale(R, gr, s.fadeR, frames);
                deliver();
            }
            return;
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
            // Sample k gets cur + d * (k + 1), reaching the target on the last sample.
            vec::rampMul(L, rt.curL, dl, s.fadeL, frames);
            vec::rampMul(R, rt.curR, dr, s.fadeR, frames);
            const float pl = blockMeter(s.fadeL, frames, rt.meterDcL), pr = blockMeter(s.fadeR, frames, rt.meterDcR);
            deliver();
            raisePeak(rt.peakL, pl);
            raisePeak(rt.peakR, pr);
        }
        rt.curL = gl;
        rt.curR = gr;
    };

    // Rounds: every track moves as far as it can, starting the blocks of its isolated plug-ins; finished tracks are
    // delivered in order; when nothing else can move, the blocks in flight are collected (one wait for all of them,
    // instead of one after another). With only in-process plug-ins this is the plain track-by-track order.
    size_t cursor = 0;
    while (cursor < count) {
        bool moved = false;
        for (size_t i = cursor; i < count; ++i)
            if (!steps[i].waiting && steps[i].stage != kStepReady && advance(i, cursor)) moved = true;
        while (cursor < count && steps[cursor].stage == kStepReady) { deliverTrack(cursor); ++cursor; moved = true; }
        if (moved) continue;
        bool collected = false;
        for (size_t i = cursor; i < count; ++i)
            if (steps[i].waiting) { finishPending(i); collected = true; }
        if (!collected) { // defensive: should not happen (the cursor track can always start)
            if (!advance(cursor, cursor)) { steps[cursor].stage = kStepReady; }
        }
    }
    // Master fader (ramped live from the previous block, constant offline).
    if (state.master) {
        TrackRuntime &m = *state.master;
        const float g = m.gain.load(std::memory_order_relaxed);
        if (!smooth || !m.primed) { m.curL = g; m.primed = smooth; }
        const float from = m.curL, step = (g - from) / static_cast<float>(frames);
        if (from != 1.0f || g != 1.0f)
            for (int i = 0; i < frames; ++i) { const float k = from + step * static_cast<float>(i + 1); left[i] *= k; right[i] *= k; }
        m.curL = g;
    }
}

void idlePlugins(const RenderState &state, Scratch &s) DALNOK_NONBLOCKING {
    for (const RenderTrack &t : state.tracks) {
        const bool live = &t - state.tracks.data() == s.liveTrack && (t.instrument || t.instrumentPlugin);
        if (s.timelineOff && (t.bus || monitorsInput(t, s) || live)) continue; // renderBlock runs these this callback
        if (t.instrumentPlugin) { t.instrumentPlugin->setDeadline(s.deadlineNs, &s.isolatedWaitNs); t.instrumentPlugin->idle(); }
        for (PluginProcessor *p : t.inserts) { p->setDeadline(s.deadlineNs, &s.isolatedWaitNs); p->idle(); }
    }
}

} // namespace dalnok
