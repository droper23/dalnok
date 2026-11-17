// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"

#include <algorithm>
#include <cmath>
#include <ctime>
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
    if (!simulatedInput_ || !duplex_ || !left || !right || frames <= 0) return false;
    duplexCallback(this, left, right, input, frames);
    collectGarbage();
    return true;
}

bool Engine::startCapture(const std::string &uid, int channel, const std::string &path, std::string &err) {
    if (duplex_ || captureWriter_) { err = "capture is already active"; return false; }
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
    else duplex = createDuplexDevice(uid, sampleRate_, channel, err);
    if (!duplex) return false;
    const int fd = CaptureSpool::create(path, static_cast<uint32_t>(sampleRate_), 1);
    if (fd < 0) { err = "cannot create new capture spool"; return false; }
    try {
        captureSpool_ = std::make_unique<CaptureSpool>(fd, 1);
        // About 5.5 seconds at 48 kHz; overflow always reports an error.
        captureWriter_ = std::make_unique<CaptureWriter>(1 << 18, 1, *captureSpool_);
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
    int32_t solos = 0;
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
    pool_.clear();
    cache_.clear();
    undo_.clear();
    redo_.clear();
    groupDepth_ = 0;
    nextColor_ = 0;
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
        // One armed track per kind: the first recording release takes one input and one MIDI stream.
        if (armed)
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

bool Engine::setTempo(double bpm, int32_t num, int32_t den, std::string &err) {
    return edit("Tempo", false, [&](Model &m) {
        if (!(bpm >= 20 && bpm <= 400)) return fail(err, "tempo must be 20-400 BPM");
        if (num < 1 || num > 32 || (den != 1 && den != 2 && den != 4 && den != 8 && den != 16))
            return fail(err, "meter must be 1-32 over 1, 2, 4, 8 or 16");
        m.bpm = bpm;
        m.meterNum = num;
        m.meterDen = den;
        return true;
    });
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
        c.name = "MIDI";
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
        const double grid = gridBeats * sampleRate_ * 60.0 / m.bpm;
        // The grid is anchored to the timeline (bar 1), not to the clip.
        const auto origin = c->start - c->offset;
        std::vector<MidiNote> notes = *c->notes;
        for (auto &n : notes) {
            const double at = static_cast<double>(origin + n.start);
            const double snapped = std::round(at / grid) * grid;
            n.start = std::max<int64_t>(0, static_cast<int64_t>(std::llround(at + (snapped - at) * strength)) - origin);
        }
        c->notes = sortedNotes(std::move(notes));
        return true;
    });
}

bool Engine::removeTrack(DalnokTrackId id, std::string &err) {
    return edit("Delete Track", true, [&](Model &m) {
        if (!m.track(id)) return fail(err, "no such track");
        std::erase_if(m.tracks, [id](const TrackState &t) { return t.id == id; });
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

std::unique_ptr<RenderState> Engine::compile(std::vector<StretchJob> *needed) const {
    auto s = std::make_unique<RenderState>();
    s->synth = SynthParams::make(sampleRate_);
    for (const auto &t : model_.tracks) {
        RenderTrack rt;
        rt.runtime = t.runtime;
        rt.instrument = t.kind == kTrackInstrument;
        if (rt.instrument && t.armed) s->liveTrack = static_cast<int32_t>(s->tracks.size());
        for (const auto &c : model_.clips) {
            if (c.track != t.id) continue;
            if (c.midi()) {
                if (!rt.instrument) continue;
                for (const auto &n : *c.notes) {
                    if (n.start < c.offset || n.start >= c.offset + c.length) continue; // outside the clip window
                    const int64_t at = c.start + n.start - c.offset;
                    const int64_t end = c.start + std::min(n.start + n.length, c.offset + c.length) - c.offset;
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
            rt.clips.push_back({media, c.start, offset, len, fi, fo, c.fadeCurve, dbToGain(c.gainDb)});
            if (media->channelCount() > 1) rt.monoSource = false;
        }
        std::stable_sort(rt.notes.begin(), rt.notes.end(),
                         [](const RenderNote &a, const RenderNote &b) { return a.start < b.start; });
        s->tracks.push_back(std::move(rt));
    }
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

void Engine::duplexCallback(void *ctx, float *left, float *right, const float *input, int frames) DALNOK_NONBLOCKING {
    auto *self = static_cast<Engine *>(ctx);
    audioCallback(ctx, left, right, frames);
    if (!input) {
        self->captureMissingFrames_.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed);
        self->captureInputFailed_.store(true, std::memory_order_release);
        return;
    }
    // In a recording session only blocks where the transport rolled continuously belong to the take.
    const bool take = !self->recordSession_.load(std::memory_order_acquire) || self->rtRecordingBlock_;
    if (take && self->captureRT_) self->captureRT_->push(input, static_cast<uint32_t>(frames));
    if (self->monitoring_.load(std::memory_order_relaxed))
        for (int i = 0; i < frames; ++i) { left[i] += input[i]; right[i] += input[i]; }
}

void Engine::handleMidiInput(int64_t pos) DALNOK_NONBLOCKING {
    constexpr int kMaxEvents = 256;
    RecordedMidi events[kMaxEvents];
    int count = 0;
    const int32_t live = current_ ? current_->liveTrack : -1;
    SynthState *synth = live >= 0 ? &current_->tracks[static_cast<size_t>(live)].runtime->live : nullptr;
    for (auto &slot : midiInputs_) {
        MidiParser *parser = slot.load(std::memory_order_acquire);
        if (!parser) continue;
        MidiMessage m;
        while (parser->pop(m)) {
            const uint8_t type = m.status & 0xf0;
            const bool on = type == 0x90 && m.data2 > 0, off = type == 0x80 || (type == 0x90 && m.data2 == 0);
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

    for (int off = 0; off < frames;) {
        const int n = std::min(kMaxBlock, frames - off);
        float *l = left + off, *r = right + off;
        off += n;

        if (pendingSeek_ >= 0 && transportGain_ == 0.0f) {
            rtPosition_ = pendingSeek_;
            pendingSeek_ = -1;
        }
        const float target = (play && pendingSeek_ < 0) ? 1.0f : 0.0f;

        if (transportGain_ == 0.0f && target == 0.0f) {
            for (int i = 0; i < n; ++i) l[i] = r[i] = 0.0f;
            if (current_) renderLiveInput(*current_, n, l, r, scratch_, anySolo);
            continue;
        }
        if (current_) {
            renderBlock(*current_, rtPosition_, n, l, r, scratch_, true, anySolo);
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
        if (current_) renderLiveInput(*current_, n, l, r, scratch_, anySolo);
        float pl = 0, pr = 0;
        for (int i = 0; i < n; ++i) {
            pl = std::max(pl, std::fabs(l[i]));
            pr = std::max(pr, std::fabs(r[i]));
        }
        raisePeak(masterPeakL_, pl);
        raisePeak(masterPeakR_, pr);
        rtPosition_ += n;
    }
    position_.store(pendingSeek_ >= 0 ? pendingSeek_ : rtPosition_, std::memory_order_relaxed);

    // Recording: a take covers the blocks where the transport advanced continuously.
    const uint32_t take = recordTake_.load(std::memory_order_acquire);
    if (take != rtTake_) { rtTake_ = take; rtRecordNext_ = -1; }
    rtRecordingBlock_ = false;
    if (recordArmed_.load(std::memory_order_acquire) && !recordBroken_.load(std::memory_order_relaxed)) {
        if (rtPosition_ - before == frames) {
            const int64_t blockStart = rtPosition_ - frames;
            if (rtRecordNext_ < 0) recordStart_.store(blockStart, std::memory_order_release);
            if (rtRecordNext_ >= 0 && blockStart != rtRecordNext_) recordBroken_.store(true, std::memory_order_release);
            else { rtRecordingBlock_ = true; recordEnd_.store(rtPosition_, std::memory_order_release); }
            rtRecordNext_ = rtPosition_;
        } else if (rtRecordNext_ >= 0) {
            recordBroken_.store(true, std::memory_order_release); // paused or sought during the take
        }
    }
    if (rtRecordingBlock_ && recordMidi_.load(std::memory_order_acquire)) {
        for (int i = 0; i < rtMidiCount_; ++i) {
            RecordedMidi e = rtMidiEvents_[i];
            e.pos = rtPosition_ - frames;
            if (!midiRecordQueue_.push(e)) midiRecordDropped_.fetch_add(1, std::memory_order_relaxed);
        }
    }
    rtMidiCount_ = 0;
}

// ---- Offline ------------------------------------------------------------

bool Engine::renderOffline(int64_t start, int64_t frames, float *left, float *right) {
    if (start < 0 || frames < 0 || !left || !right) return false;
    renderPendingStretchesNow();
    const auto state = compile();
    const bool anySolo = soloCount_.load() > 0;
    Scratch scratch{};
    std::vector<SynthState> synths(state->tracks.size());
    for (int64_t done = 0; done < frames;) {
        const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, frames - done));
        renderBlock(*state, start + done, n, left + done, right + done, scratch, false, anySolo, synths.data());
        done += n;
    }
    return true;
}

bool Engine::renderToWav(const std::string &path, int64_t start, int64_t frames, int32_t bits, std::string &err) {
    if (start < 0 || frames <= 0) {
        err = "invalid range";
        return false;
    }
    std::unique_ptr<WavWriter> w(openWavWriter(path, sampleRate_, bits, err));
    if (!w) return false;
    renderPendingStretchesNow();
    const auto state = compile();
    Scratch scratch{};
    std::vector<SynthState> synths(state->tracks.size());
    std::vector<float> l(kMaxBlock * 64), r(kMaxBlock * 64);
    for (int64_t done = 0; done < frames;) {
        const auto chunk = std::min<int64_t>(static_cast<int64_t>(l.size()), frames - done);
        for (int64_t o = 0; o < chunk;) {
            const int n = static_cast<int>(std::min<int64_t>(kMaxBlock, chunk - o));
            renderBlock(*state, start + done + o, n, l.data() + o, r.data() + o, scratch, false, soloCount_.load() > 0,
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
