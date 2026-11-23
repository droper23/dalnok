// Render compiler: turns the project model into an immutable RenderState snapshot for the audio thread (A-06; moved
// from Engine). It keeps the live caches that make compiling incremental: per-track content reused while a track's
// clips are unchanged (A-04), and delay-compensation lines kept across snapshots. Control thread only.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "render_compiler.hpp"
#include "engine.hpp"

#include <algorithm>
#include <cmath>
#include <set>
#include <string>
#include <utility>

namespace dalnok {

StretchKey stretchKeyOf(const ClipState &c) {
    return {c.media, c.offset, c.sourceLength(), c.length, static_cast<int32_t>(std::lround(c.pitch * 100)), c.preservePitch};
}

const PoolEntry *RenderCompiler::pool(DalnokMediaId id) const {
    auto it = in_->pool.find(id);
    return it == in_->pool.end() ? nullptr : &it->second;
}

const Media *RenderCompiler::resolvedMedia(const ClipState &c) {
    if (c.midi()) return nullptr;
    const PoolEntry *pe = pool(c.media);
    return pe && pe->handle->impl ? pe->handle->impl.get() : nullptr;
}

std::shared_ptr<const Media> RenderCompiler::resolvedStretch(const ClipState &c, const Media *media) {
    return media && c.stretched() ? in_->stretch.find(stretchKeyOf(c)) : nullptr;
}

bool RenderCompiler::sameInputs(const ClipKey &k, const ClipState &c) {
    if (k.id != c.id || k.slot != c.slot || k.follow != c.follow || k.followLoops != c.followLoops ||
        k.fadeCurve != c.fadeCurve || k.muted != c.muted || k.alt != c.alt || k.preservePitch != c.preservePitch ||
        k.notes != c.notes || k.mediaId != c.media || k.start != c.start || k.offset != c.offset ||
        k.length != c.length || k.fadeIn != c.fadeIn || k.fadeOut != c.fadeOut || k.gainDb != c.gainDb ||
        k.pitch != c.pitch || k.rate != c.rate)
        return false;
    const Media *media = resolvedMedia(c);
    if (media != k.media.get()) return false;
    return !media || !c.stretched() || resolvedStretch(c, media).get() == k.derived.get();
}

std::shared_ptr<const TrackContent> RenderCompiler::buildContent(const std::vector<const ClipState *> &clips, bool instrument,
                                                         std::vector<StretchJob> &needed) {
    auto out = std::make_shared<TrackContent>();
    for (const ClipState *cp : clips) {
        const ClipState &c = *cp;
        if (c.alt) continue; // takes in a folder don't play; the comp's pieces do
        if (c.muted) {
            if (c.midi()) out->mutedMidiSignature = (out->mutedMidiSignature * 1099511628211ULL) ^ static_cast<uint64_t>(c.id);
            if (c.slot >= 0) {
                RenderSlot sl; sl.slot = c.slot; sl.follow = c.follow; sl.followLoops = std::max(1, c.followLoops);
                sl.length = c.length; sl.muted = true; out->slots.push_back(std::move(sl));
            }
            continue;
        }
        if (c.slot >= 0 && c.midi()) { // launcher slot: notes relative to the loop start
            if (!instrument) continue;
            RenderSlot sl;
            sl.slot = c.slot;
            sl.follow = c.follow;
            sl.followLoops = std::max(1, c.followLoops);
            sl.length = c.length;
            for (const auto &n : *c.notes) {
                if (n.start < c.offset || n.start >= c.offset + c.length) continue;
                const int64_t at = n.start - c.offset;
                sl.notes.push_back({at, std::min(at + n.length, c.length), n.pitch, n.velocity});
            }
            std::stable_sort(sl.notes.begin(), sl.notes.end(), [](const RenderNote &a, const RenderNote &b) { return a.start < b.start; });
            sl.noteEnds = sl.notes;
            std::stable_sort(sl.noteEnds.begin(), sl.noteEnds.end(), [](const RenderNote &a, const RenderNote &b) { return a.end < b.end; });
            out->slots.push_back(std::move(sl));
            continue;
        }
        if (c.midi()) {
            if (!instrument) continue;
            for (const auto &n : *c.notes) {
                if (n.start < c.offset || n.start >= c.offset + c.length) continue; // outside the clip window
                const int64_t at = c.start + (n.start - c.offset);
                int64_t sourceEnd = c.offset + c.length;
                int64_t timelineEnd = c.start + c.length;
                // A split shares its note list and has contiguous source and timeline ranges.
                // Extend a crossing note through those pieces without retriggering it.
                while (timelineEnd - at < n.length) {
                    // Same first match as scanning the whole model: `clips` is this track's clips in model order.
                    const auto next = std::find_if(clips.begin(), clips.end(), [&](const ClipState *part) {
                        return !part->muted && part->notes == c.notes && part->start == timelineEnd &&
                               std::abs(part->offset - sourceEnd) <= 1;
                    });
                    if (next == clips.end() || (*next)->length <= 0) break;
                    sourceEnd = (*next)->offset + (*next)->length;
                    timelineEnd += (*next)->length;
                }
                const int64_t end = at + std::min(n.length, timelineEnd - at);
                out->notes.push_back({at, end, n.pitch, n.velocity});
            }
            continue;
        }
        const PoolEntry *pe = pool(c.media);
        if (!pe || !pe->handle->impl) continue; // offline media renders silence
        std::shared_ptr<const Media> media = pe->handle->impl;
        int64_t offset = c.offset, len = std::min(c.length, media->frames() - c.offset);
        if (c.stretched()) {
            // Stretched audio is rendered off the audio thread; until it's ready the clip is silent.
            const StretchKey key = stretchKeyOf(c);
            auto derived = in_->stretch.find(key);
            if (!derived) {
                needed.push_back({key, media});
                continue;
            }
            media = derived;
            offset = 0;
            len = std::min(c.length, media->frames());
        }
        if (len <= 0) continue;
        // Fades longer than the clip are scaled down proportionally.
        int64_t fi = std::min(c.fadeIn, len), fo = std::min(c.fadeOut, len);
        if (fi + fo > len) {
            const double k = static_cast<double>(len) / static_cast<double>(fi + fo);
            fi = static_cast<int64_t>(static_cast<double>(fi) * k);
            fo = len - fi;
        }
        if (c.slot >= 0) { // launcher slot: one loop of the clip window
            RenderSlot sl;
            sl.slot = c.slot;
            sl.follow = c.follow;
            sl.followLoops = std::max(1, c.followLoops);
            sl.length = len;
            sl.hasAudio = true;
            sl.clip = {media, 0, offset, len, fi, fo, c.fadeCurve, dbToGain(c.gainDb)};
            out->slots.push_back(std::move(sl));
            continue;
        }
        out->clips.push_back({media, c.start, offset, len, fi, fo, c.fadeCurve, dbToGain(c.gainDb)});
        if (media->channelCount() > 1) out->stereoClip = true;
    }
    std::stable_sort(out->notes.begin(), out->notes.end(),
                     [](const RenderNote &a, const RenderNote &b) { return a.start < b.start; });
    out->noteEnds = out->notes;
    std::stable_sort(out->noteEnds.begin(), out->noteEnds.end(),
                     [](const RenderNote &a, const RenderNote &b) { return a.end < b.end; });
    // Launcher "next" follow action: the next filled slot on this track, wrapping.
    std::sort(out->slots.begin(), out->slots.end(), [](const RenderSlot &a, const RenderSlot &b) { return a.slot < b.slot; });
    for (size_t k = 0; k < out->slots.size(); ++k) out->slots[k].nextSlot = out->slots[(k + 1) % out->slots.size()].slot;
    return out;
}

namespace {
bool sameClip(const RenderClip &a, const RenderClip &b) {
    return a.media == b.media && a.start == b.start && a.offset == b.offset && a.length == b.length &&
           a.fadeIn == b.fadeIn && a.fadeOut == b.fadeOut && a.curve == b.curve && a.gain == b.gain;
}
bool sameNotes(const std::vector<RenderNote> &a, const std::vector<RenderNote> &b) {
    return std::equal(a.begin(), a.end(), b.begin(), b.end(), [](const RenderNote &x, const RenderNote &y) {
        return x.start == y.start && x.end == y.end && x.pitch == y.pitch && x.velocity == y.velocity;
    });
}
bool sameContent(const TrackContent &a, const TrackContent &b) {
    return a.stereoClip == b.stereoClip && a.mutedMidiSignature == b.mutedMidiSignature &&
           sameNotes(a.notes, b.notes) && sameNotes(a.noteEnds, b.noteEnds) &&
           std::equal(a.clips.begin(), a.clips.end(), b.clips.begin(), b.clips.end(), sameClip) &&
           std::equal(a.slots.begin(), a.slots.end(), b.slots.begin(), b.slots.end(), [](const RenderSlot &x, const RenderSlot &y) {
               return x.slot == y.slot && x.follow == y.follow && x.followLoops == y.followLoops && x.nextSlot == y.nextSlot &&
                      x.length == y.length && x.hasAudio == y.hasAudio && x.muted == y.muted && sameClip(x.clip, y.clip) &&
                      sameNotes(x.notes, y.notes) && sameNotes(x.noteEnds, y.noteEnds);
           });
}
} // namespace

int32_t RenderCompiler::mismatches(const CompileInputs &inputs) {
    std::vector<StretchJob> jobs;
    const auto state = compile(inputs, &jobs, true); // live: reuses cached content exactly as commit() does
    in_ = &inputs;
    std::map<DalnokTrackId, std::vector<const ClipState *>> clipsByTrack;
    for (const auto &c : in_->model.clips) clipsByTrack[c.track].push_back(&c);
    int32_t mismatches = 0;
    for (const auto &rt : state->tracks) {
        std::vector<StretchJob> fresh;
        const auto expected = buildContent(clipsByTrack[rt.id], rt.instrument, fresh);
        if (!rt.content || !sameContent(*rt.content, *expected)) ++mismatches;
    }
    return mismatches;
}

std::unique_ptr<RenderState> RenderCompiler::compile(const CompileInputs &inputs, std::vector<StretchJob> *needed, bool live) {
    in_ = &inputs;
    const PluginMap &instances = inputs.plugins;
    auto s = std::make_unique<RenderState>();
    s->synth = SynthParams::make(in_->sampleRate);
    // Exports get their own master runtime (same gain) so they never touch the live smoothing state.
    if (!live) { s->master = std::make_shared<TrackRuntime>(); s->master->gain.store(inputs.master->gain.load()); }
    else s->master = inputs.master;
    for (const auto &seg : in_->tempo.segments())
        s->clickTempo.push_back({seg.beat, static_cast<double>(seg.frame), static_cast<double>(seg.framesPerBeat)});
    for (const auto &m : in_->model.meters)
        s->clickMeter.push_back({barToBeat(in_->model.meters, m.bar), 4.0 / m.den, m.num});
    // Processing order: a topological order of the signal graph (outputs and sends into buses, sidechain
    // sources into the tracks that listen to them), sources first and otherwise in display order.
    std::vector<const TrackState *> order;
    {
        auto feeds = [&](const TrackState &from, const TrackState &to) {
            if (from.output == to.id) return true;
            for (const auto &snd : from.sends) if (snd.bus == to.id) return true;
            for (const auto &slot : to.plugins) if (slot.sidechain == from.id) return true;
            return false;
        };
        std::vector<const TrackState *> left;
        // Non-bus tracks are listed first so plain projects keep their familiar order.
        for (const auto &t : in_->model.tracks) if (t.kind != kTrackBus) left.push_back(&t);
        for (const auto &t : in_->model.tracks) if (t.kind == kTrackBus) left.push_back(&t);
        while (!left.empty()) { // Kahn's algorithm; edits keep the graph acyclic, so this always progresses
            auto ready = std::find_if(left.begin(), left.end(), [&](const TrackState *b) {
                return std::none_of(left.begin(), left.end(), [&](const TrackState *o) { return o != b && feeds(*o, *b); });
            });
            if (ready == left.end()) ready = left.begin(); // defensive: never loop forever
            order.push_back(*ready);
            left.erase(ready);
        }
    }
    // Clips bucketed by track once, so building each RenderTrack is linear in the project's clips instead of
    // scanning every clip once per track (the audit's O(tracks x clips) finding, A-04). Takes in a folder (alt)
    // are bucketed too: they don't play, but the split-note extension sees them and the content key records them.
    std::map<DalnokTrackId, std::vector<const ClipState *>> clipsByTrack;
    for (const auto &c : in_->model.clips) clipsByTrack[c.track].push_back(&c);
    std::set<DalnokTrackId> seen;
    std::map<DalnokTrackId, int32_t> indexOf;
    for (const TrackState *tp : order) {
        const TrackState &t = *tp;
        indexOf[t.id] = static_cast<int32_t>(s->tracks.size());
        RenderTrack rt;
        rt.id = t.id;
        rt.runtime = t.runtime;
        rt.bus = t.kind == kTrackBus;
        rt.monoSource = !rt.bus; // buses are stereo (balance pan)
        rt.invert = t.phaseInvert;
        if (t.kind == kTrackAudio) { rt.inputChannel = t.inputChannel; rt.inputMonitor = t.inputMonitor; rt.armed = t.armed; }
        for (const auto &p : t.volumeAuto) // fader taper: amplitude^(1/4); -inf at the bottom
            rt.volumeAuto.push_back({p.frame, p.value <= -95 ? 0.0f : std::pow(dbToGain(p.value), 0.25f)});
        for (const auto &p : t.panAuto) rt.panAuto.push_back({p.frame, p.value});
        for (const auto &lane : t.pluginAuto) {
            auto it = instances.find(lane.slot);
            if (it == instances.end() || !it->second || lane.points.empty()) continue;
            RenderTrack::PluginLane pl;
            pl.plugin = it->second.get();
            pl.param = lane.param;
            if (!pl.plugin->automationRange(lane.param, pl.lo, pl.hi)) continue;
            for (const auto &p : lane.points) pl.pts.push_back({p.frame, p.value});
            rt.pluginAuto.push_back(std::move(pl));
        }
        rt.instrument = t.kind == kTrackInstrument;
        if (rt.instrument && t.armed) s->liveTrack = static_cast<int32_t>(s->tracks.size());
        for (const auto &slot : t.plugins) {
            auto it = instances.find(slot.id);
            if (it == instances.end() || !it->second) continue; // missing plugin: insert bypassed, instrument silent
            if (slot.bypassed) continue;                          // bypassed by the user: same as missing
            rt.keep.push_back(it->second);
            rt.latency += static_cast<int32_t>(std::min<uint32_t>(it->second->latency(), 1u << 20));
            if (slot.instrument && rt.instrument) rt.instrumentPlugin = it->second.get();
            else if (!slot.instrument) rt.inserts.push_back(it->second.get());
        }
        // A missing or bypassed instrument must not silently substitute the built-in synth.
        if (rt.instrument && !rt.instrumentPlugin && std::any_of(t.plugins.begin(), t.plugins.end(), [](const PluginSlot &p) { return p.instrument; }))
            rt.instrument = false;
        // Clip-derived content: reused from the previous live snapshot when none of the track's clip inputs
        // changed (A-04); offline renders always build fresh.
        const auto &trackClips = clipsByTrack[t.id];
        std::shared_ptr<const TrackContent> content;
        if (live) {
            seen.insert(t.id);
            ContentEntry &entry = content_[t.id];
            bool hit = entry.content && entry.instrument == rt.instrument && entry.clips.size() == trackClips.size();
            for (size_t k = 0; hit && k < trackClips.size(); ++k) hit = sameInputs(entry.clips[k], *trackClips[k]);
            if (!hit) {
                entry.instrument = rt.instrument;
                entry.clips.clear();
                entry.clips.reserve(trackClips.size());
                for (const ClipState *cp : trackClips) {
                    const ClipState &c = *cp;
                    ClipKey k;
                    k.id = c.id; k.slot = c.slot; k.follow = c.follow; k.followLoops = c.followLoops; k.fadeCurve = c.fadeCurve;
                    k.muted = c.muted; k.alt = c.alt; k.preservePitch = c.preservePitch; k.notes = c.notes; k.mediaId = c.media;
                    k.start = c.start; k.offset = c.offset; k.length = c.length; k.fadeIn = c.fadeIn; k.fadeOut = c.fadeOut;
                    k.gainDb = c.gainDb; k.pitch = c.pitch; k.rate = c.rate;
                    if (const PoolEntry *pe = c.midi() ? nullptr : pool(c.media); pe && pe->handle->impl) {
                        k.media = pe->handle->impl;
                        k.derived = resolvedStretch(c, k.media.get());
                    }
                    entry.clips.push_back(std::move(k));
                }
                entry.needed.clear();
                entry.content = buildContent(trackClips, rt.instrument, entry.needed);
            }
            if (needed) needed->insert(needed->end(), entry.needed.begin(), entry.needed.end());
            content = entry.content;
        } else {
            std::vector<StretchJob> jobs;
            content = buildContent(trackClips, rt.instrument, jobs);
            if (needed) needed->insert(needed->end(), jobs.begin(), jobs.end());
        }
        rt.mutedMidiSignature = content->mutedMidiSignature;
        if (content->stereoClip) rt.monoSource = false;
        rt.content = std::move(content);
        s->tracks.push_back(std::move(rt));
    }
    if (live) // forget content for tracks that no longer exist
        for (auto it = content_.begin(); it != content_.end();)
            it = seen.count(it->first) ? std::next(it) : content_.erase(it);
    // Sidechains: number the source tracks and point listening plug-ins at their buffers.
    {
        std::map<DalnokTrackId, int32_t> scIndex;
        for (size_t i = 0; i < order.size(); ++i)
            for (const auto &slot : order[i]->plugins) {
                if (!slot.sidechain || slot.bypassed || !indexOf.count(slot.sidechain)) continue;
                auto it = instances.find(slot.id);
                if (it == instances.end() || !it->second || !it->second->hasSidechain()) continue;
                auto [sc, fresh] = scIndex.try_emplace(slot.sidechain, static_cast<int32_t>(scIndex.size()));
                s->tracks[static_cast<size_t>(indexOf[slot.sidechain])].scSlot = sc->second;
                s->tracks[i].sidechainFeeds.push_back({it->second.get(), sc->second});
                (void)fresh;
            }
        s->scL.assign(scIndex.size() * kMaxBlock, 0.0f);
        s->scR.assign(scIndex.size() * kMaxBlock, 0.0f);
    }
    // Resolve outputs and sends to processing indices (a missing destination falls back to the master).
    int32_t buses = 0;
    for (size_t i = 0; i < order.size(); ++i) {
        RenderTrack &rt = s->tracks[i];
        const TrackState &t = *order[i];
        if (rt.bus) rt.busSlot = buses++;
        auto out = indexOf.find(t.output);
        rt.output = t.output && out != indexOf.end() ? out->second : -1;
        for (const auto &snd : t.sends)
            if (auto d = indexOf.find(snd.bus); d != indexOf.end())
                rt.sends.push_back({d->second, dbToGain(snd.db), snd.pre});
    }
    for (auto &rt : s->tracks) {
        if (rt.output >= 0) rt.output = s->tracks[static_cast<size_t>(rt.output)].busSlot;
        for (auto &snd : rt.sends) snd.slot = s->tracks[static_cast<size_t>(snd.slot)].busSlot;
    }
    // Solo links: everything reachable downstream (outputs, sends) and upstream (what feeds this track).
    std::map<DalnokTrackId, std::vector<DalnokTrackId>> down, up;
    for (const TrackState *tp : order) {
        if (tp->output) { down[tp->id].push_back(tp->output); up[tp->output].push_back(tp->id); }
        for (const auto &snd : tp->sends) { down[tp->id].push_back(snd.bus); up[snd.bus].push_back(tp->id); }
    }
    auto reach = [](const std::map<DalnokTrackId, std::vector<DalnokTrackId>> &g, DalnokTrackId from, std::set<DalnokTrackId> &out) {
        std::vector<DalnokTrackId> stack{from};
        while (!stack.empty()) {
            const auto id = stack.back(); stack.pop_back();
            if (auto it = g.find(id); it != g.end())
                for (auto n : it->second) if (out.insert(n).second) stack.push_back(n);
        }
    };
    for (size_t i = 0; i < order.size(); ++i) {
        std::set<DalnokTrackId> linked;
        reach(down, order[i]->id, linked);
        reach(up, order[i]->id, linked);
        linked.erase(order[i]->id);
        for (auto id : linked)
            if (auto it = indexOf.find(id); it != indexOf.end()) s->tracks[i].soloLinks.push_back(s->tracks[static_cast<size_t>(it->second)].runtime.get());
    }
    // Plug-in delay compensation. Order is topological (sources, then buses after everything feeding them):
    // a bus starts when its latest input arrives; every connection is delayed so all inputs of a bus (and of
    // the master) arrive together. Live delay lines persist across snapshots (keyed by connection and length);
    // offline renders (live == false) get fresh ones.
    std::vector<int64_t> start(order.size(), 0);
    std::vector<std::vector<std::pair<size_t, int32_t>>> into(order.size()); // dest index → (src index, send index or -1)
    std::vector<std::pair<size_t, int32_t>> intoMaster;
    std::vector<int32_t> slotOwner(static_cast<size_t>(buses), -1);
    for (size_t i = 0; i < order.size(); ++i) if (s->tracks[i].bus) slotOwner[static_cast<size_t>(s->tracks[i].busSlot)] = static_cast<int32_t>(i);
    for (size_t i = 0; i < order.size(); ++i) {
        const RenderTrack &rt = s->tracks[i];
        if (rt.output < 0) intoMaster.push_back({i, -1});
        else into[static_cast<size_t>(slotOwner[static_cast<size_t>(rt.output)])].push_back({i, -1});
        for (size_t k = 0; k < rt.sends.size(); ++k)
            if (rt.sends[k].slot >= 0) into[static_cast<size_t>(slotOwner[static_cast<size_t>(rt.sends[k].slot)])].push_back({i, static_cast<int32_t>(k)});
    }
    for (size_t i = 0; i < order.size(); ++i)
        for (const auto &[src, sendIndex] : into[i]) start[i] = std::max(start[i], start[src] + s->tracks[src].latency);
    int64_t master = 0;
    for (const auto &[src, sendIndex] : intoMaster) master = std::max(master, start[src] + s->tracks[src].latency);
    s->compensation = static_cast<int32_t>(std::min<int64_t>(master, 1 << 20));
    auto delayFor = [&](size_t src, int32_t sendIndex, int64_t arrival) -> DelayLine * {
        const int64_t d = arrival - (start[src] + s->tracks[src].latency);
        if (d <= 0) return nullptr;
        std::shared_ptr<DelayLine> line;
        const std::string key = std::to_string(order[src]->id) + (sendIndex < 0 ? ":out" : ":send" + std::to_string(sendIndex)) + ":" + std::to_string(d);
        if (live) {
            auto &cached = delays_[key];
            if (!cached) cached = std::make_shared<DelayLine>(static_cast<int32_t>(d));
            line = cached;
        } else {
            line = std::make_shared<DelayLine>(static_cast<int32_t>(d));
        }
        s->delayKeep.push_back(line);
        return line.get();
    };
    for (size_t i = 0; i < order.size(); ++i)
        for (const auto &[src, sendIndex] : into[i]) {
            DelayLine *d = delayFor(src, sendIndex, start[i]);
            if (sendIndex < 0) s->tracks[src].outDelay = d; else s->tracks[src].sends[static_cast<size_t>(sendIndex)].delay = d;
        }
    for (const auto &[src, sendIndex] : intoMaster) s->tracks[src].outDelay = delayFor(src, -1, master);
    if (live) // forget delay lines no snapshot can use any more
        for (auto it = delays_.begin(); it != delays_.end();)
            it = it->second.use_count() == 1 && std::none_of(s->delayKeep.begin(), s->delayKeep.end(),
                                                             [&](const auto &k) { return k == it->second; })
                     ? delays_.erase(it) : std::next(it);
    s->chainL.assign(s->tracks.size() * kMaxBlock, 0.0f);
    s->chainR.assign(s->tracks.size() * kMaxBlock, 0.0f);
    s->steps.assign(s->tracks.size(), TrackStep{});
    s->busL.assign(static_cast<size_t>(buses) * kMaxBlock, 0.0f);
    s->busR.assign(static_cast<size_t>(buses) * kMaxBlock, 0.0f);
    return s;
}

} // namespace dalnok
