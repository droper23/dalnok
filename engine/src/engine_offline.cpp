// Engine: offline rendering, export and statistics (split from engine.cpp, A-06).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"
#include "engine_internal.hpp"
#include "loudness.hpp"
#include "media.hpp"

#include <algorithm>
#include <array>
#include <functional>
#include <cmath>
#include <cstdio>
#include <set>
#include <unordered_map>
#include <utility>

namespace dalnok {
using detail::kTransportFadeSeconds;
using detail::nowNs;
using detail::atomicMax;
using detail::FlushDenormals;
using namespace detail;

bool Engine::renderOffline(int64_t start, int64_t frames, float *left, float *right) {
    [[maybe_unused]] const FlushDenormals flushDenormals;
    if (start < 0 || frames < 0 || !left || !right) return false;
    renderPendingStretchesNow();
    const auto offline = pluginHost_.offlineCopies(model_);
    const auto state = compile(nullptr, &offline);
    const bool anySolo = soloCount_.load() > 0;
    auto scratch = std::make_unique<Scratch>();
    std::vector<SynthState> synths(state->tracks.size());
    // Delay compensation: render the timeline ahead by the compensation and pre-roll that much first, so
    // output frame j is timeline frame start + j exactly as heard live.
    const int64_t m = state->compensation;
    // Streamed media (A-09): pin the blocks each second needs before rendering it.
    StreamCache::Lease lease;
    const int64_t window = static_cast<int64_t>(sampleRate_);
    int64_t leasedTo = start;
    const auto lease_ = [&](int64_t pos, int n) {
        if (pos + n <= leasedTo) return;
        lease.clear();
        leaseStreams(lease, *state, pos, window + n);
        leasedTo = pos + window + n;
    };
    float discardL[kMaxBlock], discardR[kMaxBlock];
    for (int64_t done = 0; done < m;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, m - done));
        lease_(start + done, n);
        renderBlock(*state, start + done, n, discardL, discardR, *scratch, false, anySolo, synths.data());
        done += n;
    }
    for (int64_t done = 0; done < frames;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, frames - done));
        lease_(start + m + done, n);
        renderBlock(*state, start + m + done, n, left + done, right + done, *scratch, false, anySolo, synths.data());
        done += n;
    }
    return true;
}

int32_t Engine::compensation() const {
    return compile(nullptr, &pluginHost_.instances())->compensation; // a throwaway snapshot with fresh delay lines (no live state touched)
}

bool Engine::renderToWav(const std::string &path, int64_t start, int64_t frames, int32_t bits, std::string &err,
                         int64_t maxTail, int64_t *tailWritten) {
    if (start < 0 || frames <= 0) {
        err = "invalid range";
        return false;
    }
    std::unique_ptr<WavWriter> w(openWavWriter(path, sampleRate_, bits, err));
    if (!w) return false;
    if (!renderBlocks(start, frames, maxTail, tailWritten, err,
                      [&](const float *l, const float *r, int64_t n) { return w->write(l, r, n, err); }))
        return false;
    return w->close(err);
}

bool Engine::renderToFile(const std::string &path, int64_t start, int64_t frames, int32_t format, std::string &err,
                          int64_t maxTail, int64_t *tailWritten) {
    if (start < 0 || frames <= 0) {
        err = "invalid range";
        return false;
    }
    std::unique_ptr<WavWriter> w(openAudioWriter(path, sampleRate_, format, err));
    if (!w) return false;
    if (!renderBlocks(start, frames, maxTail, tailWritten, err,
                      [&](const float *l, const float *r, int64_t n) { return w->write(l, r, n, err); }))
        return false;
    return w->close(err);
}

bool Engine::renderToFileWith(const std::string &path, int64_t start, int64_t frames, int32_t format, double outRate,
                              int32_t normalize, double target, std::string &err, int64_t maxTail, int64_t *tailWritten,
                              double *gainDb) {
    if (gainDb) *gainDb = 0;
    if (outRate <= 0) outRate = sampleRate_;
    if (outRate < 8'000 || outRate > 384'000) { err = "sample rate out of range (8-384 kHz)"; return false; }
    if (normalize < 0 || normalize > 2 || !std::isfinite(target) || target > 0 || target < -60) {
        err = normalize < 0 || normalize > 2 ? "unknown normalize mode" : "normalize target out of range (-60 to 0)";
        return false;
    }
    if (normalize == 0 && outRate == sampleRate_) return renderToFile(path, start, frames, format, err, maxTail, tailWritten);
    // Pass 1: the mix as 32-bit float at the engine's rate, measured on the way.
    const std::string temp = path + ".dalnok-render.wav";
    struct Cleanup { const std::string &p; ~Cleanup() { std::remove(p.c_str()); } } cleanup{temp};
    std::unique_ptr<WavWriter> raw(openWavWriter(temp, sampleRate_, 32, err));
    if (!raw) return false;
    LoudnessMeter meter(sampleRate_);
    float peak = 0;
    if (!renderBlocks(start, frames, maxTail, tailWritten, err, [&](const float *l, const float *r, int64_t n) {
            for (int64_t i = 0; i < n; ++i) peak = std::max({peak, std::fabs(l[i]), std::fabs(r[i])});
            for (int64_t o = 0; o < n;) {
                const int k = static_cast<int>(std::min<int64_t>(n - o, 1 << 16));
                meter.process(l + o, r + o, k);
                o += k;
            }
            return raw->write(l, r, n, err);
        }))
        return false;
    if (!raw->close(err)) return false;
    raw.reset();
    // The gain.
    double gain = 0; // dB
    if (normalize == 1 && peak > 0) gain = target - 20 * std::log10(static_cast<double>(peak));
    if (normalize == 2) {
        const LoudnessReading m = meter.reading();
        if (std::isfinite(m.integrated)) {
            gain = target - m.integrated;
            if (std::isfinite(m.truePeak)) gain = std::min(gain, -1.0 - m.truePeak); // the true-peak ceiling
        }
    }
    // Converting to another rate can raise sample peaks (the filter rings on sharp hits): measure them converted.
    if (normalize == 1 && outRate != sampleRate_) {
        float converted = 0;
        int32_t ch = 0;
        if (!decodeAudioFileChunked(temp, outRate, [&](const float *const *c, int32_t count, int64_t n) {
                for (int32_t k = 0; k < count; ++k)
                    for (int64_t i = 0; i < n; ++i) converted = std::max(converted, std::fabs(c[k][i]));
                return true;
            }, ch, err))
            return false;
        gain = converted > 0 ? target - 20 * std::log10(static_cast<double>(converted)) : 0;
    }
    if (gainDb) *gainDb = gain;
    const auto g = static_cast<float>(std::pow(10.0, gain / 20));
    // Pass 2: converted to the output rate (the system's sample-rate converter), with the gain, in the format.
    std::unique_ptr<WavWriter> w(openAudioWriter(path, outRate, format, err));
    if (!w) return false;
    std::vector<float> l, r;
    int32_t channels = 0;
    bool wrote = true;
    if (!decodeAudioFileChunked(temp, outRate, [&](const float *const *ch, int32_t count, int64_t n) {
            l.resize(static_cast<size_t>(n));
            r.resize(static_cast<size_t>(n));
            for (int64_t i = 0; i < n; ++i) {
                l[static_cast<size_t>(i)] = ch[0][i] * g;
                r[static_cast<size_t>(i)] = ch[count > 1 ? 1 : 0][i] * g;
            }
            wrote = w->write(l.data(), r.data(), n, err);
            return wrote;
        }, channels, err) || !wrote)
        return false;
    return w->close(err);
}

bool Engine::renderBlocks(int64_t start, int64_t frames, int64_t maxTail, int64_t *tailWritten, std::string &err,
                          const std::function<bool(const float *, const float *, int64_t)> &sink,
                          const std::function<void(Scratch &, const RenderState &)> &prepare,
                          const std::function<void(const Scratch &, int)> &onBlock) {
    [[maybe_unused]] const FlushDenormals flushDenormals;
    if (start < 0 || frames <= 0) {
        err = "invalid range";
        return false;
    }
    renderPendingStretchesNow();
    const auto offline = pluginHost_.offlineCopies(model_);
    const auto state = compile(nullptr, &offline);
    auto scratch = std::make_unique<Scratch>();
    std::vector<SynthState> synths(state->tracks.size());
    std::vector<float> l(kMaxBlock * 64), r(kMaxBlock * 64);
    const int64_t m = state->compensation; // pre-roll, as in renderOffline
    Scratch *const pre = scratch.get();
    if (prepare) prepare(*pre, *state);
    const size_t stems = pre->stemTracks;
    pre->stemTracks = 0; // not during the pre-roll
    StreamCache::Lease lease; // streamed media (A-09), as in renderOffline
    const int64_t window = static_cast<int64_t>(sampleRate_);
    int64_t leasedTo = start;
    const auto lease_ = [&](int64_t pos, int64_t n) {
        if (pos + n <= leasedTo) return;
        lease.clear();
        leaseStreams(lease, *state, pos, window + n);
        leasedTo = pos + window + n;
    };
    for (int64_t done = 0; done < m;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, m - done));
        lease_(start + done, n);
        renderBlock(*state, start + done, n, l.data(), r.data(), *scratch, false, soloCount_.load() > 0, synths.data());
        done += n;
    }
    pre->stemTracks = stems;
    for (int64_t done = 0; done < frames;) {
        const auto chunk = std::min<int64_t>(static_cast<int64_t>(l.size()), frames - done);
        for (int64_t o = 0; o < chunk;) {
            const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, chunk - o));
            lease_(start + m + done + o, n);
            renderBlock(*state, start + m + done + o, n, l.data() + o, r.data() + o, *scratch, false, soloCount_.load() > 0,
                        synths.data());
            if (onBlock) onBlock(*scratch, n);
            o += n;
        }
        if (!sink(l.data(), r.data(), chunk)) return false;
        done += chunk;
    }
    // Tail: keep rendering past the end (synth releases, delay and reverb decay, compressor release) until half a
    // second stays below -100 dBFS or `maxTail` frames are rendered, so an export never ends in a hard cut. Quiet
    // blocks are held back and only written once something audible follows, so the file ends at the last audible
    // block: a mix that already ends in silence exports at exactly its length.
    int64_t tail = 0, rendered = 0, quiet = 0;
    const int64_t quietNeeded = static_cast<int64_t>(sampleRate_ * 0.5);
    std::vector<float> heldL, heldR;
    while (rendered < maxTail && quiet < quietNeeded) {
        const int n = static_cast<int>(std::min<int64_t>({kMaxBlock, maxTail - rendered}));
        lease_(start + m + frames + rendered, n);
        renderBlock(*state, start + m + frames + rendered, n, l.data(), r.data(), *scratch, false,
                    soloCount_.load() > 0, synths.data());
        if (onBlock) onBlock(*scratch, n);
        rendered += n;
        float peak = 0;
        for (int i = 0; i < n; ++i) peak = std::max({peak, std::fabs(l[i]), std::fabs(r[i])});
        if (peak < 1e-5f) {
            quiet += n;
            heldL.insert(heldL.end(), l.data(), l.data() + n);
            heldR.insert(heldR.end(), r.data(), r.data() + n);
            continue;
        }
        quiet = 0;
        if (!heldL.empty()) {
            if (!sink(heldL.data(), heldR.data(), static_cast<int64_t>(heldL.size()))) return false;
            tail += static_cast<int64_t>(heldL.size());
            heldL.clear();
            heldR.clear();
        }
        if (!sink(l.data(), r.data(), n)) return false;
        tail += n;
    }
    if (tailWritten) *tailWritten = tail;
    return true;
}

bool Engine::exportStems(const std::string &folder, int32_t format, int64_t start, int64_t frames, int64_t maxTail,
                         std::vector<std::string> &paths, std::string &err, const std::vector<DalnokTrackId> &only,
                         bool buses) {
    static const char *const kExt[] = {"wav", "wav", "wav", "aif", "m4a", "m4a", "flac"};
    if (format < 0 || format > 6) return fail(err, "unknown export format");
    struct Stem { DalnokTrackId id; std::unique_ptr<WavWriter> writer; size_t index = 0; };
    std::vector<Stem> stems;
    int n = 0;
    for (const auto &t : model_.tracks) {
        ++n;
        if (t.muted || (t.kind == kTrackBus && !buses)) continue;
        if (!only.empty() && std::find(only.begin(), only.end(), t.id) == only.end()) continue;
        std::string name;
        for (char ch : t.name) name += (ch == '/' || ch == ':' || ch == '\\') ? '-' : ch;
        char prefix[8];
        snprintf(prefix, sizeof prefix, "%02d ", n);
        const std::string path = folder + "/" + prefix + name + "." + kExt[format];
        std::unique_ptr<WavWriter> w(openAudioWriter(path, sampleRate_, format, err));
        if (!w) return false;
        paths.push_back(path);
        stems.push_back({t.id, std::move(w)});
    }
    if (stems.empty()) return fail(err, buses ? "no tracks to export (muted tracks are left out)" : "no tracks to export (buses and muted tracks are left out)");
    std::vector<float> bufL, bufR;
    bool failed = false;
    const bool ok = renderBlocks(start, frames, maxTail, nullptr, err,
        [&](const float *, const float *, int64_t) { return !failed; },
        [&](Scratch &s, const RenderState &state) {
            bufL.assign(state.tracks.size() * kMaxBlock, 0.0f);
            bufR.assign(state.tracks.size() * kMaxBlock, 0.0f);
            s.stemL = bufL.data();
            s.stemR = bufR.data();
            s.stemTracks = state.tracks.size();
            for (auto &st : stems)
                for (size_t i = 0; i < state.tracks.size(); ++i)
                    if (state.tracks[i].id == static_cast<int32_t>(st.id)) st.index = i;
        },
        [&](const Scratch &s, int count) {
            for (auto &st : stems)
                if (!failed && !st.writer->write(s.stemL + st.index * kMaxBlock, s.stemR + st.index * kMaxBlock, count, err))
                    failed = true;
        });
    if (!ok || failed) return false;
    for (auto &st : stems) if (!st.writer->close(err)) return false;
    return true;
}

void Engine::drainInputNotes(std::vector<InputNote> *fresh) {
    InputNote e;
    while (inputNotes_.pop(e)) {
        captureHistory_.push_back(e);
        if (fresh) fresh->push_back(e);
    }
    const uint64_t keep = static_cast<uint64_t>(sampleRate_ * 120); // two minutes
    const uint64_t now = inputClock_.load(std::memory_order_relaxed);
    std::erase_if(captureHistory_, [&](const InputNote &n) { return n.clock + keep < now; });
}

int Engine::takeInputNotes(DalnokInputNote *out, int capacity) {
    std::vector<InputNote> fresh;
    drainInputNotes(&fresh);
    int n = 0;
    for (const auto &e : fresh) if (n < capacity) out[n++] = {e.pitch, e.velocity, e.on};
    return n;
}

int Engine::capturePending() {
    drainInputNotes(nullptr);
    return static_cast<int>(std::count_if(captureHistory_.begin(), captureHistory_.end(),
                                          [&](const InputNote &e) { return e.on && e.clock >= captureFrom_; }));
}

DalnokClipId Engine::captureMidi(DalnokTrackId track, std::string &err) {
    const TrackState *t = model_.track(track);
    if (!t) return fail(err, "no such track"), 0;
    if (t->kind == kTrackBus) return fail(err, "choose an instrument track"), 0;
    drainInputNotes(nullptr);
    std::vector<InputNote> played;
    for (const auto &e : captureHistory_) if (e.clock >= captureFrom_) played.push_back(e);
    // The latest phrase: back from the last note to the first pause of 4 s or more.
    const uint64_t pause = static_cast<uint64_t>(sampleRate_ * 4);
    size_t first = played.size();
    while (first > 0 && (first == played.size() || played[first].clock - played[first - 1].clock < pause)) --first;
    played.erase(played.begin(), played.begin() + static_cast<std::ptrdiff_t>(first));
    if (std::none_of(played.begin(), played.end(), [](const InputNote &e) { return e.on; })) return fail(err, "nothing was played"), 0;
    // Played with the transport running: notes go where they were played. Stopped: the phrase starts at the
    // playhead (the bar it is in), keeping its own timing.
    const bool timed = std::all_of(played.begin(), played.end(), [](const InputNote &e) { return e.pos >= 0; });
    const uint64_t clock0 = played.front().clock;
    double bar0 = 0;
    int64_t origin = 0;
    {
        int64_t at = timed ? played.front().pos : std::max<int64_t>(0, position());
        double beat;
        if (!map_.frameToBeat(at, beat)) beat = 0;
        const double barBeats = 4.0 * model_.meters.front().num / std::max(1, model_.meters.front().den);
        bar0 = std::floor(beat / barBeats) * barBeats;
        if (!map_.beatToFrame(bar0, origin)) origin = 0; // the bar the first note (or the playhead) is in
    }
    auto when = [&](const InputNote &e) { return timed ? e.pos : origin + static_cast<int64_t>(e.clock - clock0); };
    struct Held { int64_t at = -1; uint8_t velocity = 0; };
    std::array<Held, 128> held{};
    std::vector<MidiNote> notes;
    int64_t last = origin;
    for (const auto &e : played) {
        const int64_t at = when(e);
        last = std::max(last, at);
        Held &h = held[e.pitch & 0x7f];
        if (h.at >= 0) { notes.push_back({h.at - origin, std::max<int64_t>(1, at - h.at), static_cast<uint8_t>(e.pitch & 0x7f), h.velocity}); h.at = -1; }
        if (e.on) h = {at, static_cast<uint8_t>(std::max<int>(1, e.velocity & 0x7f))};
    }
    for (int p = 0; p < 128; ++p) // still held: to the last event
        if (held[static_cast<size_t>(p)].at >= 0)
            notes.push_back({held[static_cast<size_t>(p)].at - origin, std::max<int64_t>(1, last - held[static_cast<size_t>(p)].at),
                             static_cast<uint8_t>(p), held[static_cast<size_t>(p)].velocity});
    if (std::any_of(notes.begin(), notes.end(), [](const MidiNote &n) { return n.start < 0; }))
        for (auto &n : notes) n.start = std::max<int64_t>(0, n.start);
    int64_t end = origin;
    for (const auto &n : notes) end = std::max(end, origin + n.start + n.length);
    // Whole bars.
    double endBeat;
    int64_t clipEnd = end;
    if (map_.frameToBeat(end, endBeat)) {
        const double barBeats = 4.0 * model_.meters.front().num / std::max(1, model_.meters.front().den);
        map_.beatToFrame(std::ceil(endBeat / barBeats - 1e-9) * barBeats, clipEnd);
    }
    const DalnokClipId c = addMidiClip(track, origin, std::max<int64_t>(1, clipEnd - origin), err, std::move(notes), "Capture MIDI");
    if (c) captureFrom_ = inputClock_.load(std::memory_order_relaxed);
    return c;
}

bool Engine::renderLoudness(int64_t start, int64_t frames, LoudnessReading &out, std::string &err) {
    if (start < 0 || frames <= 0) return fail(err, "invalid range");
    LoudnessMeter meter(sampleRate_);
    if (!renderBlocks(start, frames, 0, nullptr, err, [&](const float *l, const float *r, int64_t n) {
            meter.process(l, r, static_cast<int>(n));
            return true;
        }))
        return false;
    out = meter.reading();
    return true;
}

DalnokTrackId Engine::bounceInPlace(DalnokTrackId track, const std::string &path, std::string &err) {
    [[maybe_unused]] const FlushDenormals flushDenormals;
    const TrackState *src = model_.track(track);
    if (!src) return fail(err, "no such track"), 0;
    if (src->kind == kTrackBus) return fail(err, "buses can't be bounced in place (bounce their tracks)"), 0;
    int64_t start = INT64_MAX, end = 0;
    for (const auto &c : model_.clips)
        if (c.track == track && c.slot < 0 && !c.alt && !c.muted) {
            start = std::min(start, c.start);
            end = std::max(end, c.start + c.length);
        }
    if (end <= start) return fail(err, "the track has no clips to bounce"), 0;

    renderPendingStretchesNow();
    const auto offline = pluginHost_.offlineCopies(model_);
    const auto state = compile(nullptr, &offline);
    size_t index = state->tracks.size();
    for (size_t i = 0; i < state->tracks.size(); ++i) if (state->tracks[i].id == static_cast<int32_t>(track)) index = i;
    if (index == state->tracks.size()) return fail(err, "the track is not rendered"), 0;
    const int64_t latency = state->tracks[index].latency; // the track's plug-ins delay its output by this much
    auto scratch = std::make_unique<Scratch>();
    std::vector<SynthState> synths(state->tracks.size());
    std::vector<float> l(kMaxBlock), r(kMaxBlock);
    std::vector<float> outL, outR;
    StreamCache::Lease lease;
    const int64_t window = static_cast<int64_t>(sampleRate_);
    int64_t leasedTo = start;
    const int64_t body = end - start + latency, maxTail = static_cast<int64_t>(sampleRate_ * 10);
    const int64_t quietNeeded = static_cast<int64_t>(sampleRate_ * 0.5);
    int64_t lastLoud = 0, quiet = 0;
    for (int64_t done = 0; done < body || (done < body + maxTail && quiet < quietNeeded);) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, (done < body ? body : body + maxTail) - done));
        const int64_t pos = start + done;
        if (pos + n > leasedTo) {
            lease.clear();
            leaseStreams(lease, *state, pos, window + n);
            leasedTo = pos + window + n;
        }
        renderBlock(*state, pos, n, l.data(), r.data(), *scratch, false, false, synths.data());
        const float *cl = state->chainL.data() + index * kMaxBlock, *cr = state->chainR.data() + index * kMaxBlock;
        outL.insert(outL.end(), cl, cl + n);
        outR.insert(outR.end(), cr, cr + n);
        float peak = 0;
        for (int i = 0; i < n; ++i) peak = std::max({peak, std::fabs(cl[i]), std::fabs(cr[i])});
        done += n;
        if (peak >= 1e-5f) { lastLoud = done; quiet = 0; } else if (done > body) quiet += n;
    }
    // Drop the plug-ins' latency (the bounce lines up with the clips) and the silent end of the tail.
    const int64_t keep = std::max(end - start, lastLoud - latency);
    const auto from = static_cast<size_t>(std::min<int64_t>(latency, static_cast<int64_t>(outL.size())));
    const auto to = std::min(outL.size(), from + static_cast<size_t>(keep));
    std::unique_ptr<WavWriter> w(openWavWriter(path, sampleRate_, 32, err));
    if (!w || !w->write(outL.data() + from, outR.data() + from, static_cast<int64_t>(to - from), err) || !w->close(err)) return 0;
    auto media = Media::loadFile(path, sampleRate_, err);
    if (!media) return 0;
    const DalnokMediaId mid = poolAdd(media, path);

    const TrackState copy = *src;
    beginGroup("Bounce in Place");
    DalnokTrackId out = addTrack(copy.name + " Bounce", err);
    int32_t at = 0;
    for (size_t i = 0; i < model_.tracks.size(); ++i) if (model_.tracks[i].id == track) at = static_cast<int32_t>(i) + 1;
    const bool ok = out && moveTrack(out, at, err) && addClip(out, mid, start, 0, static_cast<int64_t>(to - from), err) &&
                    setTrackOutput(out, copy.output, err) && setGainDb(out, copy.gainDb, err) && setPan(out, copy.pan, err) &&
                    setMute(track, true, err);
    endGroup();
    if (!ok) {
        if (out) undo();
        return 0;
    }
    return out;
}

// ---- Diagnostics --------------------------------------------------------

void Engine::stats(DalnokStats &o) const {
    o.callbacks = callbacks_.load(std::memory_order_relaxed);
    o.frames_rendered = inputClock_.load(std::memory_order_relaxed);
    o.max_callback_ns = maxCallbackNs_.load(std::memory_order_relaxed);
    o.last_callback_ns = lastCallbackNs_.load(std::memory_order_relaxed);
    o.max_frames_per_callback = maxFrames_.load(std::memory_order_relaxed);
    o.overloads = overloads_.load(std::memory_order_relaxed);
    o.snapshot_swaps = swaps_.load(std::memory_order_relaxed);
    o.retired_queue_depth = static_cast<uint32_t>(retired_.size());
    o.retired_queue_high_water = retiredHighWater_.load(std::memory_order_relaxed);
    o.pending_snapshot_callbacks = pendingSnapshotCallbacks_.load(std::memory_order_relaxed);
    o.snapshot_adoption_skips = adoptionSkips_.load(std::memory_order_relaxed);
}

void Engine::resetStats() {
    callbacks_ = 0;
    framesRendered_ = 0;
    maxCallbackNs_ = 0;
    lastCallbackNs_ = 0;
    maxFrames_ = 0;
    overloads_ = 0;
    swaps_ = 0;
    retiredHighWater_ = static_cast<uint32_t>(retired_.size());
    pendingSnapshotCallbacks_ = 0;
    adoptionSkips_ = 0;
}

#ifdef DALNOK_TEST_HOOKS
// Compiled only for the explicit saturation test build. Reproduce publication
// and the device callback without the normal control-thread collection calls.
void handoffSaturationFixture(uint64_t *out) {
    Engine engine(48000);
    float left[64]{}, right[64]{};
    engine.process(left, right, 64); // adopt the constructor's initial snapshot
    engine.resetStats();
    for (int i = 0; i < 100; ++i) {
        auto state = engine.compile();
        delete engine.pending_.exchange(state.release(), std::memory_order_acq_rel);
        engine.process(left, right, 64);
    }
    DalnokStats stats{};
    auto record = [&](int offset) {
        engine.stats(stats);
        out[offset] = stats.retired_queue_depth;
        out[offset + 1] = stats.retired_queue_high_water;
        out[offset + 2] = stats.pending_snapshot_callbacks;
        out[offset + 3] = stats.snapshot_adoption_skips;
        out[offset + 4] = stats.snapshot_swaps;
    };
    record(0);
    engine.resetStats();
    record(5);
    for (int i = 0; i < 3; ++i) engine.process(left, right, 64);
    record(10);
    engine.collectGarbage();
    record(15);
    engine.process(left, right, 64);
    record(20);
    engine.resetStats();
    record(25);
}
#endif

} // namespace dalnok
