// Engine: project model + undo (control thread) and live renderer (audio thread).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "dalnok/dalnok.h"
#include "device.hpp"
#include "capture_spool.hpp"
#include "json.hpp"
#include "midi_parser.hpp"
#include "plugin_host.hpp"
#include "render.hpp"
#include "stretch_cache.hpp"
#include "tempo_map.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace dalnok {

// ---- Project model (value type; copied wholesale for undo) ----------------

enum TrackKind : int32_t { kTrackAudio = 0, kTrackInstrument = 1, kTrackBus = 2 };

// A send from a track to a bus: level in dB, before or after the track's fader and pan.
struct Send {
    DalnokTrackId bus = 0;
    float db = 0;
    bool pre = false;
};

// A plugin on a track: the instrument (instrument tracks) or an insert effect. The live instance
// lives in Engine::plugins_ by id, outside the undoable model, so undo never reloads plugin code.
struct PluginSlot {
    int32_t id = 0;
    std::string format = "vst3", path, classId, name, vendor;
    bool instrument = false;
    std::vector<uint32_t> controls; // parameters on the device panel's controller (empty = the first automatable ones)
    std::string state; // last known plugin state (used when the plugin is missing, and for saving)
};

// Automation: breakpoints in timeline frames. Volume values are dB; pan values are -1 (left) to 1 (right).
struct AutoPoint {
    int64_t frame = 0;
    float value = 0;
};
enum AutoTarget : int32_t { kAutoVolume = 0, kAutoPan = 1 };
// A plug-in parameter lane: values are normalized 0-1 (the plug-in's own range is applied at render).
struct PluginAuto {
    int32_t slot = 0;
    uint32_t param = 0;
    std::vector<AutoPoint> points;
};

struct TrackState {
    DalnokTrackId id = 0;
    std::vector<AutoPoint> volumeAuto, panAuto; // empty = not automated (the fader and knob apply)
    std::vector<PluginAuto> pluginAuto;         // plug-in parameter lanes
    int32_t kind = kTrackAudio;
    DalnokTrackId output = 0;  // 0 = master; otherwise a bus track
    DalnokTrackId stack = 0;   // member of this summing stack (a bus track), 0 = none
    bool isStack = false;      // a bus track that is a summing stack (its members follow it in display order)
    bool collapsed = false;    // stack shown closed (members hidden in the arrangement)
    std::vector<Send> sends;   // to bus tracks
    bool armed = false;       // record-enabled
    int32_t inputChannel = 0; // zero-based input of the recording device (audio tracks)
    std::vector<PluginSlot> plugins; // instrument first (if any), then inserts in processing order
    std::string name;
    int32_t color = 0;        // gradient step (see "06 - Design/Track Colors")
    int32_t customColor = -1; // 0xRRGGBB pinned by the user, or -1 = automatic
    float gainDb = 0;
    float pan = 0;
    bool muted = false;
    bool solo = false;
    std::shared_ptr<TrackRuntime> runtime; // shared across model copies
};

// MIDI note in frames, relative to the start of its clip's source (like an audio offset).
struct MidiNote {
    int64_t start = 0, length = 0;
    uint8_t pitch = 60, velocity = 100;
};
using NoteList = std::shared_ptr<const std::vector<MidiNote>>; // immutable; shared across undo copies

struct ClipState {
    DalnokClipId id = 0;
    int32_t folder = 0; // take folder this clip belongs to (0 = none)
    bool alt = false;   // a take inside a folder: kept, not played (the comp's pieces play)
    NoteList notes; // non-null: MIDI clip (media = 0)
    bool midi() const { return notes != nullptr; }
    DalnokTrackId track = 0;
    DalnokMediaId media = 0;
    int64_t start = 0, offset = 0, length = 0;
    int64_t fadeIn = 0, fadeOut = 0; // frames
    int32_t fadeCurve = 0;           // FadeCurve
    float gainDb = 0;                // clip (region/item) gain
    double rate = 1.0;               // source frames per timeline frame (≠1: time-stretched)
    float pitch = 0;                 // transposition in semitones (preservePitch only)
    bool preservePitch = true;       // false: varispeed (pitch follows rate)
    bool stretched() const { return std::fabs(rate - 1.0) > 1e-9 || pitch != 0; }
    int64_t sourceLength() const { return static_cast<int64_t>(std::llround(static_cast<double>(length) * rate)); }
    std::string name;
};

// Take folder (comping): takes are alternate clips (ClipState::alt, kept but not played); the comp says which
// take plays where and is realized as ordinary clips tagged with the folder (rebuilt on every comp change).
struct CompSegment {
    int64_t from = 0, to = 0; // timeline frames
    int32_t take = 0;         // index into TakeFolder::takes
};
struct TakeFolder {
    int32_t id = 0;
    DalnokTrackId track = 0;
    std::vector<DalnokClipId> takes; // oldest first
    std::vector<CompSegment> comp;   // sorted, non-overlapping
};

struct Model {
    std::vector<TrackState> tracks; // display order
    std::vector<TakeFolder> folders;
    float masterGainDb = 0; // the master fader
    std::vector<ClipState> clips;   // z-order: later = on top
    std::vector<TempoPoint> tempo{TempoPoint{}};    // quarter-note beats; first point at beat 0
    std::vector<MeterChange> meters{MeterChange{}}; // first change at bar 0
    double bpm() const { return tempo.front().bpm; }

    TrackState *track(DalnokTrackId id);
    const TrackState *track(DalnokTrackId id) const;
    ClipState *clip(DalnokClipId id);
    const ClipState *clip(DalnokClipId id) const;
};

struct PoolEntry {
    std::string path;                     // absolute source path ("" if generated)
    std::unique_ptr<DalnokMedia> handle;  // impl == nullptr when offline
    int64_t frames = 0;
    int32_t channels = 0;
};

class Engine {
public:
    explicit Engine(double sampleRate);
    ~Engine();

    double sampleRate() const { return sampleRate_; }

    // Device
    bool startDevice(std::string &err);
    void stopDevice();
    bool deviceRunning() const { return device_ != nullptr || duplex_ != nullptr; }
    // Switches output (empty uid = system default). On failure the previous device keeps running.
    bool setOutputDevice(const std::string &uid, std::string &err);
    const std::string &outputDeviceUid() const { return outputUid_; }
    bool deviceAlive() const { return duplex_ ? duplex_->alive() : (!device_ || device_->alive()); }
    double hardwareSampleRate() const { return duplex_ ? duplex_->hardwareSampleRate() : (device_ ? device_->hardwareSampleRate() : 0); }
    // Captures the given device input channels (zero-based) into one interleaved spool.
    bool startCapture(const std::string &uid, const std::vector<int> &channels, const std::string &path, std::string &err);
    bool startCapture(const std::string &uid, int channel, const std::string &path, std::string &err) {
        return startCapture(uid, std::vector<int>{channel}, path, err);
    }
    // Recording: one armed audio track (captured from `inputUid`, the explicit output device or
    // kSimulatedInput) and/or one armed instrument track (MIDI). The take starts when the
    // transport rolls; files go to `directory` with a journal (see record.cpp).
    struct RecordResult {
        DalnokClipId audioClip = 0, midiClip = 0; // audioClip: the first armed audio track's take
        std::vector<DalnokClipId> audioClips;      // every placed audio take, in track order
        std::vector<int32_t> takeFolders;          // cycle takes: one folder per armed audio track
        DalnokMediaId media = 0;
        uint64_t frames = 0;   // audio frames in the finished or recovered file
        int64_t start = -1;    // timeline frame where the take began (before latency compensation)
        int64_t latency = 0;   // frames subtracted when placing audio
        int32_t notes = 0;
        bool recovered = false; // failed take: the valid prefix was saved but not placed
        std::string path, journal;
        DalnokCaptureStats stats{};
    };
    bool startRecording(const std::string &inputUid, const std::string &directory, std::string &err);
    bool stopRecording(RecordResult &result, std::string &err);
    bool recording() const { return recording_; }
    int64_t recordStart() const { return recordStart_.load(std::memory_order_acquire); }
    bool recordBroken() const { return recordBroken_.load(std::memory_order_acquire); }
    void setRecordLatencyOffset(int64_t frames) { latencyOffset_ = frames; }
    int64_t recordLatency() const; // device-reported round trip + offset
    void setMonitoring(bool on) { monitoring_.store(on, std::memory_order_relaxed); }
    // Metronome: a click on every beat (accented on the bar) while the transport rolls. Live path only;
    // offline renders and exports never contain it.
    void setMetronome(bool on, float level) {
        metronomeLevel_.store(std::clamp(level, 0.0f, 1.0f), std::memory_order_relaxed);
        metronome_.store(on, std::memory_order_relaxed);
    }
    bool metronome() const { return metronome_.load(std::memory_order_relaxed); }
    // Count-in: the click also sounds before `frame` (0 = off), whether or not the metronome is on.
    void setCountIn(int64_t frame) { countInUntil_.store(std::max<int64_t>(0, frame), std::memory_order_relaxed); }
    // Cycle (loop) playback between two frames. Transport state saved with the project, not an undo step.
    // Playback that crosses `end` continues at `start` on the exact sample; recording plays straight through.
    bool setCycle(bool on, int64_t start, int64_t end, std::string &err);
    // Punch: a take only records [in, out); the transport rolls before and after (pre- and post-roll).
    // Used for punch in/out and for count-in (in = where recording was started). Not saved.
    bool setPunch(bool on, int64_t in, int64_t out, std::string &err);
    void punch(bool &on, int64_t &in, int64_t &out) const {
        in = punchIn_.load(std::memory_order_relaxed); out = punchOut_.load(std::memory_order_relaxed);
        on = in != INT64_MIN;
    }
    void cycle(bool &on, int64_t &start, int64_t &end) const {
        on = cycleOn_.load(std::memory_order_relaxed);
        start = cycleStart_.load(std::memory_order_relaxed);
        end = cycleEnd_.load(std::memory_order_relaxed);
    }
    bool monitoring() const { return monitoring_.load(std::memory_order_relaxed); }
    void setSimulatedLatency(int64_t frames) { simulatedLatency_ = frames; }
    // Runs one duplex cycle on the simulated input device (tests and simulation).
    bool pumpInput(const float *input, float *left, float *right, int frames);
    bool pumpInputChannels(const float *const *inputs, int count, float *left, float *right, int frames);
    // MIDI input
    bool openMidiInput(int32_t uniqueId, std::string &err);
    bool injectMidi(uint8_t status, uint8_t data1, uint8_t data2);
    uint64_t midiDropped() const;
    int32_t recordedMidiEvents() const { return static_cast<int32_t>(midiTake_.size()); }
    bool stopCapture(DalnokCaptureStats &stats, std::string &err, bool restoreOutput = true);
    bool captureActive() const { return duplex_ != nullptr; }
    bool captureStatus(DalnokCaptureStats &stats) const;
    void collectGarbage();
    // Runs the live render path manually (no device may be running). For tests and simulation.
    bool pump(float *left, float *right, int frames);

    // Meters: peak since the last read, then reset (control thread).
    bool readTrackMeter(DalnokTrackId id, float &l, float &r);
    void readMasterMeter(float &l, float &r);

    // Media pool
    DalnokMediaId poolAdd(std::shared_ptr<const Media> media, const std::string &path);
    const PoolEntry *poolEntry(DalnokMediaId id) const;
    // Points an existing pool entry at new decoded media (e.g. relinking an offline file). Not undoable.
    bool poolRelink(DalnokMediaId id, std::shared_ptr<const Media> media, const std::string &path, std::string &err);

    // Model (read)
    const Model &model() const { return model_; }
    uint64_t revision() const { return revision_; }
    int64_t sessionLength() const;

    // Commands (each is an undo step unless inside a group). Return false and
    // set `err` on invalid input, leaving the model untouched.
    DalnokTrackId addTrack(const std::string &name, std::string &err);
    bool removeTrack(DalnokTrackId id, std::string &err);
    bool renameTrack(DalnokTrackId id, const std::string &name, std::string &err);
    bool setGainDb(DalnokTrackId id, float db, std::string &err);
    bool setMasterGainDb(float db, std::string &err);
    bool setPan(DalnokTrackId id, float pan, std::string &err);
    bool setMute(DalnokTrackId id, bool muted, std::string &err);
    bool setSolo(DalnokTrackId id, bool solo, std::string &err);
    bool moveTrack(DalnokTrackId id, int32_t index, std::string &err);
    bool nudgeClips(const std::vector<DalnokClipId> &ids, int64_t delta, std::string &err);
    bool removeClips(const std::vector<DalnokClipId> &ids, std::string &err);
    bool setTrackColor(DalnokTrackId id, int32_t customRgb, std::string &err); // -1 = automatic
    DalnokTrackId addInstrumentTrack(const std::string &name, std::string &err);
    // Routing (Phase 4): bus tracks mix what is routed or sent to them. Edits that would feed a bus back
    // into itself are rejected.
    DalnokTrackId addBusTrack(const std::string &name, std::string &err);
    bool setTrackOutput(DalnokTrackId track, DalnokTrackId bus, std::string &err); // bus 0 = master
    bool setSend(DalnokTrackId track, DalnokTrackId bus, float db, bool pre, std::string &err); // adds or updates
    bool removeSend(DalnokTrackId track, DalnokTrackId bus, std::string &err);
    // Summing stacks: a stack bus placed above its members, which are routed into it. One undo step each.
    DalnokTrackId makeStack(const std::vector<DalnokTrackId> &members, const std::string &name, std::string &err);
    bool setStackCollapsed(DalnokTrackId stack, bool collapsed, std::string &err);
    bool ungroupStack(DalnokTrackId stack, std::string &err); // members go to the stack's output; the stack goes away
    // Take folders. setComp replaces the comp (one undo step) and rebuilds the pieces that play.
    bool setComp(int32_t folder, std::vector<CompSegment> comp, std::string &err);
    int32_t makeTakeFolder(Model &m, DalnokTrackId track, std::vector<DalnokClipId> takes, std::string &err); // inside an edit
    int32_t addTakeFolder(DalnokTrackId track, std::vector<DalnokClipId> takes, std::string &err); // its own edit ("Take Folder")
    // Replaces a plug-in parameter's lane on a track (normalized 0-1; empty removes it). One undo step.
    bool setPluginAutomation(DalnokTrackId track, int32_t slot, uint32_t param, std::vector<AutoPoint> points, std::string &err);
    // Replaces a track's automation lane (sorted by frame; an empty list removes it). One undo step.
    bool setAutomation(DalnokTrackId track, int32_t target, std::vector<AutoPoint> points, std::string &err);
    bool setArmed(DalnokTrackId id, bool armed, std::string &err);
    bool setInputChannel(DalnokTrackId id, int32_t channel, std::string &err);
    // Sets the first tempo and meter; later changes keep their beat and bar positions.
    bool setTempo(double bpm, int32_t num, int32_t den, std::string &err);
    // Replaces the tempo and meter maps (one undo step). MIDI keeps its beat positions; audio keeps its time.
    bool setTempoMap(std::vector<TempoPoint> tempo, std::vector<MeterChange> meters, std::string &err);
    const TempoMap &tempoMap() const { return map_; }
    // Frames of plug-in delay compensation in the current snapshot (0 when no plug-in adds latency).
    int32_t compensation() const;
    // MIDI clips
    DalnokClipId addMidiClip(DalnokTrackId track, int64_t start, int64_t length, std::string &err,
                             std::vector<MidiNote> notes = {}, const char *undoName = "New MIDI Clip");
    bool setNotes(DalnokClipId id, std::vector<MidiNote> notes, std::string &err);
    bool quantize(DalnokClipId id, double gridBeats, double strength, std::string &err);
    // Plugins (ADR-0009 stage 3). Loading runs plugin code in this process (control thread).
    int32_t addPlugin(DalnokTrackId track, const std::string &path, const std::string &classId, std::string &err);
    bool removePlugin(DalnokTrackId track, int32_t slot, std::string &err);
    bool setPluginControls(DalnokTrackId track, int32_t slot, std::vector<uint32_t> ids, std::string &err);
    PluginProcessor *pluginInstance(int32_t slot) const;
    std::string pluginError(int32_t slot) const;
    bool pluginState(int32_t slot, std::string &bytes) const;
    bool setPluginState(int32_t slot, const std::string &bytes, std::string &err);
    void touchPlugin() { ++revision_; } // a parameter changed: the project has unsaved changes
    bool recolorAsGradient(std::string &err); // automatic tracks get gradient steps in display order
    DalnokClipId addClip(DalnokTrackId track, DalnokMediaId media, int64_t start, int64_t offset, int64_t length,
                         std::string &err);
    bool removeClip(DalnokClipId id, std::string &err);
    bool moveClip(DalnokClipId id, DalnokTrackId track, int64_t start, std::string &err);
    bool setClipRegion(DalnokClipId id, int64_t start, int64_t offset, int64_t length, std::string &err);
    DalnokClipId splitClip(DalnokClipId id, int64_t at, std::string &err);
    bool setClipFades(DalnokClipId id, int64_t fadeIn, int64_t fadeOut, int32_t curve, std::string &err);
    bool setClipGain(DalnokClipId id, float gainDb, std::string &err);
    // Time-stretch: new timeline length and speed (source span = length × rate), pitch, mode.
    bool setClipStretch(DalnokClipId id, int64_t length, double rate, float pitch, bool preservePitch, std::string &err);
    // Stretch rendering status (background). True if finished renders were installed.
    bool pollJobs();
    int pendingJobs() const { return cache_.pending(); }
    bool clipProcessing(const ClipState &c) const;

    // Undo
    bool undo();
    bool redo();
    bool canUndo() const { return !undo_.empty(); }
    bool canRedo() const { return !redo_.empty(); }
    std::string undoName() const { return undo_.empty() ? "" : undo_.back().name; }
    std::string redoName() const { return redo_.empty() ? "" : redo_.back().name; }
    void beginGroup(const std::string &name);
    void endGroup();

    // Project
    void newProject();
    // copyMedia: copy referenced audio not already inside the project folder into
    // "<project folder>/Audio Files/" and reference the copies.
    bool saveProject(const std::string &path, std::string &err, bool copyMedia = false, bool markSaved = true);
    bool loadProject(const std::string &path, int32_t &missing, std::string &err);
    // Two-phase load: prepare (parse + decode, any thread) then apply (control thread).
    struct PreparedProject;
    static std::unique_ptr<PreparedProject> prepareProject(const std::string &path, double sampleRate,
                                                           int32_t &missing, std::string &err);
    void applyProject(std::unique_ptr<PreparedProject> p, bool recovered = false);
    // Imports another DAW's project (see import/import.hpp) into a prepared project + JSON report.
    static std::unique_ptr<PreparedProject> prepareImport(const std::string &path, double sampleRate, int32_t &missing,
                                                          std::string &reportJson, std::string &err);
    static std::unique_ptr<PreparedProject> prepareDocument(const json::Value &doc, const std::filesystem::path &dir,
                                                            double sampleRate, int32_t &missing, std::string &err);
    bool dirty() const { return revision_ != savedRevision_; }
    json::Value describe() const; // model as JSON (used by save and session.describe)

    // Transport
    void play() { playing_.store(true, std::memory_order_relaxed); }
    void pause() { playing_.store(false, std::memory_order_relaxed); }
    void seek(int64_t frame) { seekRequest_.store(std::max<int64_t>(0, frame), std::memory_order_relaxed); }
    bool playing() const { return playing_.load(std::memory_order_relaxed); }
    int64_t position() const { return position_.load(std::memory_order_relaxed); }

    // Offline
    bool renderOffline(int64_t start, int64_t frames, float *left, float *right);
    bool renderToWav(const std::string &path, int64_t start, int64_t frames, int32_t bits, std::string &err);

    void stats(DalnokStats &out) const;
    void resetStats();

private:
    struct UndoStep {
        std::string name;
        Model model;
    };

    // Runs `fn` against the model; on success records an undo step and publishes.
    template <typename F>
    bool edit(const char *name, bool structural, F &&fn);
    void restore(Model m);
    void syncRuntimes();
    using PluginMap = std::map<int32_t, std::shared_ptr<PluginProcessor>>;
    std::unique_ptr<RenderState> compile(std::vector<StretchJob> *needed = nullptr, const PluginMap *plugins = nullptr) const;
    PluginMap offlinePlugins() const; // fresh instances with the live state, for offline renders
    void instantiatePlugins();        // creates missing instances for every slot in the model
    void captureLiveState(Model &m) const;
    StretchKey stretchKey(const ClipState &c) const;
    void renderPendingStretchesNow();
    void commit();
    void resetModel();

    static void audioCallback(void *ctx, float *left, float *right, int frames) DALNOK_NONBLOCKING;
    static void duplexCallback(void *ctx, float *left, float *right, const float *const *inputs, int inputCount,
                               int frames) DALNOK_NONBLOCKING;
    void process(float *left, float *right, int frames) DALNOK_NONBLOCKING;
    void handleMidiInput(int64_t pos) DALNOK_NONBLOCKING;
    void renderClick(float *left, float *right, int frames, int64_t pos) DALNOK_NONBLOCKING;
    void drainRecordedMidi();
    void waitForAudioCycles();
    bool validNotes(const std::vector<MidiNote> &notes, std::string &err) const;

    double sampleRate_;

    // Control-thread state.
    Model model_;
    TempoMap map_; // built from model_.tempo in syncRuntimes
    std::shared_ptr<TrackRuntime> masterRuntime_ = std::make_shared<TrackRuntime>(); // master fader target + smoothing
    // Live delay-compensation lines by connection and length; shared by snapshots (audio thread only processes them).
    mutable std::map<std::string, std::shared_ptr<DelayLine>> delayCache_;
    std::map<DalnokMediaId, PoolEntry> pool_;
    std::vector<UndoStep> undo_, redo_;
    int groupDepth_ = 0;
    bool groupRecorded_ = false;
    std::string groupName_;
    uint64_t revision_ = 1, savedRevision_ = 1;
    DalnokTrackId nextTrack_ = 1;
    DalnokClipId nextClip_ = 1;
    DalnokMediaId nextMedia_ = 1;
    int32_t nextColor_ = 0;
    std::unique_ptr<CaptureSpool> captureSpool_;
    std::unique_ptr<CaptureWriter> captureWriter_;
    std::unique_ptr<AudioDuplexDevice> duplex_;
    CaptureWriter *captureRT_ = nullptr; // published before start; cleared after synchronous stop
    // Device input channel for each spool channel, and interleaving space (set before the device starts).
    std::array<int, 64> captureMap_{};
    int captureChannels_ = 0;
    std::vector<float> captureScratch_;
    static constexpr int kMaxCaptureBlock = 8192;
    std::atomic<bool> captureInputFailed_{false};
    std::atomic<uint64_t> captureMissingFrames_{0};
    std::unique_ptr<AudioDevice> device_;
    std::string outputUid_;
    PluginMap plugins_;                       // live instances by slot id
    std::map<int32_t, std::string> pluginErrors_;
    int32_t nextPlugin_ = 1;
    uint64_t pluginEdits_ = 0;
    // Recording (control thread)
    bool recording_ = false;
    DalnokTrackId recordAudioTrack_ = 0, recordMidiTrack_ = 0; // audio: the first armed audio track
    // Every armed audio track in this take: spool channel i belongs to recordAudio_[i].
    struct RecordAudio { DalnokTrackId track; std::string name; int channel; std::string wav; };
    std::vector<RecordAudio> recordAudio_;
    std::string recordSpool_, recordWav_, recordJournal_;
    int64_t latencyOffset_ = 0, simulatedLatency_ = 0;
    bool simulatedInput_ = false;
    struct RecordedMidi { int64_t pos; uint8_t status, data1, data2; };
    std::vector<RecordedMidi> midiTake_;
    // Recording (shared with the audio thread)
    std::atomic<bool> recordArmed_{false}, recordMidi_{false}, recordBroken_{false}, monitoring_{false};
    std::atomic<int64_t> recordStart_{-1}, recordEnd_{-1};
    std::atomic<bool> recordSession_{false}; // capture is gated by the transport (audio take in progress)
    std::atomic<uint32_t> recordTake_{0};
    std::atomic<uint64_t> midiRecordDropped_{0};
    SpscQueue<RecordedMidi, 4096> midiRecordQueue_;
    // MIDI input: slot 0 is fed by injectMidi (control thread), others by Core MIDI ports.
    static constexpr int kMidiInputs = 8;
    std::array<std::unique_ptr<MidiParser>, kMidiInputs> midiParsers_;
    std::array<std::atomic<MidiParser *>, kMidiInputs> midiInputs_{};
    std::vector<std::unique_ptr<MidiParser>> retiredParsers_; // failed opens; freed with the engine
    std::shared_ptr<void> midiClient_; // platform handle; closed after the device stops
    mutable StretchCache cache_;

    // Control -> audio handoff.
    std::atomic<RenderState *> pending_{nullptr};
    SpscQueue<RenderState *, 64> retired_;

    // Audio-thread state.
    RenderState *current_ = nullptr;
    Scratch scratch_{};
    float transportGain_ = 0.0f;
    int64_t pendingSeek_ = -1;
    int64_t rtPosition_ = 0;
    int64_t rtRecordNext_ = -1;
    bool rtRecordingBlock_ = false;
    int rtRecordOffset_ = 0, rtRecordCount_ = 0; // the part of this callback's block that belongs to the take
    uint32_t rtTake_ = 0;
    float clickY1_ = 0, clickY2_ = 0, clickCoefNow_ = 0, clickEnv_ = 0;
    int clickLeft_ = 0;
    RecordedMidi rtMidiEvents_[256]{};
    int rtMidiCount_ = 0;
    PluginNote rtLiveNotes_[256]{}; // this callback's live notes for a plugin instrument
    int rtLiveNoteCount_ = 0;
    std::atomic<float> masterPeakL_{0.0f}, masterPeakR_{0.0f};

    // Shared atomics.
    std::atomic<bool> playing_{false};
    std::atomic<int32_t> soloCount_{0};
    std::atomic<bool> metronome_{false};
    std::atomic<float> metronomeLevel_{0.5f};
    // Click oscillator coefficients (control thread computes them; see syncRuntimes).
    std::atomic<float> clickCoef_{0}, clickAccentCoef_{0}, clickSin_{0}, clickAccentSin_{0}, clickDecay_{0};
    std::atomic<int64_t> seekRequest_{-1};
    std::atomic<int64_t> position_{0};
    std::atomic<bool> cycleOn_{false};
    std::atomic<int64_t> punchIn_{INT64_MIN}, punchOut_{INT64_MAX};
    std::atomic<int64_t> countInUntil_{0};
    std::atomic<bool> recordCycle_{false};      // this take loops the cycle and becomes one take per pass
    int64_t recordCycleStart_ = 0, recordCycleEnd_ = 0; // the cycle when that take started (control thread)
    std::atomic<int64_t> cycleStart_{0}, cycleEnd_{0};

    // Diagnostics (written by the audio thread).
    std::atomic<uint64_t> callbacks_{0}, framesRendered_{0}, maxCallbackNs_{0}, lastCallbackNs_{0};
    std::atomic<uint32_t> maxFrames_{0}, overloads_{0}, swaps_{0};
};

struct Engine::PreparedProject {
    Model model;
    std::map<DalnokMediaId, PoolEntry> pool;
    DalnokTrackId maxTrack = 0;
    DalnokClipId maxClip = 0;
    DalnokMediaId maxMedia = 0;
    int32_t maxColor = -1;
    double sampleRate = 0;
    bool imported = false; // came from another DAW: starts dirty, untitled
    bool cycleOn = false;  // transport cycle (frames at the engine rate)
    int64_t cycleStart = 0, cycleEnd = 0;
    std::vector<std::pair<StretchKey, std::shared_ptr<const Media>>> stretched; // precomputed for playback
};

float dbToGain(float db);
// Atomic replace, then flush the containing folder so the rename survives power loss where supported.
bool writeFileDurably(const std::string &path, const std::string &data, std::string &err);
bool syncDirectory(const std::string &dir);
constexpr const char *kSimulatedInput = "dalnok:simulated-input";

} // namespace dalnok
