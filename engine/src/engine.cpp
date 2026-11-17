// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"

#include <algorithm>
#include <cmath>
#include <ctime>
#include <set>
#include <unistd.h>

namespace dalnok {

namespace {
constexpr double kTransportFadeSeconds = 0.005; // de-click ramp for play/pause/seek

// clock_gettime_nsec_np reads the commpage (no syscall, no locks) but is not
// annotated by the SDK, so the effect check is suppressed for this call only.
uint64_t nowNs() DALNOK_NONBLOCKING {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#pragma clang diagnostic pop
}

void atomicMax(std::atomic<uint64_t> &a, uint64_t v) DALNOK_NONBLOCKING {
    auto cur = a.load(std::memory_order_relaxed);
    while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {}
}
} // namespace

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

namespace {
// Stands in for a duplex device in tests: the caller drives each cycle through pumpInput.
class SimulatedDuplex final : public AudioDuplexDevice {
public:
    SimulatedDuplex(double rate, int64_t latency) : rate_(rate), latency_(latency) {}
    bool start(Callback, void *, std::string &) override { return true; }
    void stop() override {}
    bool captureFailed() const override { return false; }
    bool alive() const override { return true; }
    double hardwareSampleRate() const override { return rate_; }
    int64_t roundTripLatency() const override { return latency_; }
private:
    double rate_;
    int64_t latency_;
};
} // namespace

Engine::Engine(double sampleRate) : sampleRate_(sampleRate) {
    if (sampleRate_ <= 0) sampleRate_ = defaultOutputSampleRate();
    if (sampleRate_ <= 0) sampleRate_ = 48000.0;
    midiParsers_[0] = std::make_unique<MidiParser>();
    midiInputs_[0].store(midiParsers_[0].get(), std::memory_order_release);
    syncRuntimes(); // builds the tempo map: the first snapshot needs the metronome schedule
    commit();
}

Engine::~Engine() {
    if (recording_) { RecordResult ignored; std::string err; stopRecording(ignored, err); }
    stopDevice();
    midiClient_.reset(); // closes Core MIDI ports before the parsers go away
    collectGarbage();
    delete current_;
    delete pending_.exchange(nullptr);
}

// ---- Device -------------------------------------------------------------

bool Engine::startDevice(std::string &err) {
    if (device_ || duplex_) return true;
    auto dev = createOutputDevice(outputUid_, sampleRate_, err);
    if (!dev || !dev->start(&Engine::audioCallback, this, err)) return false;
    device_ = std::move(dev);
    return true;
}

bool Engine::setOutputDevice(const std::string &uid, std::string &err) {
    if (duplex_) { err = "stop capture before changing the output device"; return false; }
    if (uid == outputUid_ && device_ && device_->alive()) return true;
    const std::string previous = outputUid_;
    const bool wasRunning = device_ != nullptr;
    stopDevice();
    outputUid_ = uid;
    if (startDevice(err)) return true;
    // Fall back to what was running before (or the default if that is gone).
    outputUid_ = previous;
    std::string ignored;
    if (wasRunning && !startDevice(ignored)) {
        outputUid_.clear();
        startDevice(ignored);
    }
    return false;
}

bool Engine::pump(float *left, float *right, int frames) {
    if (device_ || duplex_ || !left || !right || frames <= 0) return false;
    process(left, right, frames);
    collectGarbage();
    return true;
}

bool Engine::pumpInput(const float *input, float *left, float *right, int frames) {
    // Mono test input appears on every device channel.
    const float *channels[64];
    for (auto &c : channels) c = input;
    return pumpInputChannels(input ? channels : nullptr, input ? 64 : 0, left, right, frames);
}

bool Engine::pumpInputChannels(const float *const *inputs, int count, float *left, float *right, int frames) {
    if (!simulatedInput_ || !duplex_ || !left || !right || frames <= 0 || count < 0 || count > 64) return false;
    duplexCallback(this, left, right, inputs, count, frames);
    collectGarbage();
    return true;
}

bool Engine::startCapture(const std::string &uid, const std::vector<int> &channels, const std::string &path, std::string &err) {
    if (duplex_ || captureWriter_) { err = "capture is already active"; return false; }
    if (channels.empty() || channels.size() > 64) { err = "choose 1 to 64 input channels"; return false; }
    int highest = 0;
    for (int c : channels) {
        if (c < 0 || c > 63) { err = "input channel out of range"; return false; }
        highest = std::max(highest, c);
    }
    const auto count = static_cast<uint32_t>(channels.size());
    const bool simulated = uid == kSimulatedInput;
    if (simulated ? device_ != nullptr : (!device_ || uid.empty() || uid != outputUid_)) {
        err = simulated ? "the simulated input requires the output device to be stopped"
                        : "select the same explicit input and output device before capture";
        return false;
    }
    if (path.empty() || sampleRate_ != std::floor(sampleRate_) || sampleRate_ < 8000 || sampleRate_ > 384000) {
        err = "invalid capture path or sample rate"; return false;
    }
    std::unique_ptr<AudioDuplexDevice> duplex;
    if (simulated) duplex = std::make_unique<SimulatedDuplex>(sampleRate_, simulatedLatency_);
    else duplex = createDuplexDevice(uid, sampleRate_, highest, err);
    if (!duplex) return false;
    const int fd = CaptureSpool::create(path, static_cast<uint32_t>(sampleRate_), count);
    if (fd < 0) { err = "cannot create new capture spool"; return false; }
    try {
        captureSpool_ = std::make_unique<CaptureSpool>(fd, count);
        // About 5.5 seconds at 48 kHz; overflow always reports an error.
        captureWriter_ = std::make_unique<CaptureWriter>(1 << 18, count, *captureSpool_);
        captureScratch_.assign(static_cast<size_t>(kMaxCaptureBlock) * count, 0.0f);
        for (size_t i = 0; i < channels.size(); ++i) captureMap_[i] = channels[i];
        captureChannels_ = static_cast<int>(count);
        captureWriter_->start();
    } catch (...) {
        if (!captureSpool_) ::close(fd);
        captureWriter_.reset(); captureSpool_.reset();
        err = "cannot start capture writer; spool retained"; return false;
    }
    captureInputFailed_.store(false, std::memory_order_relaxed);
    captureMissingFrames_.store(0, std::memory_order_relaxed);
    captureRT_ = captureWriter_.get();
    if (device_) { device_->stop(); device_.reset(); }
    if (!duplex->start(&Engine::duplexCallback, this, err)) {
        captureRT_ = nullptr;
        captureWriter_->stop(); captureWriter_.reset(); captureSpool_.reset();
        std::string restoreError;
        if (!simulated && !startDevice(restoreError)) err += "; output restart failed: " + restoreError;
        return false;
    }
    duplex_ = std::move(duplex);
    simulatedInput_ = simulated;
    return true;
}

bool Engine::captureStatus(DalnokCaptureStats &stats) const {
    if (!duplex_ || !captureWriter_) return false;
    stats = {};
    stats.captured_frames = captureWriter_->capturedFrames();
    stats.written_frames = captureWriter_->writtenFrames();
    stats.dropped_frames = captureWriter_->droppedFrames() + captureMissingFrames_.load(std::memory_order_relaxed);
    const double hardwareRate = duplex_->hardwareSampleRate();
    stats.input_error = captureInputFailed_.load(std::memory_order_acquire) || duplex_->captureFailed() || !duplex_->alive() ||
                        hardwareRate <= 0 || std::abs(hardwareRate - sampleRate_) > 0.5;
    stats.overflow = captureWriter_->hasError(CaptureWriter::Error::overflow);
    stats.write_error = captureWriter_->hasError(CaptureWriter::Error::write);
    stats.finalize_error = captureWriter_->hasError(CaptureWriter::Error::finalize);
    return true;
}

bool Engine::stopCapture(DalnokCaptureStats &stats, std::string &err, bool restoreOutput) {
    if (!duplex_ || !captureWriter_) { err = "capture is not active"; return false; }
    duplex_->stop(); // callback no longer accesses captureRT_
    captureRT_ = nullptr;
    captureChannels_ = 0;
    captureWriter_->stop();
    captureStatus(stats);
    duplex_.reset(); captureWriter_.reset(); captureSpool_.reset();
    const bool valid = !stats.input_error && !stats.overflow && !stats.write_error && !stats.finalize_error &&
                       stats.captured_frames > 0 && stats.captured_frames == stats.written_frames;
    std::string outputError;
    const bool restore = restoreOutput && !simulatedInput_;
    simulatedInput_ = false;
    const bool outputOK = !restore || startDevice(outputError);
    if (!valid) err = "capture failed; the original spool was retained";
    if (!outputOK) { if (!err.empty()) err += "; "; err += "output restart failed: " + outputError; }
    return valid && outputOK;
}

bool Engine::readTrackMeter(DalnokTrackId id, float &l, float &r) {
    const TrackState *t = model_.track(id);
    if (!t) return false;
    l = t->runtime->peakL.exchange(0.0f, std::memory_order_relaxed);
    r = t->runtime->peakR.exchange(0.0f, std::memory_order_relaxed);
    return true;
}

void Engine::readMasterMeter(float &l, float &r) {
    l = masterPeakL_.exchange(0.0f, std::memory_order_relaxed);
    r = masterPeakR_.exchange(0.0f, std::memory_order_relaxed);
}

void Engine::stopDevice() {
    if (duplex_) { DalnokCaptureStats stats{}; std::string ignored; stopCapture(stats, ignored, false); }
    if (!device_) return;
    device_->stop(); // synchronous: the audio thread is no longer inside process()
    device_.reset();
}

void Engine::collectGarbage() {
    RenderState *s = nullptr;
    while (retired_.pop(s)) delete s;
    // Edits made in plugin editors change what the project will save.
    uint64_t edits = 0;
    for (const auto &[id, p] : plugins_) edits += p ? p->editCount() : 0;
    if (edits != pluginEdits_) { pluginEdits_ = edits; ++revision_; }
    if (recording_) drainRecordedMidi();
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

namespace {
constexpr size_t kMaxUndo = 500;
}

template <typename F>
bool Engine::edit(const char *name, bool structural, F &&fn) {
    Model before = model_;
    if (!fn(model_)) {
        model_ = std::move(before);
        return false;
    }
    if (groupDepth_ == 0) {
        undo_.push_back({name, std::move(before)});
    } else if (!groupRecorded_) {
        undo_.push_back({groupName_.empty() ? name : groupName_, std::move(before)});
        groupRecorded_ = true;
    }
    if (undo_.size() > kMaxUndo) undo_.erase(undo_.begin());
    redo_.clear();
    ++revision_;
    syncRuntimes();
    if (structural) commit();
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
    model_ = std::move(m);
    syncRuntimes();
    ++revision_;
    commit();
}

bool Engine::undo() {
    groupDepth_ = 0;
    if (undo_.empty()) return false;
    UndoStep step = std::move(undo_.back());
    undo_.pop_back();
    redo_.push_back({step.name, model_});
    restore(std::move(step.model));
    return true;
}

bool Engine::redo() {
    groupDepth_ = 0;
    if (redo_.empty()) return false;
    UndoStep step = std::move(redo_.back());
    redo_.pop_back();
    undo_.push_back({step.name, model_});
    restore(std::move(step.model));
    return true;
}

void Engine::beginGroup(const std::string &name) {
    if (groupDepth_++ == 0) {
        groupName_ = name;
        groupRecorded_ = false;
    }
}

void Engine::endGroup() {
    if (groupDepth_ > 0) --groupDepth_;
}

void Engine::resetModel() {
    model_ = Model{};
    plugins_.clear(); // snapshots still holding instances release them on this thread
    pluginErrors_.clear();
    pool_.clear();
    cache_.clear();
    undo_.clear();
    redo_.clear();
    groupDepth_ = 0;
    nextColor_ = 0;
    cycleOn_.store(false, std::memory_order_release);
    cycleStart_.store(0, std::memory_order_relaxed);
    cycleEnd_.store(0, std::memory_order_relaxed);
    syncRuntimes();
    ++revision_;
    savedRevision_ = revision_;
}

void Engine::newProject() {
    resetModel();
    commit();
}

// ---- Commands -------------------------------------------------------------

namespace {
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
} // namespace

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
    if (recording_) return fail(err, "cannot change record arm while recording");
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
    if (recording_) return fail(err, "cannot change input while recording");
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

namespace {
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
} // namespace

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

bool Engine::setPunch(bool on, int64_t in, int64_t out, std::string &err) {
    if (on && (in < 0 || out <= in)) return fail(err, "punch needs 0 <= in < out");
    punchIn_.store(on ? in : INT64_MIN, std::memory_order_relaxed);
    punchOut_.store(on ? out : INT64_MAX, std::memory_order_relaxed);
    return true;
}

bool Engine::setCycle(bool on, int64_t start, int64_t end, std::string &err) {
    if (!on && start == 0 && end == 0) { // clear the region
        cycleOn_.store(false, std::memory_order_release);
        cycleStart_.store(0, std::memory_order_relaxed);
        cycleEnd_.store(0, std::memory_order_relaxed);
        return true;
    }
    if (start < 0 || end - start < 64 || end > (int64_t{1} << 48)) return fail(err, "cycle needs 0 <= start and end at least 64 frames after start");
    cycleOn_.store(false, std::memory_order_release); // audio thread never sees a half-updated range while on
    cycleStart_.store(start, std::memory_order_relaxed);
    cycleEnd_.store(end, std::memory_order_relaxed);
    cycleOn_.store(on, std::memory_order_release);
    return true;
}

bool Engine::validNotes(const std::vector<MidiNote> &notes, std::string &err) const {
    for (const auto &n : notes)
        if (n.start < 0 || n.length <= 0 || n.pitch > 127 || n.velocity < 1 || n.velocity > 127)
            return fail(err, "notes need start >= 0, length > 0, pitch 0-127, velocity 1-127");
    return true;
}

namespace {
NoteList sortedNotes(std::vector<MidiNote> notes) {
    std::stable_sort(notes.begin(), notes.end(), [](const MidiNote &a, const MidiNote &b) {
        return a.start < b.start || (a.start == b.start && a.pitch < b.pitch);
    });
    return std::make_shared<const std::vector<MidiNote>>(std::move(notes));
}
} // namespace

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
    // "au:type:subtype:manufacturer" names an Audio Unit; anything else is a VST3 bundle path.
    const bool au = path.rfind("au:", 0) == 0;
    const std::string format = au ? "au" : "vst3", location = au ? path.substr(3) : path;
    std::shared_ptr<PluginProcessor> instance(loadPlugin(format, location, classId, sampleRate_, kMaxBlock, false, err));
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
    instance->getState(slot.state);
    plugins_[id] = std::move(instance);
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
    if (!ok) { plugins_.erase(id); return 0; }
    ++nextPlugin_;
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

PluginProcessor *Engine::pluginInstance(int32_t id) const {
    auto it = plugins_.find(id);
    return it == plugins_.end() ? nullptr : it->second.get();
}

std::string Engine::pluginError(int32_t id) const {
    auto it = pluginErrors_.find(id);
    return it == pluginErrors_.end() ? "" : it->second;
}

bool Engine::pluginState(int32_t id, std::string &bytes) const {
    if (PluginProcessor *p = pluginInstance(id)) return p->getState(bytes);
    for (const auto &t : model_.tracks)
        for (const auto &slot : t.plugins)
            if (slot.id == id) { bytes = slot.state; return true; } // missing plugin: keep what was saved
    return false;
}

bool Engine::setPluginState(int32_t id, const std::string &bytes, std::string &err) {
    PluginProcessor *p = pluginInstance(id);
    if (!p) return fail(err, "no such plug-in, or it is not loaded");
    if (!p->setState(bytes)) return fail(err, "the plug-in rejected the state");
    ++revision_; // plugin state is saved with the project, so the project changed
    return true;
}

Engine::PluginMap Engine::offlinePlugins() const {
    PluginMap out;
    for (const auto &t : model_.tracks)
        for (const auto &slot : t.plugins) {
            if (!pluginInstance(slot.id)) continue;
            std::string err, state;
            std::shared_ptr<PluginProcessor> p(loadPlugin(slot.format, slot.path, slot.classId, sampleRate_, kMaxBlock, true, err));
            if (!p) continue;
            if (pluginState(slot.id, state)) p->setState(state);
            // Parameters set since the state was captured may not be in it yet (the live processor applies
            // them on its next block), so replay them; the offline instance applies them before its first block.
            std::vector<std::pair<uint32_t, double>> touched;
            pluginInstance(slot.id)->touchedParameters(touched);
            for (const auto &[id, v] : touched) p->setParameter(id, v);
            out[slot.id] = std::move(p);
        }
    return out;
}

void Engine::instantiatePlugins() {
    for (const auto &t : model_.tracks)
        for (const auto &slot : t.plugins) {
            nextPlugin_ = std::max(nextPlugin_, slot.id + 1);
            if (plugins_.count(slot.id)) continue;
            std::string err;
            std::shared_ptr<PluginProcessor> p(loadPlugin(slot.format, slot.path, slot.classId, sampleRate_, kMaxBlock, false, err));
            if (!p) { pluginErrors_[slot.id] = err; continue; }
            if (!slot.state.empty() && !p->setState(slot.state)) pluginErrors_[slot.id] = "the saved state was not accepted";
            plugins_[slot.id] = std::move(p);
        }
}

void Engine::captureLiveState(Model &m) const {
    for (auto &t : m.tracks)
        for (auto &slot : t.plugins) {
            std::string state;
            if (PluginProcessor *p = pluginInstance(slot.id); p && p->getState(state)) slot.state = std::move(state);
        }
}

namespace {
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
} // namespace

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

DalnokClipId Engine::copyToSlot(DalnokClipId clip, int32_t slot, std::string &err) {
    const auto id = nextClip_;
    const bool ok = edit("Copy to Launcher", true, [&](Model &m) {
        const ClipState *c = m.clip(clip);
        if (!c || c->alt) return fail(err, "no such clip");
        if (slot < 0 || slot >= m.scenes) return fail(err, "no such launcher slot");
        std::erase_if(m.clips, [&](const ClipState &x) { return x.track == c->track && x.slot == slot; }); // replaces the slot
        c = m.clip(clip);
        if (!c) return fail(err, "that clip was in the slot");
        ClipState copy = *c;
        copy.id = id;
        copy.slot = slot;
        copy.folder = 0;
        copy.start = 0;
        m.clips.push_back(std::move(copy));
        return true;
    });
    if (!ok) return 0;
    ++nextClip_;
    return id;
}

DalnokClipId Engine::placeCopy(DalnokClipId clip, DalnokTrackId track, int64_t start, std::string &err) {
    const auto id = nextClip_;
    const bool ok = edit("Place Copy", true, [&](Model &m) {
        const ClipState *c = m.clip(clip);
        const TrackState *t = m.track(track);
        if (!c || !t) return fail(err, "no such clip or track");
        if (start < 0) return fail(err, "start must be >= 0");
        if (t->kind == kTrackBus || (t->kind == kTrackInstrument) != c->midi()) return fail(err, "that clip can't go on that track");
        ClipState copy = *c;
        copy.id = id;
        copy.track = track;
        copy.start = start;
        copy.slot = -1;
        copy.follow = 0;
        copy.folder = 0;
        copy.alt = false;
        m.clips.push_back(std::move(copy));
        return true;
    });
    if (!ok) return 0;
    ++nextClip_;
    return id;
}

namespace {
// Next bar start strictly after `frame` (or `frame` itself when it is a bar start).
int64_t nextBar(const Model &m, const TempoMap &map, int64_t frame) {
    double beat = 0;
    if (!map.frameToBeat(frame, beat)) return frame;
    int32_t bar, num, den; double inBar;
    beatToBar(m.meters, beat, bar, inBar, num, den);
    if (inBar < 1e-6) return frame;
    int64_t out = frame;
    map.beatToFrame(barToBeat(m.meters, bar + 1), out);
    return out;
}
} // namespace

bool Engine::launch(DalnokTrackId track, int32_t slot, std::string &err) {
    const TrackState *t = model_.track(track);
    if (!t) return fail(err, "no such track");
    if (slot >= 0 && std::none_of(model_.clips.begin(), model_.clips.end(), [&](const ClipState &c) { return c.track == track && c.slot == slot; }))
        return fail(err, "that slot is empty");
    // Launch times are timeline frames; the audio thread switches when the rendered position (the playhead
    // plus delay compensation) reaches them, so the change is heard exactly on the bar.
    const bool rolling = playing_.load();
    const int64_t at = rolling ? nextBar(model_, map_, position() + 1) : position();
    t->runtime->launchTarget.store(slot, std::memory_order_relaxed);
    t->runtime->launchAt.store(at, std::memory_order_release);
    if (!rolling && slot >= 0) play();
    return true;
}

bool Engine::launchScene(int32_t slot, std::string &err) {
    if (slot < 0 || slot >= model_.scenes) return fail(err, "no such scene");
    bool any = false;
    for (const auto &t : model_.tracks) {
        const bool filled = std::any_of(model_.clips.begin(), model_.clips.end(), [&](const ClipState &c) { return c.track == t.id && c.slot == slot; });
        std::string ignored;
        if (filled) any = launch(t.id, slot, ignored) || any;
        else if (t.runtime->playingSlot.load() >= 0) launch(t.id, -1, ignored); // empty slot in the scene: that track stops its clip
    }
    return any || fail(err, "that scene is empty");
}

void Engine::stopLauncher() {
    std::string ignored;
    for (const auto &t : model_.tracks)
        if (t.runtime->playingSlot.load() >= 0 || t.runtime->launchAt.load() >= 0) launch(t.id, -1, ignored);
}

int64_t Engine::slotStart(DalnokTrackId track) const {
    const TrackState *t = model_.track(track);
    return t ? t->runtime->slotStart.load(std::memory_order_relaxed) : 0;
}

bool Engine::setFollowAction(DalnokClipId clip, int32_t action, int32_t loops, std::string &err) {
    if (action < 0 || action > 2 || loops < 1 || loops > 1024) return fail(err, "follow action is 0 none, 1 next, 2 stop; loops 1-1024");
    return edit("Follow Action", true, [&](Model &m) {
        ClipState *c = m.clip(clip);
        if (!c || c->slot < 0) return fail(err, "not a launcher clip");
        c->follow = action;
        c->followLoops = loops;
        return true;
    });
}

void Engine::setLauncherRecording(bool on) {
    if (on == launcherRecording_.load()) return;
    if (on) {
        LaunchEvent e;
        while (launchEvents_.pop(e)) {}
        launchLog_.clear();
        launcherRecordStart_ = position();
        // Tracks already playing a slot start their segment where recording began.
        for (const auto &t : model_.tracks)
            if (int32_t ps = t.runtime->playingSlot.load(); ps >= 0) launchLog_.push_back({t.id, ps, launcherRecordStart_});
        launcherRecording_.store(true);
        return;
    }
    launcherRecording_.store(false);
    LaunchEvent e;
    while (launchEvents_.pop(e)) launchLog_.push_back(e);
    const int64_t end = position();
    // Each track's segments: from a switch to the next switch (or the end); slot -1 = arrangement.
    struct Piece { DalnokTrackId track; int32_t slot; int64_t from, to, slotStart; };
    std::vector<Piece> pieces;
    std::map<DalnokTrackId, std::vector<LaunchEvent>> byTrack;
    for (const auto &ev : launchLog_) byTrack[ev.track].push_back(ev);
    for (auto &[track, evs] : byTrack) {
        std::stable_sort(evs.begin(), evs.end(), [](const LaunchEvent &a, const LaunchEvent &b) { return a.frame < b.frame; });
        for (size_t i = 0; i < evs.size(); ++i) {
            const int64_t to = i + 1 < evs.size() ? evs[i + 1].frame : end;
            if (evs[i].slot >= 0 && to > evs[i].frame) pieces.push_back({track, evs[i].slot, evs[i].frame, to, evs[i].frame});
        }
    }
    launchLog_.clear();
    if (pieces.empty()) return;
    std::string err;
    edit("Record Launcher", true, [&](Model &m) {
        for (const auto &p : pieces) {
            const auto src = std::find_if(m.clips.begin(), m.clips.end(), [&](const ClipState &c) { return c.track == p.track && c.slot == p.slot; });
            if (src == m.clips.end() || src->length <= 0) continue;
            const ClipState proto = *src;
            // One clip per loop pass, the last one trimmed where the performance moved on.
            for (int64_t at = p.from; at < p.to; at += proto.length) {
                ClipState c = proto;
                c.id = nextClip_++;
                c.slot = -1;
                c.follow = 0;
                c.start = at;
                c.length = std::min(proto.length, p.to - at);
                // Recorded material replaces whatever the arrangement had there.
                std::erase_if(m.clips, [&](const ClipState &x) {
                    return x.track == p.track && x.slot < 0 && !x.alt && x.start >= c.start && x.start + x.length <= c.start + c.length && x.id != c.id;
                });
                m.clips.push_back(std::move(c));
            }
        }
        return true;
    });
}

int32_t Engine::playingSlot(DalnokTrackId track) const {
    const TrackState *t = model_.track(track);
    return t ? t->runtime->playingSlot.load(std::memory_order_relaxed) : -1;
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

namespace {
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
} // namespace

int32_t Engine::makeTakeFolder(Model &m, DalnokTrackId track, std::vector<DalnokClipId> takes, std::string &err) {
    int32_t id = 1;
    for (const auto &f : m.folders) id = std::max(id, f.id + 1);
    TakeFolder f;
    f.id = id;
    f.track = track;
    f.takes = std::move(takes);
    // Default comp: later takes cover earlier ones (the newest pass plays wherever it was recorded).
    std::vector<CompSegment> comp;
    for (int32_t k = 0; k < static_cast<int32_t>(f.takes.size()); ++k) {
        ClipState *c = m.clip(f.takes[static_cast<size_t>(k)]);
        if (!c) return fail(err, "no such take"), 0;
        c->folder = id;
        c->alt = true;
        const int64_t a = c->start, b = c->start + c->length;
        std::vector<CompSegment> next;
        for (const auto &s : comp) { // cut existing segments around [a, b)
            if (s.to <= a || s.from >= b) { next.push_back(s); continue; }
            if (s.from < a) next.push_back({s.from, a, s.take});
            if (s.to > b) next.push_back({b, s.to, s.take});
        }
        next.push_back({a, b, k});
        std::sort(next.begin(), next.end(), [](const CompSegment &x, const CompSegment &y) { return x.from < y.from; });
        comp = std::move(next);
    }
    f.comp = std::move(comp);
    if (!realizeComp(m, f, nextClip_, err)) return 0;
    m.folders.push_back(std::move(f));
    return id;
}

int32_t Engine::addTakeFolder(DalnokTrackId track, std::vector<DalnokClipId> takes, std::string &err) {
    int32_t folder = 0;
    edit("Take Folder", true, [&](Model &m) {
        for (auto id : takes) {
            const ClipState *c = m.clip(id);
            if (!c || c->track != track || c->midi() || c->folder) return fail(err, "takes must be audio clips on the track, not in a folder");
        }
        folder = makeTakeFolder(m, track, std::move(takes), err);
        return folder != 0;
    });
    return folder;
}

bool Engine::setComp(int32_t folder, std::vector<CompSegment> comp, std::string &err) {
    std::sort(comp.begin(), comp.end(), [](const CompSegment &x, const CompSegment &y) { return x.from < y.from; });
    return edit("Comp", true, [&](Model &m) {
        auto it = std::find_if(m.folders.begin(), m.folders.end(), [&](const TakeFolder &f) { return f.id == folder; });
        if (it == m.folders.end()) return fail(err, "no such take folder");
        int64_t prev = INT64_MIN;
        for (const auto &seg : comp) {
            if (seg.take < 0 || seg.take >= static_cast<int32_t>(it->takes.size()) || seg.to <= seg.from || seg.from < prev)
                return fail(err, "comp segments must be ordered, non-overlapping and name a take");
            const ClipState *t = m.clip(it->takes[static_cast<size_t>(seg.take)]);
            if (!t || seg.from < t->start || seg.to > t->start + t->length) return fail(err, "a comp segment lies outside its take");
            prev = seg.to;
        }
        it->comp = std::move(comp);
        return realizeComp(m, *it, nextClip_, err);
    });
}

DalnokTrackId Engine::makeStack(const std::vector<DalnokTrackId> &members, const std::string &name, std::string &err) {
    const auto id = nextTrack_;
    const bool ok = edit("Create Track Stack", true, [&](Model &m) {
        if (members.empty()) return fail(err, "choose tracks for the stack");
        std::vector<size_t> at;
        for (auto t : members) {
            auto it = std::find_if(m.tracks.begin(), m.tracks.end(), [t](const TrackState &x) { return x.id == t; });
            if (it == m.tracks.end()) return fail(err, "no such track");
            if (it->isStack || it->stack) return fail(err, "a track can be in one stack, and stacks don't nest yet");
            at.push_back(static_cast<size_t>(it - m.tracks.begin()));
        }
        std::sort(at.begin(), at.end());
        TrackState stack;
        stack.id = id;
        stack.kind = kTrackBus;
        stack.isStack = true;
        stack.name = name.empty() ? "Stack" : name;
        stack.color = m.tracks[at.front()].color;
        stack.output = m.tracks[at.front()].output; // the stack goes where its first member went
        stack.runtime = std::make_shared<TrackRuntime>();
        // Members (in their current order) follow the stack, which takes the first member's place.
        std::vector<TrackState> moved;
        for (size_t i : at) moved.push_back(m.tracks[i]);
        for (auto it = at.rbegin(); it != at.rend(); ++it) m.tracks.erase(m.tracks.begin() + static_cast<long>(*it));
        for (auto &t : moved) { t.output = id; t.stack = id; }
        const auto insertAt = m.tracks.begin() + static_cast<long>(at.front());
        moved.insert(moved.begin(), std::move(stack));
        m.tracks.insert(insertAt, moved.begin(), moved.end());
        if (m.track(id)->output && feedsBack(m, id, m.track(id)->output)) m.track(id)->output = 0;
        return true;
    });
    if (!ok) return 0;
    ++nextTrack_;
    return id;
}

bool Engine::setStackCollapsed(DalnokTrackId stack, bool collapsed, std::string &err) {
    return edit(collapsed ? "Close Stack" : "Open Stack", false, [&](Model &m) {
        TrackState *t = m.track(stack);
        if (!t || !t->isStack) return fail(err, "not a track stack");
        t->collapsed = collapsed;
        return true;
    });
}

bool Engine::ungroupStack(DalnokTrackId stack, std::string &err) {
    return edit("Ungroup Track Stack", true, [&](Model &m) {
        TrackState *t = m.track(stack);
        if (!t || !t->isStack) return fail(err, "not a track stack");
        const auto out = t->output;
        for (auto &x : m.tracks) {
            if (x.stack == stack) { x.stack = 0; if (x.output == stack) x.output = out; }
            std::erase_if(x.sends, [stack](const Send &s) { return s.bus == stack; });
            if (x.output == stack) x.output = out;
        }
        std::erase_if(m.tracks, [stack](const TrackState &x) { return x.id == stack; });
        return true;
    });
}

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
        if (!m.track(id)) return fail(err, "no such track");
        std::erase_if(m.tracks, [id](const TrackState &t) { return t.id == id; });
        std::erase_if(m.folders, [id](const TakeFolder &f) { return f.track == id; });
        for (auto &t : m.tracks) { // whatever fed a deleted bus goes to the master instead
            if (t.stack == id) t.stack = 0;
            if (t.output == id) t.output = 0;
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
    return edit("Master Volume", false, [&](Model &m) {
        if (std::isnan(db)) return fail(err, "gain is NaN");
        m.masterGainDb = db <= -96.0f ? -INFINITY : std::min(db, 12.0f);
        masterRuntime_->gain.store(dbToGain(m.masterGainDb), std::memory_order_relaxed);
        return true;
    });
}

bool Engine::setGainDb(DalnokTrackId id, float db, std::string &err) {
    return edit("Volume", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        if (std::isnan(db)) return fail(err, "gain is NaN");
        t->gainDb = db <= -96.0f ? -INFINITY : std::min(db, 12.0f);
        t->runtime->gain.store(dbToGain(t->gainDb), std::memory_order_relaxed);
        return true;
    });
}

bool Engine::setPan(DalnokTrackId id, float pan, std::string &err) {
    return edit("Pan", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        if (std::isnan(pan)) return fail(err, "pan is NaN");
        t->pan = std::clamp(pan, -1.0f, 1.0f);
        t->runtime->pan.store(t->pan, std::memory_order_relaxed);
        return true;
    });
}

bool Engine::setMute(DalnokTrackId id, bool muted, std::string &err) {
    return edit(muted ? "Mute" : "Unmute", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        t->muted = muted;
        t->runtime->muted.store(muted, std::memory_order_relaxed);
        return true;
    });
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
    return edit(solo ? "Solo" : "Unsolo", false, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        t->solo = solo;
        return true;
    });
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

bool Engine::setClipFades(DalnokClipId id, int64_t fadeIn, int64_t fadeOut, int32_t curve, std::string &err) {
    return edit("Fade", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        if (c->midi()) return fail(err, "not available for MIDI clips");
        if (fadeIn < 0 || fadeOut < 0) return fail(err, "fades must be >= 0");
        if (curve != kFadeLinear && curve != kFadeEqualPower) return fail(err, "unknown fade curve");
        c->fadeIn = fadeIn;
        c->fadeOut = fadeOut;
        c->fadeCurve = curve;
        return true;
    });
}

bool Engine::setClipStretch(DalnokClipId id, int64_t length, double rate, float pitch, bool preservePitch,
                            std::string &err) {
    return edit("Time Stretch", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        if (c->midi()) return fail(err, "not available for MIDI clips");
        if (!(rate >= 0.05 && rate <= 20) || !(pitch >= -48 && pitch <= 48) || length <= 0)
            return fail(err, "rate must be 0.05–20, pitch −48…48 semitones, length > 0");
        const PoolEntry *pe = poolEntry(c->media);
        const auto span = static_cast<int64_t>(std::llround(static_cast<double>(length) * rate));
        if (!pe || c->offset + span > pe->frames + 1) return fail(err, "stretch reads past the end of the source");
        c->length = length;
        c->rate = rate;
        c->pitch = preservePitch ? pitch : 0;
        c->preservePitch = preservePitch;
        return true;
    });
}

bool Engine::setClipGain(DalnokClipId id, float gainDb, std::string &err) {
    return edit("Clip Gain", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        if (c->midi()) return fail(err, "not available for MIDI clips");
        if (std::isnan(gainDb)) return fail(err, "gain is NaN");
        c->gainDb = gainDb <= -96.0f ? -INFINITY : std::min(gainDb, 24.0f);
        return true;
    });
}

bool Engine::poolRelink(DalnokMediaId id, std::shared_ptr<const Media> media, const std::string &path,
                        std::string &err) {
    auto it = pool_.find(id);
    if (it == pool_.end()) return fail(err, "no such media");
    if (!media) return fail(err, "no media");
    it->second.path = path;
    it->second.frames = media->frames();
    it->second.channels = media->channelCount();
    it->second.handle = std::make_unique<DalnokMedia>(DalnokMedia{std::move(media)});
    cache_.clear();
    ++revision_;
    commit();
    return true;
}

DalnokClipId Engine::addClip(DalnokTrackId track, DalnokMediaId media, int64_t start, int64_t offset, int64_t length,
                             std::string &err) {
    const PoolEntry *pe = poolEntry(media);
    const auto id = nextClip_;
    const bool ok = edit("Add Clip", true, [&](Model &m) {
        if (!m.track(track)) return fail(err, "no such track");
        if (m.track(track)->kind != kTrackAudio) return fail(err, "audio clips go on audio tracks");
        if (!pe) return fail(err, "no such media");
        if (start < 0 || offset < 0 || offset >= pe->frames) return fail(err, "start/offset out of range");
        const int64_t avail = pe->frames - offset;
        ClipState c;
        c.id = id;
        c.track = track;
        c.media = media;
        c.start = start;
        c.offset = offset;
        c.length = length <= 0 ? avail : std::min(length, avail);
        c.name = pe->path.empty() ? "Audio" : stem(pe->path);
        m.clips.push_back(std::move(c));
        return true;
    });
    if (!ok) return 0;
    ++nextClip_;
    return id;
}

bool Engine::removeClip(DalnokClipId id, std::string &err) {
    return edit("Delete Clip", true, [&](Model &m) {
        if (!m.clip(id)) return fail(err, "no such clip");
        std::erase_if(m.clips, [id](const ClipState &c) { return c.id == id; });
        return true;
    });
}

bool Engine::moveClip(DalnokClipId id, DalnokTrackId track, int64_t start, std::string &err) {
    return edit("Move Clip", true, [&](Model &m) {
        auto it = std::find_if(m.clips.begin(), m.clips.end(), [id](const ClipState &c) { return c.id == id; });
        if (it == m.clips.end()) return fail(err, "no such clip");
        if (!m.track(track)) return fail(err, "no such track");
        if (start < 0) return fail(err, "start must be >= 0");
        if (m.track(track)->kind == kTrackBus) return fail(err, "buses don't hold clips");
        if ((m.track(track)->kind == kTrackInstrument) != it->midi())
            return fail(err, it->midi() ? "MIDI clips go on instrument tracks" : "audio clips go on audio tracks");
        ClipState c = *it;
        c.track = track;
        c.start = start;
        m.clips.erase(it);
        m.clips.push_back(std::move(c)); // moved clips come to the top
        return true;
    });
}

bool Engine::setClipRegion(DalnokClipId id, int64_t start, int64_t offset, int64_t length, std::string &err) {
    return edit("Trim Clip", true, [&](Model &m) {
        ClipState *c = m.clip(id);
        if (!c) return fail(err, "no such clip");
        const PoolEntry *pe = poolEntry(c->media);
        const int64_t frames = c->midi() ? INT64_MAX / 2 : (pe ? pe->frames : 0); // MIDI clips can extend freely
        const auto span = static_cast<int64_t>(std::llround(static_cast<double>(length) * c->rate));
        if (start < 0 || offset < 0 || length <= 0 || offset + span > frames)
            return fail(err, "region out of range");
        c->start = start;
        c->offset = offset;
        c->length = length;
        return true;
    });
}

DalnokClipId Engine::splitClip(DalnokClipId id, int64_t at, std::string &err) {
    const auto rightId = nextClip_;
    const bool ok = edit("Split Clip", true, [&](Model &m) {
        auto it = std::find_if(m.clips.begin(), m.clips.end(), [id](const ClipState &c) { return c.id == id; });
        if (it == m.clips.end()) return fail(err, "no such clip");
        if (at <= it->start || at >= it->start + it->length) return fail(err, "split point not inside clip");
        ClipState right = *it;
        const int64_t leftLen = at - it->start;
        it->length = leftLen;
        right.id = rightId;
        right.start = at;
        right.offset += static_cast<int64_t>(std::llround(static_cast<double>(leftLen) * it->rate));
        right.length -= leftLen;
        right.fadeIn = 0;      // the right part keeps the original fade-out
        it->fadeOut = 0;       // the left part keeps the original fade-in
        m.clips.insert(it + 1, std::move(right)); // same z-level as the original
        return true;
    });
    if (!ok) return 0;
    ++nextClip_;
    return rightId;
}

// ---- Snapshot compilation -------------------------------------------------

StretchKey Engine::stretchKey(const ClipState &c) const {
    return {c.media, c.offset, c.sourceLength(), c.length, static_cast<int32_t>(std::lround(c.pitch * 100)), c.preservePitch};
}

bool Engine::clipProcessing(const ClipState &c) const {
    if (!c.stretched()) return false;
    const PoolEntry *pe = poolEntry(c.media);
    return pe && pe->handle->impl && !cache_.find(stretchKey(c));
}

std::unique_ptr<RenderState> Engine::compile(std::vector<StretchJob> *needed, const PluginMap *pluginMap) const {
    const PluginMap &instances = pluginMap ? *pluginMap : plugins_;
    auto s = std::make_unique<RenderState>();
    s->synth = SynthParams::make(sampleRate_);
    // Exports get their own master runtime (same gain) so they never touch the live smoothing state.
    if (pluginMap) { s->master = std::make_shared<TrackRuntime>(); s->master->gain.store(masterRuntime_->gain.load()); }
    else s->master = masterRuntime_;
    for (const auto &seg : map_.segments())
        s->clickTempo.push_back({seg.beat, static_cast<double>(seg.frame), static_cast<double>(seg.framesPerBeat)});
    for (const auto &m : model_.meters)
        s->clickMeter.push_back({barToBeat(model_.meters, m.bar), 4.0 / m.den, m.num});
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
        for (const auto &t : model_.tracks) if (t.kind != kTrackBus) left.push_back(&t);
        for (const auto &t : model_.tracks) if (t.kind == kTrackBus) left.push_back(&t);
        while (!left.empty()) { // Kahn's algorithm; edits keep the graph acyclic, so this always progresses
            auto ready = std::find_if(left.begin(), left.end(), [&](const TrackState *b) {
                return std::none_of(left.begin(), left.end(), [&](const TrackState *o) { return o != b && feeds(*o, *b); });
            });
            if (ready == left.end()) ready = left.begin(); // defensive: never loop forever
            order.push_back(*ready);
            left.erase(ready);
        }
    }
    std::map<DalnokTrackId, int32_t> indexOf;
    for (const TrackState *tp : order) {
        const TrackState &t = *tp;
        indexOf[t.id] = static_cast<int32_t>(s->tracks.size());
        RenderTrack rt;
        rt.id = t.id;
        rt.runtime = t.runtime;
        rt.bus = t.kind == kTrackBus;
        rt.monoSource = !rt.bus; // buses are stereo (balance pan)
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
            rt.keep.push_back(it->second);
            rt.latency += static_cast<int32_t>(std::min<uint32_t>(it->second->latency(), 1u << 20));
            if (slot.instrument && rt.instrument) rt.instrumentPlugin = it->second.get();
            else if (!slot.instrument) rt.inserts.push_back(it->second.get());
        }
        for (const auto &c : model_.clips) {
            if (c.track != t.id || c.alt) continue; // takes in a folder don't play; the comp's pieces do
            if (c.slot >= 0 && c.midi()) { // launcher slot: notes relative to the loop start
                if (!rt.instrument) continue;
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
                rt.slots.push_back(std::move(sl));
                continue;
            }
            if (c.midi()) {
                if (!rt.instrument) continue;
                for (const auto &n : *c.notes) {
                    if (n.start < c.offset || n.start >= c.offset + c.length) continue; // outside the clip window
                    const int64_t at = c.start + (n.start - c.offset);
                    int64_t sourceEnd = c.offset + c.length;
                    int64_t timelineEnd = c.start + c.length;
                    // A split shares its note list and has contiguous source and timeline ranges.
                    // Extend a crossing note through those pieces without retriggering it.
                    while (timelineEnd - at < n.length) {
                        const auto next = std::find_if(model_.clips.begin(), model_.clips.end(), [&](const ClipState &part) {
                            return part.track == c.track && part.notes == c.notes && part.start == timelineEnd &&
                                   std::abs(part.offset - sourceEnd) <= 1;
                        });
                        if (next == model_.clips.end() || next->length <= 0) break;
                        sourceEnd = next->offset + next->length;
                        timelineEnd += next->length;
                    }
                    const int64_t end = at + std::min(n.length, timelineEnd - at);
                    rt.notes.push_back({at, end, n.pitch, n.velocity});
                }
                continue;
            }
            const PoolEntry *pe = poolEntry(c.media);
            if (!pe || !pe->handle->impl) continue; // offline media renders silence
            std::shared_ptr<const Media> media = pe->handle->impl;
            int64_t offset = c.offset, len = std::min(c.length, media->frames() - c.offset);
            if (c.stretched()) {
                // Stretched audio is rendered off the audio thread; until it's ready the clip is silent.
                const StretchKey key = stretchKey(c);
                auto derived = cache_.find(key);
                if (!derived) {
                    if (needed) needed->push_back({key, media});
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
                rt.slots.push_back(std::move(sl));
                continue;
            }
            rt.clips.push_back({media, c.start, offset, len, fi, fo, c.fadeCurve, dbToGain(c.gainDb)});
            if (media->channelCount() > 1) rt.monoSource = false;
        }
        std::stable_sort(rt.notes.begin(), rt.notes.end(),
                         [](const RenderNote &a, const RenderNote &b) { return a.start < b.start; });
        rt.noteEnds = rt.notes;
        std::stable_sort(rt.noteEnds.begin(), rt.noteEnds.end(),
                         [](const RenderNote &a, const RenderNote &b) { return a.end < b.end; });
        // Launcher "next" follow action: the next filled slot on this track, wrapping.
        std::sort(rt.slots.begin(), rt.slots.end(), [](const RenderSlot &a, const RenderSlot &b) { return a.slot < b.slot; });
        for (size_t k = 0; k < rt.slots.size(); ++k) rt.slots[k].nextSlot = rt.slots[(k + 1) % rt.slots.size()].slot;
        s->tracks.push_back(std::move(rt));
    }
    // Sidechains: number the source tracks and point listening plug-ins at their buffers.
    {
        std::map<DalnokTrackId, int32_t> scIndex;
        for (size_t i = 0; i < order.size(); ++i)
            for (const auto &slot : order[i]->plugins) {
                if (!slot.sidechain || !indexOf.count(slot.sidechain)) continue;
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
    // offline renders (pluginMap != nullptr) get fresh ones.
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
        if (!pluginMap) {
            auto &cached = delayCache_[key];
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
    if (!pluginMap) // forget delay lines no snapshot can use any more
        for (auto it = delayCache_.begin(); it != delayCache_.end();)
            it = it->second.use_count() == 1 && std::none_of(s->delayKeep.begin(), s->delayKeep.end(),
                                                             [&](const auto &k) { return k == it->second; })
                     ? delayCache_.erase(it) : std::next(it);
    s->busL.assign(static_cast<size_t>(buses) * kMaxBlock, 0.0f);
    s->busR.assign(static_cast<size_t>(buses) * kMaxBlock, 0.0f);
    return s;
}

void Engine::commit() {
    std::vector<StretchJob> needed;
    auto state = compile(&needed);
    cache_.setNeeded(std::move(needed));
    // A snapshot replaced here was never observed by the audio thread, so it
    // is safe to delete immediately.
    delete pending_.exchange(state.release(), std::memory_order_acq_rel);
    collectGarbage();
}

bool Engine::pollJobs() {
    if (!cache_.poll()) return false;
    commit();
    return true;
}

void Engine::renderPendingStretchesNow() {
    std::vector<StretchJob> needed;
    compile(&needed);
    if (needed.empty()) return;
    cache_.computeNow(needed);
    commit();
}

// ---- Audio thread -------------------------------------------------------

void Engine::duplexCallback(void *ctx, float *left, float *right, const float *const *inputs, int inputCount,
                            int frames) DALNOK_NONBLOCKING {
    auto *self = static_cast<Engine *>(ctx);
    audioCallback(ctx, left, right, frames);
    const int n = self->captureChannels_;
    bool ok = inputs != nullptr && frames <= kMaxCaptureBlock;
    for (int c = 0; ok && c < n; ++c) {
        const int ch = self->captureMap_[static_cast<size_t>(c)];
        ok = ch < inputCount && inputs[ch] != nullptr;
    }
    if (!ok) {
        self->captureMissingFrames_.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed);
        self->captureInputFailed_.store(true, std::memory_order_release);
        return;
    }
    // Outside a recording session every frame is captured; in one, only the part of the block inside the
    // punch window, and only where the transport rolled continuously.
    const bool session = self->recordSession_.load(std::memory_order_acquire);
    if (self->captureRT_ && n > 0 && (!session || self->rtRecordingBlock_)) {
        const int from = session ? self->rtRecordOffset_ : 0, count = session ? self->rtRecordCount_ : frames;
        float *out = self->captureScratch_.data();
        for (int i = 0; i < count; ++i)
            for (int c = 0; c < n; ++c) out[i * n + c] = inputs[self->captureMap_[static_cast<size_t>(c)]][from + i];
        self->captureRT_->push(out, static_cast<uint32_t>(count));
    }
    if (self->monitoring_.load(std::memory_order_relaxed))
        for (int c = 0; c < n; ++c) {
            const float *in = inputs[self->captureMap_[static_cast<size_t>(c)]];
            for (int i = 0; i < frames; ++i) { left[i] += in[i]; right[i] += in[i]; }
        }
}

void Engine::renderClick(float *left, float *right, int frames, int64_t pos) DALNOK_NONBLOCKING {
    const bool on = metronome_.load(std::memory_order_relaxed);
    const int64_t until = countInUntil_.load(std::memory_order_relaxed); // count-in clicks even with the metronome off
    const float level = metronomeLevel_.load(std::memory_order_relaxed), decay = clickDecay_.load(std::memory_order_relaxed);
    bool accent = false;
    int64_t next = (on || pos < until) && current_ ? nextClick(*current_, pos, accent) : INT64_MAX;
    for (int i = 0; i < frames; ++i) {
        if ((on || pos + i < until) && pos + i == next) { // start a click: sine via a two-term recursion, no libm on this thread
            clickCoefNow_ = accent ? clickAccentCoef_.load(std::memory_order_relaxed) : clickCoef_.load(std::memory_order_relaxed);
            clickY1_ = 0;
            clickY2_ = -(accent ? clickAccentSin_.load(std::memory_order_relaxed) : clickSin_.load(std::memory_order_relaxed));
            clickEnv_ = level * (accent ? 1.0f : 0.6f);
            clickLeft_ = static_cast<int>(sampleRate_ * 0.08);
            next = nextClick(*current_, pos + i + 1, accent);
        }
        if (clickLeft_ <= 0) continue;
        const float y = clickCoefNow_ * clickY1_ - clickY2_;
        clickY2_ = clickY1_;
        clickY1_ = y;
        const float v = y * clickEnv_; // sin(w), sin(2w), ...: the onset sample is already non-zero
        left[i] += v;
        right[i] += v;
        clickEnv_ *= decay;
        --clickLeft_;
    }
}

void Engine::handleMidiInput(int64_t pos) DALNOK_NONBLOCKING {
    constexpr int kMaxEvents = 256;
    RecordedMidi events[kMaxEvents];
    int count = 0;
    const int32_t live = current_ ? current_->liveTrack : -1;
    const bool pluginLive = live >= 0 && current_->tracks[static_cast<size_t>(live)].instrumentPlugin;
    SynthState *synth = live >= 0 && !pluginLive ? &current_->tracks[static_cast<size_t>(live)].runtime->live : nullptr;
    rtLiveNoteCount_ = 0;
    for (auto &slot : midiInputs_) {
        MidiParser *parser = slot.load(std::memory_order_acquire);
        if (!parser) continue;
        MidiMessage m;
        while (parser->pop(m)) {
            const uint8_t type = m.status & 0xf0;
            const bool on = type == 0x90 && m.data2 > 0, off = type == 0x80 || (type == 0x90 && m.data2 == 0);
            if (pluginLive && (on || off) && rtLiveNoteCount_ < 256)
                rtLiveNotes_[rtLiveNoteCount_++] = PluginNote{0, static_cast<uint8_t>(on ? 1 : 0), m.data1, m.data2};
            if (synth && on) synth->noteOn(current_->synth, m.data1, m.data2, -1);
            else if (synth && off) synth->noteOff(current_->synth, m.data1);
            else if (synth && type == 0xb0 && (m.data1 == 120 || m.data1 == 123)) synth->reset();
            if (!on && !off) continue;
            if (count < kMaxEvents) events[count++] = {pos, m.status, m.data1, m.data2};
            else midiRecordDropped_.fetch_add(1, std::memory_order_relaxed);
        }
    }
    // Record after the block decided whether the transport rolled (see process).
    rtMidiCount_ = 0;
    for (int i = 0; i < count; ++i) rtMidiEvents_[rtMidiCount_++] = events[i];
}

void Engine::audioCallback(void *ctx, float *left, float *right, int frames) DALNOK_NONBLOCKING {
    auto *self = static_cast<Engine *>(ctx);
    const uint64_t t0 = nowNs();
    self->process(left, right, frames);
    const uint64_t dt = nowNs() - t0;

    self->callbacks_.fetch_add(1, std::memory_order_relaxed);
    self->framesRendered_.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed);
    self->lastCallbackNs_.store(dt, std::memory_order_relaxed);
    atomicMax(self->maxCallbackNs_, dt);
    if (static_cast<uint32_t>(frames) > self->maxFrames_.load(std::memory_order_relaxed))
        self->maxFrames_.store(static_cast<uint32_t>(frames), std::memory_order_relaxed);
    if (static_cast<double>(dt) > static_cast<double>(frames) / self->sampleRate_ * 1e9)
        self->overloads_.fetch_add(1, std::memory_order_relaxed);
}

void Engine::process(float *left, float *right, int frames) DALNOK_NONBLOCKING {
    // Adopt the newest snapshot only if the previous one can be retired.
    if (!retired_.full()) {
        if (RenderState *s = pending_.exchange(nullptr, std::memory_order_acq_rel)) {
            if (current_) retired_.push(current_);
            current_ = s;
            swaps_.fetch_add(1, std::memory_order_relaxed);
        }
    }
    const int64_t before = rtPosition_;
    handleMidiInput(before);
    const bool anySolo = soloCount_.load(std::memory_order_relaxed) > 0;
    const int64_t seek = seekRequest_.exchange(-1, std::memory_order_relaxed);
    if (seek >= 0) pendingSeek_ = seek;
    const bool play = playing_.load(std::memory_order_relaxed);
    const float step = static_cast<float>(1.0 / (kTransportFadeSeconds * sampleRate_));

    // Cycle: read once per callback (the control thread writes start/end before enabling).
    // Recording plays straight through, except a cycle take (recordCycle_), which loops and becomes takes.
    const bool cycleTake = recordCycle_.load(std::memory_order_acquire) && recordArmed_.load(std::memory_order_relaxed);
    const bool cycling = cycleOn_.load(std::memory_order_acquire) && (!recordArmed_.load(std::memory_order_relaxed) || cycleTake);
    int64_t advanced = 0; // frames the transport advanced in this callback (cycle wraps included)
    bool jumped = false;  // a seek landed in this callback
    const int64_t cycleStart = cycleStart_.load(std::memory_order_relaxed), cycleEnd = cycleEnd_.load(std::memory_order_relaxed);
    const bool cycleValid = cycling && cycleEnd - cycleStart >= 64 && cycleStart >= 0;

    for (int off = 0; off < frames;) {
        int n = std::min(kMaxBlock, frames - off);
        // Stop the sub-block exactly at the cycle end so the jump back lands on the right sample.
        if (cycleValid && play && pendingSeek_ < 0 && rtPosition_ < cycleEnd && rtPosition_ + n > cycleEnd)
            n = static_cast<int>(cycleEnd - rtPosition_);
        // Clip launcher: switch tracks exactly at their launch frame and cut blocks at loop ends, so every
        // change lands on a block start (rendered position = playhead + compensation).
        if (current_ && play && pendingSeek_ < 0) {
            const int64_t rp = rtPosition_ + current_->compensation;
            for (const RenderTrack &t : current_->tracks) {
                TrackRuntime &rt = *t.runtime;
                const int64_t la = rt.launchAt.load(std::memory_order_acquire);
                const bool logging = launcherRecording_.load(std::memory_order_relaxed);
                if (la >= 0 && la <= rp) {
                    const int32_t target = rt.launchTarget.load(std::memory_order_relaxed);
                    rt.playingSlot.store(target, std::memory_order_relaxed);
                    rt.slotStart.store(la, std::memory_order_relaxed);
                    rt.slotLoops = 0;
                    rt.launchAt.store(-1, std::memory_order_relaxed);
                    if (logging) launchEvents_.push(LaunchEvent{t.id, target, la});
                } else if (la >= 0 && la < rp + n) {
                    n = static_cast<int>(la - rp);
                }
                const int32_t ps = rt.playingSlot.load(std::memory_order_relaxed);
                if (ps < 0) continue;
                for (const RenderSlot &sl : t.slots) {
                    if (sl.slot != ps || sl.length <= 0) continue;
                    const int64_t start = rt.slotStart.load(std::memory_order_relaxed);
                    const int64_t rel = ((rp - start) % sl.length + sl.length) % sl.length;
                    // At a loop boundary: count it and run the follow action, exactly here.
                    if (rel == 0 && rp > start) {
                        ++rt.slotLoops;
                        if (sl.follow != 0 && rt.slotLoops >= sl.followLoops && rt.launchAt.load(std::memory_order_relaxed) < 0) {
                            const int32_t next = sl.follow == 1 ? sl.nextSlot : -1;
                            rt.playingSlot.store(next, std::memory_order_relaxed);
                            rt.slotStart.store(rp, std::memory_order_relaxed);
                            rt.slotLoops = 0;
                            if (logging) launchEvents_.push(LaunchEvent{t.id, next, rp});
                            break;
                        }
                    }
                    if (rel + n > sl.length) n = static_cast<int>(sl.length - rel);
                }
            }
        }
        float *l = left + off, *r = right + off;
        off += n;

        if (pendingSeek_ >= 0 && transportGain_ == 0.0f) {
            rtPosition_ = pendingSeek_;
            pendingSeek_ = -1;
            jumped = true;
        }
        const float target = (play && pendingSeek_ < 0) ? 1.0f : 0.0f;

        if (transportGain_ == 0.0f && target == 0.0f) {
            for (int i = 0; i < n; ++i) l[i] = r[i] = 0.0f;
            scratch_.liveNotes = rtLiveNotes_;
            scratch_.liveNoteCount = off == n ? rtLiveNoteCount_ : 0; // live notes go to the first sub-block
            if (current_) renderLiveInput(*current_, n, l, r, scratch_, anySolo, true);
            continue;
        }
        scratch_.liveNotes = rtLiveNotes_;
        scratch_.liveNoteCount = off == n ? rtLiveNoteCount_ : 0;
        if (current_) {
            // Rendered ahead by the delay compensation, so what is heard lines up with the playhead.
            renderBlock(*current_, rtPosition_ + current_->compensation, n, l, r, scratch_, true, anySolo);
        } else {
            for (int i = 0; i < n; ++i) l[i] = r[i] = 0.0f;
        }
        float g = transportGain_;
        if (g != target) {
            for (int i = 0; i < n; ++i) {
                g = target > g ? std::min(target, g + step) : std::max(target, g - step);
                l[i] *= g;
                r[i] *= g;
            }
            transportGain_ = g;
        }
        if (current_) renderLiveInput(*current_, n, l, r, scratch_, anySolo, false);
        if (play && pendingSeek_ < 0 && (clickLeft_ > 0 || metronome_.load(std::memory_order_relaxed) ||
                                         rtPosition_ < countInUntil_.load(std::memory_order_relaxed)))
            renderClick(l, r, n, rtPosition_);
        float pl = 0, pr = 0;
        for (int i = 0; i < n; ++i) {
            pl = std::max(pl, std::fabs(l[i]));
            pr = std::max(pr, std::fabs(r[i]));
        }
        raisePeak(masterPeakL_, pl);
        raisePeak(masterPeakR_, pr);
        rtPosition_ += n;
        advanced += n;
        if (cycleValid && play && pendingSeek_ < 0 && rtPosition_ == cycleEnd) rtPosition_ = cycleStart;
    }
    position_.store(pendingSeek_ >= 0 ? pendingSeek_ : rtPosition_, std::memory_order_relaxed);

    // Recording: a take covers the blocks where the transport advanced continuously.
    const uint32_t take = recordTake_.load(std::memory_order_acquire);
    if (take != rtTake_) { rtTake_ = take; rtRecordNext_ = -1; }
    rtRecordingBlock_ = false;
    rtRecordOffset_ = 0;
    rtRecordCount_ = frames;
    if (recordArmed_.load(std::memory_order_acquire) && !recordBroken_.load(std::memory_order_relaxed)) {
        // Punch window: only frames in [in, out) belong to the take (whole blocks without punch).
        const int64_t in = punchIn_.load(std::memory_order_relaxed), out = punchOut_.load(std::memory_order_relaxed);
        const bool finished = rtRecordNext_ >= 0 && rtRecordNext_ >= out; // past punch-out: nothing more to check
        if (cycleTake) {
            // Cycle take: every frame while the transport rolls continuously, across wraps. The control
            // thread cuts the capture into one take per pass when recording stops.
            if (advanced == frames && !jumped && pendingSeek_ < 0) {
                if (rtRecordNext_ < 0) recordStart_.store(before, std::memory_order_release);
                rtRecordingBlock_ = true;
                rtRecordNext_ = 0; // started
                recordEnd_.store(rtPosition_, std::memory_order_release);
            } else if (rtRecordNext_ >= 0) {
                recordBroken_.store(true, std::memory_order_release);
            }
        }
        // A block that ends with a seek still pending is a fade-out before a jump (e.g. count-in pre-roll
        // requested while playing): it never starts a take, and during a take the jump breaks it below.
        else if (!finished && rtPosition_ - before == frames && pendingSeek_ < 0) {
            const int64_t blockStart = rtPosition_ - frames;
            const int64_t from = std::max(blockStart, in), to = std::min(rtPosition_, out);
            if (to > from) {
                if (rtRecordNext_ < 0) recordStart_.store(from, std::memory_order_release);
                if (rtRecordNext_ >= 0 && from != rtRecordNext_) recordBroken_.store(true, std::memory_order_release);
                else {
                    rtRecordingBlock_ = true;
                    rtRecordOffset_ = static_cast<int>(from - blockStart);
                    rtRecordCount_ = static_cast<int>(to - from);
                    recordEnd_.store(to, std::memory_order_release);
                }
                rtRecordNext_ = to;
            }
        } else if (!finished && rtRecordNext_ >= 0) {
            recordBroken_.store(true, std::memory_order_release); // paused or sought during the take
        }
    }
    if (rtRecordingBlock_ && recordMidi_.load(std::memory_order_acquire)) {
        for (int i = 0; i < rtMidiCount_; ++i) {
            RecordedMidi e = rtMidiEvents_[i];
            e.pos = rtPosition_ - frames + rtRecordOffset_; // block-accurate, clamped into the punch window
            if (!midiRecordQueue_.push(e)) midiRecordDropped_.fetch_add(1, std::memory_order_relaxed);
        }
    }
    rtMidiCount_ = 0;
}

// ---- Offline ------------------------------------------------------------

bool Engine::renderOffline(int64_t start, int64_t frames, float *left, float *right) {
    if (start < 0 || frames < 0 || !left || !right) return false;
    renderPendingStretchesNow();
    const auto offline = offlinePlugins();
    const auto state = compile(nullptr, &offline);
    const bool anySolo = soloCount_.load() > 0;
    auto scratch = std::make_unique<Scratch>();
    std::vector<SynthState> synths(state->tracks.size());
    // Delay compensation: render the timeline ahead by the compensation and pre-roll that much first, so
    // output frame j is timeline frame start + j exactly as heard live.
    const int64_t m = state->compensation;
    float discardL[kMaxBlock], discardR[kMaxBlock];
    for (int64_t done = 0; done < m;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, m - done));
        renderBlock(*state, start + done, n, discardL, discardR, *scratch, false, anySolo, synths.data());
        done += n;
    }
    for (int64_t done = 0; done < frames;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, frames - done));
        renderBlock(*state, start + m + done, n, left + done, right + done, *scratch, false, anySolo, synths.data());
        done += n;
    }
    return true;
}

int32_t Engine::compensation() const {
    return compile(nullptr, &plugins_)->compensation; // a throwaway snapshot with fresh delay lines (no live state touched)
}

bool Engine::renderToWav(const std::string &path, int64_t start, int64_t frames, int32_t bits, std::string &err) {
    if (start < 0 || frames <= 0) {
        err = "invalid range";
        return false;
    }
    std::unique_ptr<WavWriter> w(openWavWriter(path, sampleRate_, bits, err));
    if (!w) return false;
    renderPendingStretchesNow();
    const auto offline = offlinePlugins();
    const auto state = compile(nullptr, &offline);
    auto scratch = std::make_unique<Scratch>();
    std::vector<SynthState> synths(state->tracks.size());
    std::vector<float> l(kMaxBlock * 64), r(kMaxBlock * 64);
    const int64_t m = state->compensation; // pre-roll, as in renderOffline
    for (int64_t done = 0; done < m;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, m - done));
        renderBlock(*state, start + done, n, l.data(), r.data(), *scratch, false, soloCount_.load() > 0, synths.data());
        done += n;
    }
    for (int64_t done = 0; done < frames;) {
        const auto chunk = std::min<int64_t>(static_cast<int64_t>(l.size()), frames - done);
        for (int64_t o = 0; o < chunk;) {
            const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, chunk - o));
            renderBlock(*state, start + m + done + o, n, l.data() + o, r.data() + o, *scratch, false, soloCount_.load() > 0,
                        synths.data());
            o += n;
        }
        if (!w->write(l.data(), r.data(), chunk, err)) return false;
        done += chunk;
    }
    return w->close(err);
}

// ---- Diagnostics --------------------------------------------------------

void Engine::stats(DalnokStats &o) const {
    o.callbacks = callbacks_.load(std::memory_order_relaxed);
    o.frames_rendered = framesRendered_.load(std::memory_order_relaxed);
    o.max_callback_ns = maxCallbackNs_.load(std::memory_order_relaxed);
    o.last_callback_ns = lastCallbackNs_.load(std::memory_order_relaxed);
    o.max_frames_per_callback = maxFrames_.load(std::memory_order_relaxed);
    o.overloads = overloads_.load(std::memory_order_relaxed);
    o.snapshot_swaps = swaps_.load(std::memory_order_relaxed);
}

void Engine::resetStats() {
    callbacks_ = 0;
    framesRendered_ = 0;
    maxCallbackNs_ = 0;
    lastCallbackNs_ = 0;
    maxFrames_ = 0;
    overloads_ = 0;
    swaps_ = 0;
}

} // namespace dalnok
