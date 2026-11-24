// Clip tools (Logic's region functions, Ableton's clip commands): Normalize, Reverse, Strip Silence and Join.
// Each is one undo step. Reverse and Join write a new audio file (the app chooses where, beside the project's
// recordings); the clip then plays it, and undo returns to the old one (both stay in the pool).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"
#include "engine_internal.hpp"

#include <algorithm>
#include <cmath>

namespace dalnok {
using namespace detail;

namespace {
// Fade gain at position t of n (0..1 along the fade), as the renderer draws it.
float fadeAt(double t, int32_t curve) {
    t = std::clamp(t, 0.0, 1.0);
    return curve == kFadeEqualPower ? static_cast<float>(std::sin(t * 1.5707963267948966)) : static_cast<float>(t);
}
} // namespace

bool Engine::normalizeClip(DalnokClipId id, double targetDb, std::string &err) {
    const ClipState *c = model_.clip(id);
    if (!c) return fail(err, "no such clip");
    if (c->midi()) return fail(err, "normalize an audio clip");
    const PoolEntry *pe = poolEntry(c->media);
    if (!pe || !pe->handle->impl) return fail(err, "the clip's audio is offline");
    const Media &m = *pe->handle->impl;
    const int64_t span = std::min(c->looped() ? c->loopLength : c->sourceLength(), m.frames() - c->offset);
    if (span <= 0) return fail(err, "the clip is empty");
    std::vector<float> l(65536), r(65536);
    float peak = 0;
    for (int64_t done = 0; done < span;) {
        const int64_t n = std::min<int64_t>(65536, span - done);
        m.read(c->offset + done, n, l.data(), r.data());
        for (int64_t i = 0; i < n; ++i) peak = std::max({peak, std::fabs(l[static_cast<size_t>(i)]), std::fabs(r[static_cast<size_t>(i)])});
        done += n;
    }
    if (peak < 1e-6f) return fail(err, "the clip is silent");
    const float gain = static_cast<float>(targetDb - 20 * std::log10(peak));
    if (gain > 24) return fail(err, "the clip is too quiet to normalize (more than +24 dB)");
    return edit("Normalize", true, [&](Model &mm) {
        mm.clip(id)->gainDb = gain;
        return true;
    });
}

bool Engine::reverseClip(DalnokClipId id, const std::string &path, std::string &err) {
    const ClipState *c = model_.clip(id);
    if (!c) return fail(err, "no such clip");
    if (c->midi()) return fail(err, "reverse an audio clip");
    if (c->stretched() || c->looped()) return fail(err, "reverse a clip at its own speed (not stretched, quantized or looped)");
    const PoolEntry *pe = poolEntry(c->media);
    if (!pe || !pe->handle->impl) return fail(err, "the clip's audio is offline");
    const Media &m = *pe->handle->impl;
    const int64_t n = std::min(c->length, m.frames() - c->offset);
    if (n <= 0) return fail(err, "the clip is empty");
    std::vector<float> l(static_cast<size_t>(n)), r(static_cast<size_t>(n));
    m.read(c->offset, n, l.data(), r.data());
    std::reverse(l.begin(), l.end());
    std::reverse(r.begin(), r.end());
    std::unique_ptr<WavWriter> w(openWavWriter(path, sampleRate_, 32, err));
    if (!w || !w->write(l.data(), r.data(), n, err) || !w->close(err)) return false;
    auto media = Media::loadFile(path, sampleRate_, err);
    if (!media) return false;
    const DalnokMediaId mid = poolAdd(media, path);
    return edit("Reverse", true, [&](Model &mm) {
        ClipState *cc = mm.clip(id);
        cc->media = mid;
        cc->offset = 0;
        cc->length = n;
        std::swap(cc->fadeIn, cc->fadeOut); // the fade at the end of the audio is now at its start
        return true;
    });
}

std::vector<DalnokClipId> Engine::stripSilence(DalnokClipId id, double thresholdDb, double minSilence, std::string &err) {
    const ClipState *c = model_.clip(id);
    if (!c) return fail(err, "no such clip"), std::vector<DalnokClipId>{};
    if (c->midi() || c->stretched() || c->looped()) return fail(err, "strip silence from an audio clip at its own speed"), std::vector<DalnokClipId>{};
    const PoolEntry *pe = poolEntry(c->media);
    if (!pe || !pe->handle->impl) return fail(err, "the clip's audio is offline"), std::vector<DalnokClipId>{};
    const Media &m = *pe->handle->impl;
    const int64_t n = std::min(c->length, m.frames() - c->offset);
    // Peaks per 10 ms block; a region is a run of blocks over the threshold, with 10 ms kept before and 50 ms after,
    // and gaps shorter than `minSilence` closed.
    const int64_t block = std::max<int64_t>(1, static_cast<int64_t>(sampleRate_ * 0.01));
    const float thr = static_cast<float>(std::pow(10.0, thresholdDb / 20));
    std::vector<float> l(static_cast<size_t>(block)), r(static_cast<size_t>(block));
    std::vector<std::pair<int64_t, int64_t>> regions; // clip-relative frames
    for (int64_t b = 0; b < n; b += block) {
        const int64_t len = std::min(block, n - b);
        m.read(c->offset + b, len, l.data(), r.data());
        float p = 0;
        for (int64_t i = 0; i < len; ++i) p = std::max({p, std::fabs(l[static_cast<size_t>(i)]), std::fabs(r[static_cast<size_t>(i)])});
        if (p < thr) continue;
        const int64_t from = std::max<int64_t>(0, b - block), to = std::min(n, b + len + 5 * block);
        if (!regions.empty() && from - regions.back().second < static_cast<int64_t>(minSilence * sampleRate_)) regions.back().second = to;
        else regions.push_back({from, to});
    }
    if (regions.empty()) return fail(err, "the clip is all below the threshold"), std::vector<DalnokClipId>{};
    if (regions.size() == 1 && regions[0].first == 0 && regions[0].second >= n) return fail(err, "no silence to strip"), std::vector<DalnokClipId>{};
    std::vector<DalnokClipId> out;
    const auto first = nextClip_;
    const bool ok = edit("Strip Silence", true, [&](Model &mm) {
        const ClipState orig = *mm.clip(id);
        DalnokClipId next = first;
        for (size_t k = 0; k < regions.size(); ++k) {
            ClipState part = orig;
            part.start = orig.start + regions[k].first;
            part.offset = orig.offset + regions[k].first;
            part.length = regions[k].second - regions[k].first;
            const int64_t edge = std::min<int64_t>(part.length / 4, static_cast<int64_t>(sampleRate_ * 0.005)); // 5 ms
            part.fadeIn = k == 0 && regions[k].first == 0 ? orig.fadeIn : edge;
            part.fadeOut = k + 1 == regions.size() && regions[k].second >= n ? orig.fadeOut : edge;
            if (k == 0) *mm.clip(id) = part;
            else { part.id = next++; mm.clips.push_back(std::move(part)); }
        }
        return true;
    });
    if (!ok) return {};
    nextClip_ = first + static_cast<DalnokClipId>(regions.size() - 1);
    out.push_back(id);
    for (DalnokClipId k = first; k < nextClip_; ++k) out.push_back(k);
    return out;
}

DalnokClipId Engine::joinClips(const std::vector<DalnokClipId> &ids, const std::string &path, std::string &err) {
    if (ids.size() < 2) return fail(err, "select two or more clips to join"), 0;
    std::vector<const ClipState *> clips;
    for (auto id : ids) {
        const ClipState *c = model_.clip(id);
        if (!c) return fail(err, "no such clip"), 0;
        if (c->slot >= 0 || c->alt) return fail(err, "join arrangement clips"), 0;
        clips.push_back(c);
    }
    const DalnokTrackId track = clips[0]->track;
    const bool midi = clips[0]->midi();
    for (const auto *c : clips) {
        if (c->track != track) return fail(err, "join clips on one track"), 0;
        if (c->midi() != midi) return fail(err, "join MIDI with MIDI and audio with audio"), 0;
        if (!midi && (c->stretched() || c->looped())) return fail(err, "join audio clips at their own speed (not stretched, quantized or looped)"), 0;
    }
    int64_t start = INT64_MAX, end = 0;
    for (const auto *c : clips) { start = std::min(start, c->start); end = std::max(end, c->start + c->length); }
    // MIDI: one clip holding every note where it sounded (later clips' notes win a collision).
    if (midi) {
        std::vector<MidiNote> notes;
        std::vector<MidiCC> ccs;
        for (const auto *c : clips) {
            for (const auto &n : *c->notes)
                if (n.start >= c->offset && n.start < c->offset + c->length && !c->muted)
                    notes.push_back({c->start + n.start - c->offset - start, std::min(n.length, c->offset + c->length - n.start), n.pitch, n.velocity});
            if (c->controllers)
                for (const auto &e : *c->controllers)
                    if (e.start >= c->offset && e.start < c->offset + c->length && !c->muted)
                        ccs.push_back({c->start + e.start - c->offset - start, e.controller, e.value});
        }
        beginGroup("Join Clips");
        DalnokClipId joined = addMidiClip(track, start, end - start, err, std::move(notes), "Join Clips");
        bool ok = joined != 0 && (ccs.empty() || setControllers(joined, std::move(ccs), err));
        for (auto id : ids) ok = ok && removeClip(id, err);
        endGroup();
        if (!ok) { undo(); return 0; }
        return joined;
    }
    // Audio: the clips mixed as they play on the track (gain, fades; later clips on top), before the track's
    // plug-ins and fader, into one file.
    const int64_t n = end - start;
    std::vector<float> outL(static_cast<size_t>(n), 0.0f), outR(static_cast<size_t>(n), 0.0f);
    std::vector<const ClipState *> order;
    for (const auto &c : model_.clips) // model order = z-order
        if (std::find(ids.begin(), ids.end(), c.id) != ids.end()) order.push_back(&c);
    for (const auto *c : order) {
        if (c->muted) continue;
        const PoolEntry *pe = poolEntry(c->media);
        if (!pe || !pe->handle->impl) return fail(err, "a clip's audio is offline"), 0;
        const Media &m = *pe->handle->impl;
        const int64_t len = std::min(c->length, m.frames() - c->offset);
        if (len <= 0) continue;
        std::vector<float> l(static_cast<size_t>(len)), r(static_cast<size_t>(len));
        m.read(c->offset, len, l.data(), r.data());
        const float g = std::isfinite(c->gainDb) ? static_cast<float>(std::pow(10.0, c->gainDb / 20)) : 0.0f;
        int64_t fi = std::min(c->fadeIn, len), fo = std::min(c->fadeOut, len);
        if (fi + fo > len) { fi = len * fi / (fi + fo); fo = len - fi; }
        for (int64_t i = 0; i < len; ++i) {
            float env = 1;
            if (i < fi) env *= fadeAt((static_cast<double>(i) + 0.5) / static_cast<double>(fi), c->fadeCurve);
            if (i >= len - fo) env *= fadeAt((static_cast<double>(len - i) - 0.5) / static_cast<double>(fo), c->fadeCurve);
            const auto at = static_cast<size_t>(c->start - start + i);
            // On top: a later clip replaces what is under it (crossfading through its fades), as the renderer does.
            const float under = c->fadeCurve == kFadeEqualPower ? std::sqrt(std::max(0.0f, 1.0f - env * env)) : 1.0f - env;
            outL[at] = outL[at] * under + l[static_cast<size_t>(i)] * g * env;
            outR[at] = outR[at] * under + r[static_cast<size_t>(i)] * g * env;
        }
    }
    std::unique_ptr<WavWriter> w(openWavWriter(path, sampleRate_, 32, err));
    if (!w || !w->write(outL.data(), outR.data(), n, err) || !w->close(err)) return 0;
    auto media = Media::loadFile(path, sampleRate_, err);
    if (!media) return 0;
    const DalnokMediaId mid = poolAdd(media, path);
    beginGroup("Join Clips");
    const DalnokClipId joined = addClip(track, mid, start, 0, n, err);
    bool ok = joined != 0;
    for (auto id : ids) ok = ok && removeClip(id, err);
    endGroup();
    if (!ok) { undo(); return 0; }
    return joined;
}

} // namespace dalnok

// ---- Standard MIDI Files ----------------------------------------------------------------------------------------

#include "midi_file.hpp"

#include <fstream>
#include <sstream>

namespace dalnok {
using namespace detail;

std::vector<DalnokClipId> Engine::importMidiFile(const std::string &path, int64_t at, DalnokTrackId into, std::string &err) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return err = "can't open " + path, std::vector<DalnokClipId>{};
    std::stringstream ss;
    ss << in.rdbuf();
    const std::string bytes = ss.str();
    if (bytes.size() > 64u << 20) return fail(err, "the MIDI file is too large"), std::vector<DalnokClipId>{};
    SmfFile file;
    if (!parseMidiFile(bytes, file, err)) return {};
    if (into && (!model_.track(into) || model_.track(into)->kind == kTrackBus)) return fail(err, "choose an instrument track"), std::vector<DalnokClipId>{};
    std::string base = path.substr(path.find_last_of('/') + 1);
    if (const auto dot = base.find_last_of('.'); dot != std::string::npos) base = base.substr(0, dot);
    std::vector<DalnokClipId> out;
    beginGroup("Import MIDI File");
    bool ok = true;
    // An empty project takes the file's tempo and meter (as Logic and Ableton offer to).
    const bool empty = std::none_of(model_.clips.begin(), model_.clips.end(), [](const ClipState &c) { return c.slot < 0; });
    if (empty && (!file.tempo.empty() || file.meterNum != 4 || file.meterDen != 4)) {
        std::vector<TempoPoint> tempo;
        for (const auto &t : file.tempo) if (tempo.empty() || t.beat > tempo.back().beat + 1e-6) tempo.push_back({t.beat, t.bpm});
        if (tempo.empty() || tempo.front().beat > 0) tempo.insert(tempo.begin(), {0, tempo.empty() ? model_.bpm() : tempo.front().bpm});
        std::vector<MeterChange> meters = model_.meters;
        meters.front().num = file.meterNum;
        meters.front().den = file.meterDen;
        std::string tempoErr;
        if (!setTempoMap(std::move(tempo), std::move(meters), tempoErr)) { /* keep the project's tempo */ }
    }
    double beat0 = 0;
    if (!map_.frameToBeat(std::max<int64_t>(0, at), beat0)) beat0 = 0;
    const double barBeats = 4.0 * model_.meters.front().num / std::max(1, model_.meters.front().den);
    const double lenBeats = std::max(barBeats, std::ceil(file.lengthBeats / barBeats - 1e-9) * barBeats);
    int64_t start = 0, end = 0;
    ok = map_.beatToFrame(beat0, start) && map_.beatToFrame(beat0 + lenBeats, end) && end > start;
    // One clip per file track (all of them in one clip when a track was chosen).
    std::vector<SmfTrack> tracks = file.tracks;
    if (into && tracks.size() > 1) {
        SmfTrack all;
        for (auto &t : tracks) {
            all.notes.insert(all.notes.end(), t.notes.begin(), t.notes.end());
            all.controllers.insert(all.controllers.end(), t.controllers.begin(), t.controllers.end());
        }
        all.name = base;
        tracks = {all};
    }
    for (size_t k = 0; ok && k < tracks.size(); ++k) {
        const SmfTrack &st = tracks[k];
        DalnokTrackId t = into;
        if (!t) {
            t = addInstrumentTrack(st.name.empty() ? (tracks.size() == 1 ? base : base + " " + std::to_string(k + 1)) : st.name, err);
            ok = t != 0;
        }
        std::vector<MidiNote> notes;
        for (const auto &n : st.notes) {
            int64_t a, b;
            if (!map_.beatToFrame(beat0 + n.beat, a) || !map_.beatToFrame(beat0 + n.beat + n.length, b)) continue;
            notes.push_back({a - start, std::max<int64_t>(1, b - a), n.pitch, std::max<uint8_t>(1, n.velocity)});
        }
        std::vector<MidiCC> ccs;
        for (const auto &c : st.controllers) {
            int64_t a;
            if (map_.beatToFrame(beat0 + c.beat, a)) ccs.push_back({a - start, c.controller, c.value});
        }
        const DalnokClipId clip = ok ? addMidiClip(t, start, end - start, err, std::move(notes), "Import MIDI File") : 0;
        ok = clip != 0 && (ccs.empty() || setControllers(clip, std::move(ccs), err));
        if (ok) {
            if (ClipState *cs = model_.clip(clip)) cs->name = st.name.empty() ? base : st.name;
            out.push_back(clip);
        }
    }
    endGroup();
    if (!ok) { undo(); return {}; }
    return out;
}

bool Engine::exportMidiClip(DalnokClipId id, const std::string &path, std::string &err) {
    const ClipState *c = model_.clip(id);
    if (!c) return fail(err, "no such clip");
    if (!c->midi()) return fail(err, "export a MIDI clip");
    double b0;
    if (!map_.frameToBeat(c->start, b0)) return fail(err, "the clip is beyond the supported timeline");
    SmfTrack track;
    track.name = c->name;
    auto beatOf = [&](int64_t sourceFrame, double &out) {
        double b;
        if (!map_.frameToBeat(c->start - c->offset + sourceFrame, b)) return false;
        out = b - b0;
        return true;
    };
    for (const auto &n : *c->notes) {
        if (n.start < c->offset || n.start >= c->offset + c->length) continue;
        double a, b;
        if (!beatOf(n.start, a) || !beatOf(std::min(n.start + n.length, c->offset + c->length), b)) continue;
        track.notes.push_back({a, std::max(1e-3, b - a), n.pitch, n.velocity, 0});
    }
    if (c->controllers)
        for (const auto &e : *c->controllers) {
            double a;
            if (e.start >= c->offset && e.start < c->offset + c->length && beatOf(e.start, a)) track.controllers.push_back({a, e.controller, e.value});
        }
    std::vector<SmfTempo> tempo;
    for (const auto &t : model_.tempo) { // the tempo map from the clip's start on
        if (t.beat <= b0) { if (tempo.empty()) tempo.push_back({0, t.bpm}); else tempo.front().bpm = t.bpm; }
        else tempo.push_back({t.beat - b0, t.bpm});
    }
    const std::string bytes = writeMidiFile(track, tempo, model_.meters.front().num, model_.meters.front().den);
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out || !out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()))) return err = "can't write " + path, false;
    return true;
}

} // namespace dalnok
