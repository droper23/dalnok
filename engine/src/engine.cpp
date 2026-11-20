// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"
#include "engine_internal.hpp"
#include <unordered_map>
#include "plugin_remote.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <ctime>
#include <set>
#include <utility>
#include <unistd.h>

namespace dalnok {
using detail::kTransportFadeSeconds;
using detail::nowNs;
using detail::atomicMax;
using detail::FlushDenormals;
using namespace detail;


float dbToGain(float db) { return db <= -96.0f ? 0.0f : std::pow(10.0f, std::min(db, 12.0f) / 20.0f); }

// ---- Model lookups --------------------------------------------------------

TrackState *Model::track(DalnokTrackId id) {
    for (auto &t : tracks) if (t.id == id) return &t;
    return nullptr;
}
const TrackState *Model::track(DalnokTrackId id) const { return const_cast<Model *>(this)->track(id); }
ClipState *Model::clip(DalnokClipId id) {
    for (auto &c : clips) if (c.id == id) return &c;
    return nullptr;
}
const ClipState *Model::clip(DalnokClipId id) const { return const_cast<Model *>(this)->clip(id); }

// ---- Lifecycle ------------------------------------------------------------


Engine::Engine(double sampleRate) : sampleRate_(sampleRate) {
    if (sampleRate_ <= 0) sampleRate_ = defaultOutputSampleRate();
    if (sampleRate_ <= 0) sampleRate_ = 48000.0;
    pluginHost_.setSampleRate(sampleRate_);
    streamPlan_ = std::make_shared<StreamPlan>();
    streamPlan_->position = &transport_.position;
    StreamCache::shared().addPlan(streamPlan_);
    midiParsers_[0] = std::make_unique<MidiParser>();
    midiInputs_[0].store(midiParsers_[0].get(), std::memory_order_release);
    syncRuntimes(); // builds the tempo map: the first snapshot needs the metronome schedule
    commit();
}

Engine::~Engine() {
    StreamCache::shared().removePlan(streamPlan_.get());
    if (rec_.active) { RecordResult ignored; std::string err; stopRecording(ignored, err); }
    stopDevice();
    midiClient_.reset(); // closes Core MIDI ports before the parsers go away
    collectGarbage();
    delete current_;
    delete pending_.exchange(nullptr);
}

// ---- Media pool -----------------------------------------------------------

DalnokMediaId Engine::poolAdd(std::shared_ptr<const Media> media, const std::string &path) {
    if (!media) return 0;
    if (!path.empty())
        for (const auto &[id, e] : pool_)
            if (e.path == path && e.handle->impl) return id;
    const auto id = nextMedia_++;
    PoolEntry &e = pool_[id];
    e.path = path;
    e.frames = media->frames();
    e.channels = media->channelCount();
    e.handle = std::make_unique<DalnokMedia>(DalnokMedia{std::move(media)});
    return id;
}

const PoolEntry *Engine::poolEntry(DalnokMediaId id) const {
    auto it = pool_.find(id);
    return it == pool_.end() ? nullptr : &it->second;
}

int64_t Engine::sessionLength() const {
    int64_t end = 0;
    for (const auto &c : model_.clips) end = std::max(end, c.start + c.length);
    return end;
}

// ---- Edit machinery -------------------------------------------------------


float Engine::parameterValue(DalnokTrackId id, ParameterField field) const {
    if (field == ParameterField::masterGain) return model_.masterGainDb;
    const TrackState *track = model_.track(id);
    switch (field) {
        case ParameterField::gain: return track->gainDb;
        case ParameterField::pan: return track->pan;
        case ParameterField::mute: return track->muted;
        case ParameterField::solo: return track->solo;
        case ParameterField::masterGain: break;
    }
    return 0;
}

void Engine::applyParameter(const ParameterValue &v) {
    const float previous = parameterValue(v.track, v.field);
    setParameterInModel(model_, v);
    if (v.field == ParameterField::masterGain) {
        masterRuntime_->gain.store(dbToGain(v.value), std::memory_order_relaxed);
        return;
    }
    TrackState *track = model_.track(v.track);
    switch (v.field) {
        case ParameterField::gain: track->runtime->gain.store(dbToGain(v.value), std::memory_order_relaxed); break;
        case ParameterField::pan: track->runtime->pan.store(v.value, std::memory_order_relaxed); break;
        case ParameterField::mute: track->runtime->muted.store(v.value != 0, std::memory_order_relaxed); break;
        case ParameterField::solo:
            track->runtime->solo.store(v.value != 0, std::memory_order_relaxed);
            if ((previous != 0) != (v.value != 0)) soloCount_.fetch_add(v.value != 0 ? 1 : -1, std::memory_order_relaxed);
            break;
        case ParameterField::masterGain: break;
    }
}

bool Engine::editParameter(const char *name, DalnokTrackId track, ParameterField field, float value, std::string &err) {
    if (field != ParameterField::masterGain && !model_.track(track)) { err = "no such track"; return false; }
    if (std::isnan(value)) { err = field == ParameterField::pan ? "pan is NaN" : "gain is NaN"; return false; }
    if (field == ParameterField::gain || field == ParameterField::masterGain)
        value = value <= -96.0f ? -INFINITY : std::min(value, 12.0f);
    if (field == ParameterField::pan) value = std::clamp(value, -1.0f, 1.0f);
    ParameterValue old{track, field, parameterValue(track, field)};
    history_.recordParameter(name, old, model_);
    applyParameter({track, field, value});
    ++revision_;
    if (field != ParameterField::masterGain) stampTracks({track});
    markParameterRevision();
    return true;
}

void Engine::syncRuntimes() {
    // The model's tempo map is always valid (edits validate it); fall back to 120 BPM defensively.
    std::string ignored;
    if (!TempoMap::build(sampleRate_, model_.tempo, map_, ignored)) TempoMap::build(sampleRate_, {TempoPoint{}}, map_, ignored);
    // Click oscillators (beats: 1 kHz, bar starts: 1.6 kHz; 35 ms decay). The schedule is in the RenderState.
    const double w = 2 * 3.14159265358979 * 1000.0 / sampleRate_, wa = 2 * 3.14159265358979 * 1600.0 / sampleRate_;
    clickCoef_.store(static_cast<float>(2 * std::cos(w)), std::memory_order_relaxed);
    clickSin_.store(static_cast<float>(std::sin(w)), std::memory_order_relaxed);
    clickAccentCoef_.store(static_cast<float>(2 * std::cos(wa)), std::memory_order_relaxed);
    clickAccentSin_.store(static_cast<float>(std::sin(wa)), std::memory_order_relaxed);
    clickDecay_.store(static_cast<float>(std::exp(-1.0 / (0.012 * sampleRate_))), std::memory_order_relaxed);
    int32_t solos = 0;
    masterRuntime_->gain.store(dbToGain(model_.masterGainDb), std::memory_order_relaxed);
    for (const auto &t : model_.tracks) {
        t.runtime->gain.store(dbToGain(t.gainDb), std::memory_order_relaxed);
        t.runtime->pan.store(t.pan, std::memory_order_relaxed);
        t.runtime->muted.store(t.muted, std::memory_order_relaxed);
        t.runtime->solo.store(t.solo, std::memory_order_relaxed);
        solos += t.solo;
    }
    soloCount_.store(solos, std::memory_order_relaxed);
}

void Engine::restore(Model m) {
    const Model before = std::exchange(model_, std::move(m));
    const auto changed = changedTracks(before);
    syncRuntimes();
    ++revision_;
    stampTracks(changed);
    commit();
}

std::vector<DalnokTrackId> Engine::changedTracks(const Model &before) const {
    // A track changed if its own state or its clips (in z-order) differ. O(tracks + clips) comparisons.
    std::map<DalnokTrackId, std::vector<const ClipState *>> oldClips, newClips;
    for (const auto &c : before.clips) oldClips[c.track].push_back(&c);
    for (const auto &c : model_.clips) newClips[c.track].push_back(&c);
    std::map<DalnokTrackId, const TrackState *> oldTracks;
    for (const auto &t : before.tracks) oldTracks[t.id] = &t;
    std::vector<DalnokTrackId> out;
    for (const auto &t : model_.tracks) {
        auto old = oldTracks.find(t.id);
        const auto &a = oldClips[t.id], &b = newClips[t.id];
        const bool same = old != oldTracks.end() && *old->second == t &&
                          std::equal(a.begin(), a.end(), b.begin(), b.end(), [](const ClipState *x, const ClipState *y) { return *x == *y; });
        if (!same) out.push_back(t.id);
    }
    return out;
}

void Engine::applyUndo(bool undo) {
    UndoStack::Step step = history_.take(undo);
    if (step.snapshot()) {
        Model target = UndoStack::target(step, model_);
        history_.pushInverse(undo, UndoStack::Step(step.name, std::make_unique<Model>(model_), {}), model_);
        restore(std::move(target));
    } else {
        UndoStack::Step inverse(step.name, nullptr, {});
        inverse.parameters.reserve(step.parameters.size());
        for (const auto &v : step.parameters) {
            inverse.parameters.push_back({v.track, v.field, parameterValue(v.track, v.field)});
            applyParameter(v);
        }
        history_.pushInverse(undo, std::move(inverse), model_); // model_ already holds the parameters' undone values
        ++revision_;
        for (const auto &v : step.parameters) if (v.field != ParameterField::masterGain) stampTracks({v.track});
        markParameterRevision();
    }
}

bool Engine::undo() {
    history_.closeGroups();
    if (!history_.canUndo()) return false;
    applyUndo(true);
    return true;
}

bool Engine::redo() {
    history_.closeGroups();
    if (!history_.canRedo()) return false;
    applyUndo(false);
    return true;
}

void Engine::beginGroup(const std::string &name) { history_.beginGroup(name); }

void Engine::endGroup() { history_.endGroup(); }

void Engine::resetModel() {
    model_ = Model{};
    clipboard_.clear(); // clips refer to this project's media
    pluginHost_.clear(); // snapshots still holding instances release them on this thread
    pool_.clear();
    cache_.clear();
    history_.clear();
    nextColor_ = 0;
    transport_.cycleOn.store(false, std::memory_order_release);
    transport_.cycleStart.store(0, std::memory_order_relaxed);
    transport_.cycleEnd.store(0, std::memory_order_relaxed);
    syncRuntimes();
    bumpRevisionAll();
    savedRevision_ = revision_;
}

void Engine::newProject() {
    resetModel();
    commit();
}

// ---- Commands -------------------------------------------------------------

namespace detail {
bool fail(std::string &err, const char *msg) {
    err = msg;
    return false;
}
std::string stem(const std::string &path) {
    const auto slash = path.find_last_of('/');
    std::string base = slash == std::string::npos ? path : path.substr(slash + 1);
    const auto dot = base.find_last_of('.');
    return dot == std::string::npos || dot == 0 ? base : base.substr(0, dot);
}
} // namespace detail

DalnokTrackId Engine::addTrack(const std::string &name, std::string &err) {
    const auto id = nextTrack_;
    const bool ok = edit("New Track", true, [&](Model &m) {
        TrackState t;
        t.id = id;
        t.name = name.empty() ? "Track " + std::to_string(m.tracks.size() + 1) : name;
        // Continue the gradient from the track above, so neighbors never share a color.
        t.color = m.tracks.empty() ? 0 : m.tracks.back().color + 1;
        t.runtime = std::make_shared<TrackRuntime>();
        m.tracks.push_back(std::move(t));
        return true;
    });
    if (!ok) return fail(err, "could not add track"), 0;
    ++nextTrack_;
    ++nextColor_;
    return id;
}

DalnokTrackId Engine::addInstrumentTrack(const std::string &name, std::string &err) {
    const auto id = nextTrack_;
    const bool ok = edit("New Instrument Track", true, [&](Model &m) {
        TrackState t;
        t.id = id;
        t.kind = kTrackInstrument;
        t.name = name.empty() ? "Instrument " + std::to_string(m.tracks.size() + 1) : name;
        t.color = m.tracks.empty() ? 0 : m.tracks.back().color + 1;
        t.runtime = std::make_shared<TrackRuntime>();
        // A new instrument track plays live MIDI input right away (one armed instrument track).
        for (auto &other : m.tracks) if (other.kind == kTrackInstrument) other.armed = false;
        t.armed = true;
        m.tracks.push_back(std::move(t));
        return true;
    });
    if (!ok) return fail(err, "could not add track"), 0;
    ++nextTrack_;
    ++nextColor_;
    return id;
}

bool Engine::setArmed(DalnokTrackId id, bool armed, std::string &err) {
    if (rec_.active) return fail(err, "cannot change record arm while recording");
    return edit(armed ? "Record Enable" : "Record Disable", true, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        // Any number of audio tracks record at once (one device input each); one instrument track takes MIDI.
        if (armed && t->kind == kTrackInstrument)
            for (auto &other : m.tracks) if (other.kind == t->kind) other.armed = false;
        t->armed = armed;
        return true;
    });
}

bool Engine::setInputChannel(DalnokTrackId id, int32_t channel, std::string &err) {
    if (rec_.active) return fail(err, "cannot change input while recording");
    return edit("Track Input", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        if (t->kind != kTrackAudio) return fail(err, "only audio tracks have an audio input");
        if (channel < 0 || channel > 63) return fail(err, "input channel must be 0-63");
        t->inputChannel = channel;
        return true;
    });
}

bool Engine::removeClips(const std::vector<DalnokClipId> &ids, std::string &err) {
    if (ids.empty()) return fail(err, "no clips selected");
    std::set<DalnokClipId> unique;
    for (auto id : ids) {
        if (!model_.clip(id)) return fail(err, "no such clip");
        if (!unique.insert(id).second) return fail(err, "duplicate clip id");
    }
    return edit("Delete Clips", true, [&](Model &m) {
        std::erase_if(m.clips, [&](const ClipState &clip) { return unique.count(clip.id) != 0; });
        return true;
    });
}

bool Engine::nudgeClips(const std::vector<DalnokClipId> &ids, int64_t delta, std::string &err) {
    if (ids.empty()) return fail(err, "no clips selected");
    std::set<DalnokClipId> unique;
    int64_t earliest = INT64_MAX;
    for (auto id : ids) {
        const ClipState *clip = model_.clip(id);
        if (!clip) return fail(err, "no such clip");
        if (!unique.insert(id).second) return fail(err, "duplicate clip id");
        earliest = std::min(earliest, clip->start);
    }
    if (delta < 0) delta = std::max(delta, -earliest);
    if (delta > 0) {
        for (auto id : ids) {
            const ClipState *clip = model_.clip(id);
            if (clip->length > INT64_MAX - clip->start || delta > INT64_MAX - clip->start - clip->length)
                return fail(err, "nudge exceeds the supported timeline");
        }
    }
    if (delta == 0) return true;
    return edit("Nudge Clips", true, [&](Model &m) {
        for (auto id : ids) m.clip(id)->start += delta;
        return true;
    });
}

namespace detail {
// Moves every MIDI clip and note so it keeps its beat position under `to`. Clips that share a note
// list and a source origin (split pieces) keep sharing one remapped list.
bool remapMidi(Model &m, const TempoMap &from, const TempoMap &to, std::string &err) {
    auto remap = [&](int64_t frame, int64_t &out) {
        double beat;
        return from.frameToBeat(frame, beat) && to.beatToFrame(beat, out);
    };
    std::map<std::pair<const std::vector<MidiNote> *, int64_t>, NoteList> lists;
    for (auto &clip : m.clips) {
        if (!clip.midi()) continue;
        const int64_t origin = clip.start - clip.offset;
        int64_t newOrigin, start, end;
        if (clip.length > INT64_MAX / 4 || !remap(origin, newOrigin) || !remap(clip.start, start) ||
            !remap(clip.start + clip.length, end) || start < 0)
            return fail(err, "tempo change would move MIDI beyond the supported timeline");
        const auto key = std::make_pair(clip.notes.get(), origin);
        auto found = lists.find(key);
        if (found == lists.end()) {
            std::vector<MidiNote> notes = *clip.notes;
            for (auto &note : notes) {
                int64_t a, b;
                if (!remap(origin + note.start, a) || !remap(origin + note.start + note.length, b))
                    return fail(err, "tempo change would move MIDI beyond the supported timeline");
                note.start = std::max<int64_t>(0, a - newOrigin);
                note.length = std::max<int64_t>(1, b - a);
            }
            found = lists.emplace(key, std::make_shared<const std::vector<MidiNote>>(std::move(notes))).first;
        }
        clip.start = start;
        clip.offset = std::max<int64_t>(0, start - newOrigin);
        clip.length = std::max<int64_t>(1, end - start);
        clip.notes = found->second;
    }
    return true;
}
} // namespace detail

bool Engine::setTempo(double bpm, int32_t num, int32_t den, std::string &err) {
    auto tempo = model_.tempo;
    auto meters = model_.meters;
    tempo.front().bpm = bpm;
    meters.front().num = num;
    meters.front().den = den;
    return setTempoMap(std::move(tempo), std::move(meters), err);
}

bool Engine::setTempoMap(std::vector<TempoPoint> tempo, std::vector<MeterChange> meters, std::string &err) {
    TempoMap next;
    if (!TempoMap::build(sampleRate_, tempo, next, err)) return false;
    if (!validMeters(meters, err)) return false;
    if (tempo.size() > 10000 || meters.size() > 10000) return fail(err, "too many tempo or meter changes");
    return edit("Tempo", true, [&](Model &m) {
        if (!remapMidi(m, map_, next, err)) return false;
        m.tempo = std::move(tempo);
        m.meters = std::move(meters);
        return true;
    });
}

bool Engine::validNotes(const std::vector<MidiNote> &notes, std::string &err) const {
    for (const auto &n : notes)
        if (n.start < 0 || n.length <= 0 || n.pitch > 127 || n.velocity < 1 || n.velocity > 127)
            return fail(err, "notes need start >= 0, length > 0, pitch 0-127, velocity 1-127");
    return true;
}

namespace detail {
NoteList sortedNotes(std::vector<MidiNote> notes) {
    std::stable_sort(notes.begin(), notes.end(), [](const MidiNote &a, const MidiNote &b) {
        return a.start < b.start || (a.start == b.start && a.pitch < b.pitch);
    });
    return std::make_shared<const std::vector<MidiNote>>(std::move(notes));
}
} // namespace detail

DalnokClipId Engine::addMidiClip(DalnokTrackId track, int64_t start, int64_t length, std::string &err,
                                 std::vector<MidiNote> notes, const char *undoName) {
    if (!validNotes(notes, err)) return 0;
    const auto id = nextClip_;
    const bool ok = edit(undoName, true, [&](Model &m) {
        const TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        if (t->kind != kTrackInstrument) return fail(err, "MIDI clips go on instrument tracks");
        if (start < 0 || length <= 0) return fail(err, "start must be >= 0 and length > 0");
        ClipState c;
        c.id = id;
        c.track = track;
        c.start = start;
        c.length = length;
        c.notes = sortedNotes(std::move(notes));
        c.name = t->name; // like a region: named after its track until renamed
        m.clips.push_back(std::move(c));
        return true;
    });
    if (!ok) return 0;
    ++nextClip_;
    return id;
}

bool Engine::setNotes(DalnokClipId id, std::vector<MidiNote> notes, std::string &err) {
    if (!validNotes(notes, err)) return false;
    return edit("Edit Notes", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        if (!c->midi()) return fail(err, "not a MIDI clip");
        c->notes = sortedNotes(std::move(notes));
        return true;
    });
}

bool Engine::quantize(DalnokClipId id, double gridBeats, double strength, std::string &err) {
    return edit("Quantize", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        if (!c->midi()) return fail(err, "not a MIDI clip");
        if (!(gridBeats >= 1.0 / 64 && gridBeats <= 16) || !(strength > 0 && strength <= 1))
            return fail(err, "grid must be 1/64-16 beats and strength 0-1");
        // The grid is in beats from the timeline origin (bar 1), not the clip, and follows the tempo map.
        const auto origin = c->start - c->offset;
        std::vector<MidiNote> notes = *c->notes;
        for (auto &n : notes) {
            const int64_t at = origin + n.start;
            double beat;
            int64_t snapped;
            if (!map_.frameToBeat(at, beat) || !map_.beatToFrame(std::round(beat / gridBeats) * gridBeats, snapped))
                return fail(err, "note is beyond the supported timeline");
            const double moved = static_cast<double>(at) + static_cast<double>(snapped - at) * strength;
            n.start = std::max<int64_t>(0, static_cast<int64_t>(std::llround(moved)) - origin);
        }
        c->notes = sortedNotes(std::move(notes));
        return true;
    });
}

// ---- Plugins ----------------------------------------------------------------

int32_t Engine::addPlugin(DalnokTrackId track, const std::string &path, const std::string &classId, std::string &err) {
    const TrackState *t = model_.track(track);
    if (!t) return fail(err, "no such track"), 0;
    // "au:type:subtype:manufacturer" names an Audio Unit, "dalnok:<id>" a built-in plug-in (ADR-0011); a ".clap"
    // bundle is CLAP; anything else is a VST3 bundle.
    const bool au = path.rfind("au:", 0) == 0, builtin = path.rfind("dalnok:", 0) == 0;
    const bool clap = !au && !builtin && path.size() > 5 && path.compare(path.size() - 5, 5, ".clap") == 0;
    const std::string format = au ? "au" : builtin ? "dalnok" : clap ? "clap" : "vst3";
    const std::string location = au ? path.substr(3) : builtin ? path.substr(7) : path;
    std::shared_ptr<PluginProcessor> instance(pluginHost_.create(format, location, classId, false, err));
    if (!instance) return 0;
    if (instance->instrument() && t->kind != kTrackInstrument) return fail(err, "instrument plug-ins go on instrument tracks"), 0;
    const int32_t id = nextPlugin_;
    PluginSlot slot;
    slot.id = id;
    slot.format = format;
    slot.path = location;
    slot.classId = instance->classId();
    slot.name = instance->name();
    slot.vendor = instance->vendor();
    slot.instrument = instance->instrument();
    std::string initialState;
    instance->getState(initialState);
    slot.state.assign(std::move(initialState));
    pluginHost_.insert(id, std::move(instance));
    const bool ok = edit(slot.instrument ? "Set Instrument" : "Add Plug-in", true, [&](Model &m) {
        TrackState *tr = m.track(track);
        if (!tr) return fail(err, "no such track");
        if (slot.instrument) {
            std::erase_if(tr->plugins, [](const PluginSlot &p) { return p.instrument; }); // replaces the instrument
            tr->plugins.insert(tr->plugins.begin(), slot);
        } else {
            tr->plugins.push_back(slot);
        }
        return true;
    });
    if (!ok) { pluginHost_.erase(id); return 0; }
    ++nextPlugin_;
    return id;
}

// ---- Auditioning notes (piano roll) ---------------------------------------------

bool Engine::previewNote(DalnokTrackId track, uint8_t pitch, uint8_t velocity, bool on) {
    const TrackState *t = model_.track(track);
    if (!t || t->kind != kTrackInstrument || pitch > 127) return false;
    std::lock_guard<std::mutex> g(previewProducer_);
    return previewNotes_.push(PreviewNote{track, pitch, static_cast<uint8_t>(std::min<int>(velocity, 127)), on && velocity > 0});
}

// ---- Markers ----------------------------------------------------------------

static void sortMarkers(std::vector<Marker> &ms) {
    std::stable_sort(ms.begin(), ms.end(), [](const Marker &a, const Marker &b) { return a.frame < b.frame; });
}

int32_t Engine::addMarker(int64_t frame, const std::string &name, std::string &err) {
    if (frame < 0) return fail(err, "a marker needs a position >= 0"), 0;
    const int32_t id = nextMarker_;
    const bool ok = edit("Add Marker", false, [&](Model &m) {
        m.markers.push_back({id, frame, name.empty() ? "Marker " + std::to_string(m.markers.size() + 1) : name});
        sortMarkers(m.markers);
        return true;
    });
    if (!ok) return 0;
    ++nextMarker_;
    return id;
}
bool Engine::removeMarker(int32_t id, std::string &err) {
    return edit("Delete Marker", false, [&](Model &m) {
        const auto before = m.markers.size();
        std::erase_if(m.markers, [id](const Marker &x) { return x.id == id; });
        return m.markers.size() != before || fail(err, "no such marker");
    });
}
bool Engine::moveMarker(int32_t id, int64_t frame, std::string &err) {
    if (frame < 0) return fail(err, "a marker needs a position >= 0");
    return edit("Move Marker", false, [&](Model &m) {
        auto it = std::find_if(m.markers.begin(), m.markers.end(), [id](const Marker &x) { return x.id == id; });
        if (it == m.markers.end()) return fail(err, "no such marker");
        it->frame = frame;
        sortMarkers(m.markers);
        return true;
    });
}
bool Engine::renameMarker(int32_t id, const std::string &name, std::string &err) {
    if (name.empty()) return fail(err, "a marker needs a name");
    return edit("Rename Marker", false, [&](Model &m) {
        auto it = std::find_if(m.markers.begin(), m.markers.end(), [id](const Marker &x) { return x.id == id; });
        if (it == m.markers.end()) return fail(err, "no such marker");
        it->name = name;
        return true;
    });
}

DalnokTrackId Engine::duplicateTrack(DalnokTrackId track, std::string &err) {
    const TrackState *src = model_.track(track);
    if (!src) return fail(err, "no such track"), 0;
    if (src->isStack) return fail(err, "duplicate the tracks inside a stack one by one"), 0;
    // New plug-in instances first (loading plug-in code can't happen inside a model edit).
    std::vector<PluginSlot> slots;
    std::map<int32_t, int32_t> slotMap;
    std::vector<std::pair<int32_t, std::shared_ptr<PluginProcessor>>> made;
    int32_t nextSlot = nextPlugin_;
    for (const auto &p : src->plugins) {
        PluginSlot s = p;
        s.id = nextSlot++;
        slotMap[p.id] = s.id;
        std::string state;
        if (!pluginState(p.id, state)) state = p.state.str();
        s.state.assign(state);
        std::string loadErr;
        if (pluginInstance(p.id)) {
            std::shared_ptr<PluginProcessor> inst(pluginHost_.create(p.format, p.path, p.classId, false, loadErr));
            if (inst) { if (!state.empty()) inst->setState(state); made.emplace_back(s.id, std::move(inst)); }
        }
        slots.push_back(std::move(s));
    }
    const auto id = nextTrack_;
    const auto firstClip = nextClip_;
    DalnokClipId nextClipId = firstClip;
    for (auto &[sid, inst] : made) pluginHost_.insert(sid, inst); // before the edit: it compiles the new render state
    const bool ok = edit("Duplicate Track", true, [&](Model &m) {
        auto it = std::find_if(m.tracks.begin(), m.tracks.end(), [track](const TrackState &t) { return t.id == track; });
        if (it == m.tracks.end()) return fail(err, "no such track");
        TrackState t = *it;
        t.id = id;
        t.name = it->name + " copy";
        t.solo = false;
        t.armed = false;
        t.customColor = it->customColor;
        t.runtime = std::make_shared<TrackRuntime>();
        t.plugins = slots;
        for (auto &l : t.pluginAuto) l.slot = slotMap.count(l.slot) ? slotMap[l.slot] : l.slot;
        std::vector<ClipState> copies;
        for (const auto &c : m.clips) {
            if (c.track != track || c.alt || c.folder != 0) continue; // take folders stay with the original
            ClipState d = c;
            d.id = nextClipId++;
            d.track = id;
            copies.push_back(std::move(d));
        }
        // Tracks fed by sidechains or sending to this one keep pointing at the original.
        m.tracks.insert(it + 1, std::move(t));
        for (auto &c : copies) m.clips.push_back(std::move(c));
        return true;
    });
    if (!ok) { for (auto &[sid, inst] : made) pluginHost_.erase(sid); return 0; }
    nextPlugin_ = nextSlot;
    nextClip_ = nextClipId;
    ++nextTrack_;
    syncRuntimes();
    bumpRevisionAll();
    return id;
}

bool Engine::removePlugin(DalnokTrackId track, int32_t id, std::string &err) {
    return edit("Remove Plug-in", true, [&](Model &m) {
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        const auto before = t->plugins.size();
        std::erase_if(t->plugins, [id](const PluginSlot &p) { return p.id == id; });
        if (t->plugins.size() == before) return fail(err, "no such plug-in");
        std::erase_if(t->pluginAuto, [id](const PluginAuto &l) { return l.slot == id; });
        return true; // the instance stays loaded for undo
    });
}

bool Engine::setPluginControls(DalnokTrackId track, int32_t id, std::vector<uint32_t> ids, std::string &err) {
    if (ids.size() > 32) return fail(err, "at most 32 controls");
    return edit("Edit Controls", false, [&](Model &m) {
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        for (auto &slot : t->plugins)
            if (slot.id == id) { slot.controls = ids; return true; }
        return fail(err, "no such plug-in");
    });
}

PluginProcessor *Engine::pluginInstance(int32_t id) const { return pluginHost_.instance(id); }

std::string Engine::pluginError(int32_t id) const { return pluginHost_.error(id); }

bool Engine::pluginState(int32_t id, std::string &bytes) const { return pluginHost_.state(model_, id, bytes); }

bool Engine::setPluginState(int32_t id, const std::string &bytes, std::string &err) {
    PluginProcessor *p = pluginInstance(id);
    if (!p) return fail(err, "no such plug-in, or it is not loaded");
    if (!p->setState(bytes)) return fail(err, "the plug-in rejected the state");
    bumpRevisionAll(); // plugin state is saved with the project, so the project changed
    return true;
}

void Engine::instantiatePlugins() {
    for (const auto &t : model_.tracks)
        for (const auto &slot : t.plugins) nextPlugin_ = std::max(nextPlugin_, slot.id + 1);
    pluginHost_.instantiateMissing(model_);
}

int32_t Engine::activateNextPlugin(int32_t &slot, double &seconds) {
    bool changed = false;
    const int32_t left = pluginHost_.activateNext(model_, slot, seconds, changed);
    if (changed) {
        bumpRevisionKeepingSaved(); // loaded state and latency are visible to the UI; not an edit
        commit();
    }
    return left;
}

bool Engine::pluginLoading(int32_t slot) const { return pluginHost_.loading(slot); }

void Engine::cancelPendingPlugins() {
    if (pluginHost_.cancelPending()) bumpRevisionKeepingSaved();
}

void Engine::bumpRevisionKeepingSaved() {
    const bool clean = revision_ == savedRevision_;
    bumpRevisionAll();
    if (clean) savedRevision_ = revision_;
}

bool Engine::reloadPlugin(int32_t id, std::string &err) {
    const bool ok = pluginHost_.reload(model_, id, err);
    if (err == "no such plug-in slot") return false;
    bumpRevisionKeepingSaved();
    commit();
    return ok;
}

namespace detail {
// True if routing `from` into `to` (as its output or a send) would let `to` reach `from` again.
bool feedsBack(const Model &m, DalnokTrackId from, DalnokTrackId to) {
    std::vector<DalnokTrackId> stack{to};
    std::set<DalnokTrackId> seen;
    while (!stack.empty()) {
        const auto id = stack.back();
        stack.pop_back();
        if (id == from) return true;
        if (!seen.insert(id).second) continue;
        const TrackState *t = m.track(id);
        if (!t) continue;
        if (t->output) stack.push_back(t->output);
        for (const auto &s : t->sends) stack.push_back(s.bus);
        for (const auto &o : m.tracks) // a sidechain source feeds the track that listens to it
            for (const auto &slot : o.plugins) if (slot.sidechain == id) stack.push_back(o.id);
    }
    return false;
}
} // namespace detail

DalnokTrackId Engine::addBusTrack(const std::string &name, std::string &err) {
    const auto id = nextTrack_;
    const bool ok = edit("New Bus", true, [&](Model &m) {
        TrackState t;
        t.id = id;
        t.kind = kTrackBus;
        int buses = 0;
        for (const auto &o : m.tracks) buses += o.kind == kTrackBus;
        t.name = name.empty() ? "Bus " + std::to_string(buses + 1) : name;
        t.color = m.tracks.empty() ? 0 : m.tracks.back().color + 1;
        t.runtime = std::make_shared<TrackRuntime>();
        m.tracks.push_back(std::move(t));
        return true;
    });
    if (!ok) return fail(err, "could not add bus"), 0;
    ++nextTrack_;
    ++nextColor_;
    return id;
}

bool Engine::setTrackOutput(DalnokTrackId track, DalnokTrackId bus, std::string &err) {
    return edit("Set Output", true, [&](Model &m) {
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        if (bus) {
            const TrackState *b = m.track(bus);
            if (!b || b->kind != kTrackBus) return fail(err, "outputs go to the master or a bus");
            if (feedsBack(m, track, bus)) return fail(err, "that routing would feed the bus back into itself");
        }
        t->output = bus;
        return true;
    });
}

bool Engine::setSend(DalnokTrackId track, DalnokTrackId bus, float db, bool pre, std::string &err) {
    return edit("Send", true, [&](Model &m) {
        TrackState *t = m.track(track);
        const TrackState *b = m.track(bus);
        if (!t) return fail(err, "no such track");
        if (!b || b->kind != kTrackBus) return fail(err, "sends go to a bus");
        if (!(db <= 6.0f) || std::isnan(db)) return fail(err, "send level must be at most +6 dB");
        auto it = std::find_if(t->sends.begin(), t->sends.end(), [bus](const Send &s) { return s.bus == bus; });
        if (it == t->sends.end()) {
            if (t->sends.size() >= 16) return fail(err, "16 sends per track at most");
            if (feedsBack(m, track, bus)) return fail(err, "that send would feed the bus back into itself");
            t->sends.push_back({bus, db, pre});
        } else {
            it->db = db;
            it->pre = pre;
        }
        return true;
    });
}

bool Engine::setPluginAutomation(DalnokTrackId track, int32_t slot, uint32_t param, std::vector<AutoPoint> points, std::string &err) {
    for (const auto &p : points)
        if (p.frame < 0 || !(p.value >= 0 && p.value <= 1)) return fail(err, "plug-in automation points need frame >= 0 and a value 0-1");
    std::stable_sort(points.begin(), points.end(), [](const AutoPoint &a, const AutoPoint &b) { return a.frame < b.frame; });
    return edit("Plug-in Automation", true, [&](Model &m) {
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        if (std::none_of(t->plugins.begin(), t->plugins.end(), [slot](const PluginSlot &p) { return p.id == slot; }))
            return fail(err, "that plug-in isn't on this track");
        auto it = std::find_if(t->pluginAuto.begin(), t->pluginAuto.end(), [&](const PluginAuto &l) { return l.slot == slot && l.param == param; });
        if (points.empty()) { if (it != t->pluginAuto.end()) t->pluginAuto.erase(it); return true; }
        if (it == t->pluginAuto.end()) t->pluginAuto.push_back({slot, param, std::move(points)});
        else it->points = std::move(points);
        return true;
    });
}

bool Engine::setAutomation(DalnokTrackId track, int32_t target, std::vector<AutoPoint> points, std::string &err) {
    if (target != kAutoVolume && target != kAutoPan) return fail(err, "automation target must be volume (0) or pan (1)");
    if (points.size() > 100000) return fail(err, "too many automation points");
    for (const auto &p : points) {
        if (p.frame < 0 || !std::isfinite(p.value)) return fail(err, "automation points need frame >= 0 and a finite value");
        if (target == kAutoPan && (p.value < -1 || p.value > 1)) return fail(err, "pan automation is -1 to 1");
        if (target == kAutoVolume && p.value > 6) return fail(err, "volume automation is at most +6 dB");
    }
    std::stable_sort(points.begin(), points.end(), [](const AutoPoint &a, const AutoPoint &b) { return a.frame < b.frame; });
    return edit(target == kAutoVolume ? "Volume Automation" : "Pan Automation", true, [&](Model &m) {
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        (target == kAutoVolume ? t->volumeAuto : t->panAuto) = std::move(points);
        return true;
    });
}

namespace detail {
// Rebuilds the clips that play a folder's comp: one piece per segment, cut from its take. A piece that
// follows another starts a little early and fades in over it (an equal-power crossfade, no gap or click).
bool realizeComp(Model &m, const TakeFolder &f, DalnokClipId &nextClip, std::string &err) {
    std::erase_if(m.clips, [&](const ClipState &c) { return c.folder == f.id && !c.alt; });
    constexpr int64_t kXfade = 256;
    int64_t prevEnd = -1;
    for (const auto &seg : f.comp) {
        const ClipState *take = m.clip(f.takes[static_cast<size_t>(seg.take)]);
        if (!take) return fail(err, "a take is missing");
        ClipState piece = *take;
        piece.id = nextClip++;
        piece.alt = false;
        piece.fadeIn = piece.fadeOut = 0;
        piece.fadeCurve = kFadeEqualPower;
        int64_t from = seg.from;
        if (prevEnd == seg.from) { // adjacent to the previous piece: overlap it for the crossfade
            const int64_t back = std::min({kXfade, seg.from - take->start, take->offset + (seg.from - take->start)});
            from -= std::max<int64_t>(0, back);
            piece.fadeIn = seg.from - from;
        }
        piece.start = from;
        piece.offset = take->offset + (from - take->start);
        piece.length = seg.to - from;
        m.clips.push_back(std::move(piece));
        prevEnd = seg.to;
    }
    return true;
}
} // namespace detail

bool Engine::setSidechain(DalnokTrackId track, int32_t slot, DalnokTrackId source, std::string &err) {
    return edit("Sidechain", true, [&](Model &m) {
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        auto it = std::find_if(t->plugins.begin(), t->plugins.end(), [slot](const PluginSlot &p) { return p.id == slot; });
        if (it == t->plugins.end()) return fail(err, "that plug-in isn't on this track");
        if (source) {
            if (!m.track(source) || source == track) return fail(err, "choose another track as the sidechain source");
            if (feedsBack(m, source, track)) return fail(err, "that sidechain would feed the track back into its source");
        }
        it->sidechain = source;
        return true;
    });
}

bool Engine::setPluginBypassed(DalnokTrackId track, int32_t slot, bool bypassed, std::string &err) {
    return edit(bypassed ? "Bypass Plug-in" : "Enable Plug-in", true, [&](Model &m) {
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        auto it = std::find_if(t->plugins.begin(), t->plugins.end(), [slot](const PluginSlot &p) { return p.id == slot; });
        if (it == t->plugins.end()) return fail(err, "that plug-in isn't on this track");
        if (it->bypassed == bypassed) return fail(err, bypassed ? "already bypassed" : "not bypassed");
        it->bypassed = bypassed;
        return true;
    });
}

bool Engine::movePlugin(DalnokTrackId track, int32_t slot, int32_t index, std::string &err) {
    const TrackState *t0 = model_.track(track);
    if (!t0) return fail(err, "no such track");
    const auto from = std::find_if(t0->plugins.begin(), t0->plugins.end(), [slot](const PluginSlot &p) { return p.id == slot; });
    if (from == t0->plugins.end()) return fail(err, "that plug-in isn't on this track");
    if (index < 0 || index >= static_cast<int32_t>(t0->plugins.size())) return fail(err, "position out of range");
    if (from - t0->plugins.begin() == index) return true;
    return edit("Move Plug-in", true, [&](Model &m) {
        auto &list = m.track(track)->plugins;
        auto it = std::find_if(list.begin(), list.end(), [slot](const PluginSlot &p) { return p.id == slot; });
        PluginSlot p = std::move(*it);
        list.erase(it);
        list.insert(list.begin() + index, std::move(p));
        return true;
    });
}

bool Engine::removeSend(DalnokTrackId track, DalnokTrackId bus, std::string &err) {
    return edit("Remove Send", true, [&](Model &m) {
        TrackState *t = m.track(track);
        if (!t) return fail(err, "no such track");
        const auto before = t->sends.size();
        std::erase_if(t->sends, [bus](const Send &s) { return s.bus == bus; });
        if (t->sends.size() == before) return fail(err, "no such send");
        return true;
    });
}

bool Engine::removeTrack(DalnokTrackId id, std::string &err) {
    return edit("Delete Track", true, [&](Model &m) {
        const TrackState *gone = m.track(id);
        if (!gone) return fail(err, "no such track");
        // A deleted stack's members move up to its parent stack (and its output); other buses' sources go to the master.
        const DalnokTrackId parent = gone->isStack ? gone->stack : 0, out = gone->isStack ? gone->output : 0;
        std::erase_if(m.tracks, [id](const TrackState &t) { return t.id == id; });
        std::erase_if(m.folders, [id](const TakeFolder &f) { return f.track == id; });
        for (auto &t : m.tracks) {
            if (t.stack == id) t.stack = parent;
            if (t.output == id) t.output = out;
            std::erase_if(t.sends, [id](const Send &s) { return s.bus == id; });
        }
        std::erase_if(m.clips, [id](const ClipState &c) { return c.track == id; });
        return true;
    });
}

bool Engine::renameTrack(DalnokTrackId id, const std::string &name, std::string &err) {
    return edit("Rename Track", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        if (name.empty()) return fail(err, "name must not be empty");
        t->name = name;
        return true;
    });
}

bool Engine::setMasterGainDb(float db, std::string &err) {
    return editParameter("Master Volume", 0, ParameterField::masterGain, db, err);
}

bool Engine::setGainDb(DalnokTrackId id, float db, std::string &err) {
    return editParameter("Volume", id, ParameterField::gain, db, err);
}

bool Engine::setPan(DalnokTrackId id, float pan, std::string &err) {
    return editParameter("Pan", id, ParameterField::pan, pan, err);
}

bool Engine::setMute(DalnokTrackId id, bool muted, std::string &err) {
    return editParameter(muted ? "Mute" : "Unmute", id, ParameterField::mute, muted, err);
}

bool Engine::setTrackColor(DalnokTrackId id, int32_t customRgb, std::string &err) {
    return edit("Track Color", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        if (customRgb > 0xFFFFFF || customRgb < -1) return fail(err, "color must be 0xRRGGBB or -1");
        t->customColor = customRgb;
        return true;
    });
}

bool Engine::recolorAsGradient(std::string &err) {
    return edit("Recolor Tracks", false, [&](Model &m) {
        if (m.tracks.empty()) return fail(err, "no tracks");
        int32_t step = 0;
        for (auto &t : m.tracks) t.color = step++;
        nextColor_ = step;
        return true;
    });
}

bool Engine::setSolo(DalnokTrackId id, bool solo, std::string &err) {
    return editParameter(solo ? "Solo" : "Unsolo", id, ParameterField::solo, solo, err);
}

bool Engine::moveTrack(DalnokTrackId id, int32_t index, std::string &err) {
    return edit("Move Track", true, [&](Model &m) {
        auto it = std::find_if(m.tracks.begin(), m.tracks.end(), [id](const TrackState &t) { return t.id == id; });
        if (it == m.tracks.end()) return fail(err, "no such track");
        if (index < 0 || index >= static_cast<int32_t>(m.tracks.size())) return fail(err, "index out of range");
        TrackState t = std::move(*it);
        m.tracks.erase(it);
        m.tracks.insert(m.tracks.begin() + index, std::move(t));
        return true;
    });
}

} // namespace dalnok

#ifdef DALNOK_TEST_HOOKS
extern "C" void dalnok_test_handoff_saturation(uint64_t *out) {
    dalnok::handoffSaturationFixture(out);
}
#endif
