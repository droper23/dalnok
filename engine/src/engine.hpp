// Engine: project model + undo (control thread) and live renderer (audio thread).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "model.hpp"
#include "render_compiler.hpp"
#include "transport.hpp"
#include "recording_state.hpp"
#include "dalnok/dalnok.h"
#include "device.hpp"
#include "capture_spool.hpp"
#include "json.hpp"
#include "midi_parser.hpp"
#include "plugin_host.hpp"
#include "plugin_remote.hpp"
#include "plugin_service.hpp"
#include "undo_stack.hpp"
#include "stream_cache.hpp"
#include "render.hpp"
#include "stretch_cache.hpp"
#include "tempo_map.hpp"
#include "loudness.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <functional>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <map>
#include <set>
#include <memory>
#include <string>
#include <vector>

namespace dalnok {
int32_t projectFormatVersion(); // project.cpp

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
    // Input device for monitoring and recording (empty = none). While any track monitors its input (Input Monitoring,
    // or armed with armed-track monitoring on), the engine runs the input and output devices as one duplex device.
    bool setInputDevice(const std::string &uid, std::string &err);
    const std::string &inputDeviceUid() const { return inputUid_; }
    bool inputRunning() const { return duplex_ != nullptr && !simulatedInput_; }
    const std::string &inputError() const { return inputError_; }
    bool setInputMonitor(DalnokTrackId id, bool on, std::string &err);
    // Track groups (engine_groups.cpp). Group edits are undoable; the clutch (suspending every group) is not saved.
    int32_t createGroup(const std::string &name, const std::vector<DalnokTrackId> &members, std::string &err);
    bool removeGroup(int32_t id, std::string &err);
    bool setTrackGroup(DalnokTrackId track, int32_t group, std::string &err);
    bool setGroup(const TrackGroup &g, std::string &err); // name and links
    const std::vector<TrackGroup> &groups() const { return model_.groups; }
    void setGroupClutch(bool suspended) { groupClutch_ = suspended; }
    bool groupClutch() const { return groupClutch_; }
    // The other members of `id`'s group when that group links `what` (empty with the clutch on).
    std::vector<DalnokTrackId> groupLinked(DalnokTrackId id, bool TrackGroup::*what) const;
    // Latency measurement (loopback): clicks out, the same clicks back on an input channel.
    struct LatencyResult { bool ok = false; int64_t measured = 0, reported = 0; int32_t clicks = 0, spread = 0; float level = 0; std::string error; };
    bool startLatencyProbe(const std::string &uid, int channel, std::string &err);
    bool pollLatencyProbe(LatencyResult &result); // true once finished
    // Stream check (automatic latency): with a loopback input set, every new duplex stream on that device measures its
    // own round trip in its first 0.75 s (quiet bursts added to the output, cross-correlated with what came back).
    // Takes recorded on that stream use it instead of reported + offset. uid empty or channel < 0: off.
    bool setStreamCheck(const std::string &uid, int channel, std::string &err);
    // The current stream's generation (0: none yet) and its check (ok false while listening or after a failure).
    uint64_t pollStreamCheck(LatencyResult &result);
    // Live waveform of the take in progress: peaks (one per kLivePeakFrames) of the spool channel recording `track`.
    const std::vector<float> *livePeaks(DalnokTrackId track);
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
    bool recording() const { return rec_.active; }
    // Record into a launcher slot (-1 = the arrangement): takes go to this slot on each recorded track,
    // trimmed to whole bars (the bars the take fully covers), replacing what was there. Not saved.
    void setRecordSlot(int32_t slot) { rec_.recordSlot.store(slot, std::memory_order_relaxed); }
    int32_t recordSlot() const { return rec_.recordSlot.load(std::memory_order_relaxed); }
    int64_t recordStart() const { return rec_.recordStart.load(std::memory_order_acquire); }
    bool recordBroken() const { return rec_.recordBroken.load(std::memory_order_acquire); }
    void setRecordLatencyOffset(int64_t frames) { rec_.latencyOffset = frames; }
    int64_t recordLatency() const; // device-reported round trip + offset
    void setMonitoring(bool on) { rec_.monitoring.store(on, std::memory_order_relaxed); syncInput(); }
    // Metronome: a click on every beat (accented on the bar) while the transport rolls. Live path only;
    // offline renders and exports never contain it.
    void setMetronome(bool on, float level) { transport_.setMetronome(on, level); }
    bool metronome() const { return transport_.metronome.load(std::memory_order_relaxed); }
    // Count-in: the click also sounds before `frame` (0 = off), whether or not the metronome is on.
    void setCountIn(int64_t frame) { transport_.setCountIn(frame); }
    // Cycle (loop) playback between two frames. Transport state saved with the project, not an undo step.
    // Playback that crosses `end` continues at `start` on the exact sample; recording plays straight through.
    bool setCycle(bool on, int64_t start, int64_t end, std::string &err) { return transport_.setCycle(on, start, end, err); }
    // Punch: a take only records [in, out); the transport rolls before and after (pre- and post-roll).
    // Used for punch in/out and for count-in (in = where recording was started). Not saved.
    bool setPunch(bool on, int64_t in, int64_t out, std::string &err) { return transport_.setPunch(on, in, out, err); }
    void punch(bool &on, int64_t &in, int64_t &out) const { transport_.punch(on, in, out); }
    void cycle(bool &on, int64_t &start, int64_t &end) const { transport_.cycle(on, start, end); }
    bool monitoring() const { return rec_.monitoring.load(std::memory_order_relaxed); }
    void setSimulatedLatency(int64_t frames) { simulatedLatency_ = frames; }
    // Runs one duplex cycle on the simulated input device (tests and simulation).
    bool pumpInput(const float *input, float *left, float *right, int frames);
    bool pumpInputChannels(const float *const *inputs, int count, float *left, float *right, int frames);
    // MIDI input
    bool openMidiInput(int32_t uniqueId, std::string &err);
    bool injectMidi(uint8_t status, uint8_t data1, uint8_t data2);
    uint64_t midiDropped() const;
    int32_t recordedMidiEvents() const { return static_cast<int32_t>(rec_.midiTake.size()); }
    bool stopCapture(DalnokCaptureStats &stats, std::string &err, bool restoreOutput = true);
    bool captureActive() const { return rec_.captureWriter != nullptr; }
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
    // The revision at which this track's view-relevant state (track fields, its clips) last changed (A-05).
    uint64_t trackRevision(DalnokTrackId id) const {
        auto it = trackRevisions_.find(id);
        // A track never stamped individually has not changed since the last whole-project change.
        return std::max(globalRevision_, it == trackRevisions_.end() ? 0 : it->second);
    }
    bool onlyParametersSince(uint64_t revision) const {
        return lastParameterRevision_ == revision_ && revision < revision_ && revision >= firstParameterRevision_ - 1;
    }
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
    // Sidechain: feed a track's post-insert, pre-fader signal into a plug-in's sidechain input (0 = none).
    bool setSidechain(DalnokTrackId track, int32_t slot, DalnokTrackId source, std::string &err);
    // Bypass: a bypassed effect is left out of the insert chain (and its latency); a bypassed instrument is silent.
    bool setPluginBypassed(DalnokTrackId track, int32_t slot, bool bypassed, std::string &err);
    // Folding: how the device chain shows the unit (a narrow strip); saved with the project, undoable, no audio change.
    bool setPluginFolded(DalnokTrackId track, int32_t slot, bool folded, std::string &err);
    // Moves a plug-in to `index` in the track's list (insert order = processing order). Undoable.
    bool movePlugin(DalnokTrackId track, int32_t slot, int32_t index, std::string &err);
    // Duplicates a track right below it: settings, routing, sends, automation, clips (new ids) and plug-ins (new
    // instances with the same state; missing plug-ins keep their saved state). Stacks can't be duplicated yet.
    DalnokTrackId duplicateTrack(DalnokTrackId track, std::string &err);
    // Copies plug-ins (`ids`, in their chain order) from one track to another at `index` (-1 = the end): new instances
    // with the same state, one undo step. An instrument replaces the target's (an empty audio track becomes an
    // instrument track). Returns the new slot ids (empty on failure). API 47.
    std::vector<int32_t> copyPlugins(DalnokTrackId from, const std::vector<int32_t> &ids, DalnokTrackId to, int32_t index,
                                     std::string &err);
    // Hide tracks from view (they keep playing). `track` 0 with hidden=false shows every track. Undoable.
    bool setTrackHidden(DalnokTrackId track, bool hidden, std::string &err);
    // Phase (polarity) invert at the head of the strip. Undoable (API 46).
    bool setPhaseInvert(DalnokTrackId track, bool on, std::string &err);
    // Markers (undoable): add returns the id; positions are timeline frames (>= 0).
    int32_t addMarker(int64_t frame, const std::string &name, std::string &err);
    bool removeMarker(int32_t id, std::string &err);
    bool moveMarker(int32_t id, int64_t frame, std::string &err);
    bool renameMarker(int32_t id, const std::string &name, std::string &err);
    bool pluginHasSidechain(int32_t slot) const { const auto *p = pluginHost_.instance(slot); return p && p->hasSidechain(); }
    // Summing stacks: a stack bus placed above its members, which are routed into it. One undo step each.
    DalnokTrackId makeStack(const std::vector<DalnokTrackId> &members, const std::string &name, std::string &err);
    bool setStackCollapsed(DalnokTrackId stack, bool collapsed, std::string &err);
    // Lane height (view only, one undo step): `track` 0 sets every track; `height` 0 returns to the default.
    bool setTrackHeight(DalnokTrackId track, float height, std::string &err);
    bool ungroupStack(DalnokTrackId stack, std::string &err); // members go to the stack's output; the stack goes away
    // Take folders. setComp replaces the comp (one undo step) and rebuilds the pieces that play.
    bool setComp(int32_t folder, std::vector<CompSegment> comp, std::string &err);
    int32_t makeTakeFolder(Model &m, DalnokTrackId track, std::vector<DalnokClipId> takes, std::string &err); // inside an edit
    int32_t addTakeFolder(DalnokTrackId track, std::vector<DalnokClipId> takes, std::string &err); // its own edit ("Take Folder")
    // Clip launcher. A slot clip is a copy of a clip that loops when launched; launching takes effect at the next
    // bar (immediately when stopped, which starts the transport). Launch state is live-only, not undoable.
    DalnokClipId copyToSlot(DalnokClipId clip, int32_t slot, std::string &err); // one undo step
    DalnokClipId placeCopy(DalnokClipId clip, DalnokTrackId track, int64_t start, std::string &err); // a copy on the timeline
    bool launch(DalnokTrackId track, int32_t slot, std::string &err);           // slot -1 = back to the arrangement
    bool launchScene(int32_t slot, std::string &err);
    void stopLauncher();                                                         // every track back to the arrangement
    int32_t playingSlot(DalnokTrackId track) const;
    int64_t slotStart(DalnokTrackId track) const;
    int32_t queuedSlot(DalnokTrackId track, int64_t *at) const; // -2: nothing queued
    bool setFollowAction(DalnokClipId clip, int32_t action, int32_t loops, std::string &err);
    // Launcher performance recording: while on, every switch is logged; turning it off writes the
    // performance into the arrangement as clips (one undo step "Record Launcher").
    void setLauncherRecording(bool on);
    bool launcherRecording() const { return launcherRecording_.load(); }
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
    // Replaces a MIDI clip's controller events (sorted here; one undo step). See MidiCC.
    bool setControllers(DalnokClipId id, std::vector<MidiCC> events, std::string &err);
    bool quantize(DalnokClipId id, double gridBeats, double strength, std::string &err);
    // MIDI functions on `only` (empty = every note in the clip's window), one undo step; `out` gets the selected notes
    // as they are afterwards, in the same order (so an editor can keep them selected). See DalnokMidiFunction.
    bool transformNotes(DalnokClipId id, int32_t op, const std::vector<MidiNote> &only, double a, double b,
                        std::vector<MidiNote> &out, std::string &err);
    // Audio quantize (API 47, audio_quantize.cpp): the clip's transients (source frames), and a warp map that moves
    // them to the grid by `strength` (attacks at their own speed, the rest stretched to fit; one undo step).
    std::vector<int64_t> audioTransients(DalnokClipId id, double sensitivity, std::string &err) const;
    bool quantizeAudio(DalnokClipId id, double gridBeats, double strength, double sensitivity, std::string &err);
    bool setClipWarp(DalnokClipId id, WarpList warp, std::string &err); // empty: remove (one speed again)
    // Plugins (ADR-0009 stage 3). Loading runs plugin code in this process (control thread).
    int32_t addPlugin(DalnokTrackId track, const std::string &path, const std::string &classId, std::string &err);
    bool removePlugin(DalnokTrackId track, int32_t slot, std::string &err);
    bool setPluginControls(DalnokTrackId track, int32_t slot, std::vector<uint32_t> ids, std::string &err);
    PluginProcessor *pluginInstance(int32_t slot) const;
    std::string pluginError(int32_t slot) const;
    bool pluginState(int32_t slot, std::string &bytes) const;
    bool savingRecoverySnapshot_ = false; // control thread: set while dalnok_project_save_snapshot writes
    bool setPluginState(int32_t slot, const std::string &bytes, std::string &err);
    void touchPlugin() { ++revision_; } // a parameter changed: the project has unsaved changes
    bool recolorAsGradient(std::string &err); // automatic tracks get gradient steps in display order
    DalnokClipId addClip(DalnokTrackId track, DalnokMediaId media, int64_t start, int64_t offset, int64_t length,
                         std::string &err);
    bool removeClip(DalnokClipId id, std::string &err);
    bool setClipLoop(DalnokClipId id, bool on, std::string &err); // see ClipState::loopLength
    bool moveClip(DalnokClipId id, DalnokTrackId track, int64_t start, std::string &err);
    bool setClipRegion(DalnokClipId id, int64_t start, int64_t offset, int64_t length, std::string &err);
    DalnokClipId splitClip(DalnokClipId id, int64_t at, std::string &err);
    // Copies clips with every attribute (fades, gain, stretch, MIDI notes shared copy-on-write) as one undo step.
    // The earliest clip lands at `start`; tracks shift by `trackShift` places in arrangement order (0 = same tracks).
    // Returns the new ids in the order given, or empty on failure (nothing changes).
    std::vector<DalnokClipId> copyClips(const std::vector<DalnokClipId> &ids, int64_t start, int32_t trackShift, std::string &err);
    // Clipboard: copies of clips held outside the model (not undoable), so Cut then Paste works after the source is
    // gone. Paste puts the topmost source track's clips on `track`, the rest the same number of tracks below.
    bool copyToClipboard(const std::vector<DalnokClipId> &ids, std::string &err);
    std::vector<DalnokClipId> pasteClipboard(DalnokTrackId track, int64_t start, std::string &err);
    size_t clipboardCount() const { return clipboard_.size(); }
    bool setClipFades(DalnokClipId id, int64_t fadeIn, int64_t fadeOut, int32_t curve, std::string &err);
    bool setClipGain(DalnokClipId id, float gainDb, std::string &err);
    bool setClipMuted(DalnokClipId id, bool muted, std::string &err);
    // Time-stretch: new timeline length and speed (source span = length × rate), pitch, mode.
    bool setClipStretch(DalnokClipId id, int64_t length, double rate, float pitch, bool preservePitch, std::string &err);
    // Stretch rendering status (background). True if finished renders were installed.
    bool pollJobs();
    int pendingJobs() const { return cache_.pending(); }
    bool clipProcessing(const ClipState &c) const;

    // Undo
    bool undo();
    bool redo();
    bool canUndo() const { return history_.canUndo(); }
    bool canRedo() const { return history_.canRedo(); }
    std::string undoName() const { return history_.undoName(); }
    std::string redoName() const { return history_.redoName(); }
    void beginGroup(const std::string &name);
    void endGroup();

    // Project
    void newProject();
    // copyMedia: copy referenced audio not already inside the project folder into
    // "<project folder>/Audio Files/" and reference the copies.
    bool saveProject(const std::string &path, std::string &err, bool copyMedia = false, bool markSaved = true);
    // DAWproject export: the arrangement, mixer (volume, pan, mute, solo, outputs, sends) and audio in one ZIP.
    // `notes` lists what the format didn't carry (plug-ins, automation, launcher slots, ...).
    bool exportDawproject(const std::string &path, std::vector<std::string> &notes, std::string &err);
    bool loadProject(const std::string &path, int32_t &missing, std::string &err);
    // Two-phase load: prepare (parse + decode, any thread) then apply (control thread).
    struct PreparedProject;
    static std::unique_ptr<PreparedProject> prepareProject(const std::string &path, double sampleRate,
                                                           int32_t &missing, std::string &err);
    // load: activate every plug-in now. recover: keep slots unloaded. defer: show the project now and queue its
    // plug-ins for activateNextPlugin (ADR-0013).
    enum class ApplyMode { load, recover, defer };
    bool applyProject(std::unique_ptr<PreparedProject> p, ApplyMode mode = ApplyMode::load);
    // Deferred activation (control/main thread). Handles the next queued plug-in and returns how many remain (queued
    // or loading), or -1 if none were; `slot` and `seconds` report the one finished in this call. Isolated plug-ins
    // load in their own processes without blocking: the call starts their hosts and returns, `slot` is 0 until one
    // finishes (ADR-0014 stage 2).
    int32_t activateNextPlugin(int32_t &slot, double &seconds);
    int32_t pendingPluginCount() const { return static_cast<int32_t>(pluginHost_.pendingCount()); }
    bool pluginLoading(int32_t slot) const;
    bool takeEditorKey(int32_t &slot, PluginProcessor::EditorKey &key) { return pluginHost_.takeEditorKey(slot, key); }
    void noteEditorOpened(int32_t slot) { pluginHost_.noteEditorOpened(slot); }
    bool previewNote(DalnokTrackId track, uint8_t pitch, uint8_t velocity, bool on);
    bool pluginEditorStatesChanged() const { return pluginHost_.editorStatesChanged(); }
    void cancelPendingPlugins();
    bool reloadPlugin(int32_t slot, std::string &err); // an unloaded or failed slot, from its saved state
    void setPluginHost(const std::string &path) { pluginHost_.setHostPath(path); }
    const std::string &pluginHost() const { return pluginHost_.hostPath(); }
    void setRecoveryDirectory(std::string directory) { recoveryDirectory_ = std::move(directory); }
    // Imports another DAW's project (see import/import.hpp) into a prepared project + JSON report.
    static std::unique_ptr<PreparedProject> prepareImport(const std::string &path, double sampleRate, int32_t &missing,
                                                          std::string &reportJson, std::string &err);
    static std::unique_ptr<PreparedProject> prepareDocument(const json::Value &doc, const std::filesystem::path &dir,
                                                            double sampleRate, int32_t &missing, std::string &err);
    // prepareDocument's reader, for a document already migrated to the current format version (project.cpp).
    static std::unique_ptr<PreparedProject> readDocument(const json::Value &doc, const std::filesystem::path &dir,
                                                         double sampleRate, int32_t &missing, std::string &err);
    bool dirty() const { return revision_ != savedRevision_; }
    json::Value describe() const; // model as JSON (used by save and session.describe)

    // Transport
    void play() { transport_.play(); }
    void pause() { transport_.pause(); }
    void seek(int64_t frame) { transport_.seek(frame); }
    bool playing() const { return transport_.playing.load(std::memory_order_relaxed); }
    int64_t position() const { return transport_.position.load(std::memory_order_relaxed); }

    // Offline
    bool renderOffline(int64_t start, int64_t frames, float *left, float *right);
    // maxTail > 0 keeps rendering after `frames` until the output has decayed to silence (or maxTail frames).
    bool renderToWav(const std::string &path, int64_t start, int64_t frames, int32_t bits, std::string &err,
                     int64_t maxTail = 0, int64_t *tailWritten = nullptr);
    bool renderToFile(const std::string &path, int64_t start, int64_t frames, int32_t format, std::string &err,
                      int64_t maxTail = 0, int64_t *tailWritten = nullptr);

    // Bounce in Place (Logic) / Freeze-and-flatten (Ableton): renders `track`'s clips through its plug-ins (pre-fader,
    // with their tail) into a 32-bit float WAV at `path`, puts it on a new audio track right below with the same
    // fader, pan and output, and mutes the original. One undo step. Returns the new track (0 on failure).
    DalnokTrackId bounceInPlace(DalnokTrackId track, const std::string &path, std::string &err);
    // Loudness: live (the master while playing; reset clears it) and of an offline render of [start, start+frames).
    LoudnessReading loudness() const { return loudness_->reading(); }
    void resetLoudness() { loudness_->reset(); }
    bool renderLoudness(int64_t start, int64_t frames, LoudnessReading &out, std::string &err);
    // The offline render loop behind renderToWav and renderLoudness: blocks of [start, start+frames) (plus the
    // tail, see renderToWav) go to `sink` in order; a false return stops it.
    bool renderBlocks(int64_t start, int64_t frames, int64_t maxTail, int64_t *tailWritten, std::string &err,
                      const std::function<bool(const float *, const float *, int64_t)> &sink,
                      const std::function<void(Scratch &, const RenderState &)> &prepare = {},
                      const std::function<void(const Scratch &, int)> &onBlock = {});
    // Export Stems: every track that isn't a bus and isn't muted, post-fader (what reaches its output; sends left
    // out), one file each in `folder` named "NN Name.ext", all the same length (the range plus the mix's tail).
    // Returns the paths written.
    bool exportStems(const std::string &folder, int32_t format, int64_t start, int64_t frames, int64_t maxTail,
                     std::vector<std::string> &paths, std::string &err);

    void stats(DalnokStats &out) const;
    void resetStats();
    int32_t snapshotMismatches() const; // tracks whose reused content differs from a fresh build (tests)

private:
#ifdef DALNOK_TEST_HOOKS
    friend void handoffSaturationFixture(uint64_t *out);
#endif
    using ParameterField = dalnok::ParameterField;
    using ParameterValue = dalnok::ParameterValue;
    bool editParameter(const char *name, DalnokTrackId track, ParameterField field, float value, std::string &err);
    float parameterValue(DalnokTrackId track, ParameterField field) const;
    void applyParameter(const ParameterValue &value);
    void applyUndo(bool undo); // undo (or redo) the top step of its stack
    void cycleFollowsTempo(const TempoMap &from); // keep the cycle on its beats after a tempo map change

    // Runs `fn` against the model; on success records an undo step and publishes.
    template <typename F>
    bool edit(const char *name, bool structural, F &&fn);
    void restore(Model m);
    void syncRuntimes();
    using PluginMap = PluginHostService::PluginMap;
    std::unique_ptr<RenderState> compile(std::vector<StretchJob> *needed = nullptr, const PluginMap *plugins = nullptr) const;
    void instantiatePlugins(); // creates missing instances for every slot in the model
    void bumpRevisionKeepingSaved(); // a UI-visible change that is not an edit (dirty state unchanged)
    StretchKey stretchKey(const ClipState &c) const;
    CompileInputs compileInputs(const PluginMap &plugins) const;
    void renderPendingStretchesNow();
    void commit();
    void resetModel();

    static void audioCallback(void *ctx, float *left, float *right, int frames) DALNOK_NONBLOCKING;
    static void duplexCallback(void *ctx, float *left, float *right, const float *const *inputs, int inputCount,
                               int frames) DALNOK_NONBLOCKING;
    void process(float *left, float *right, int frames) DALNOK_NONBLOCKING;
    uint64_t restEstimateNs_ = 0;                // audio thread: recent non-plug-in work per callback (see process)
    std::atomic<float> lastIsolatedBudget_{0.4f}; // the last callback's isolated budget, as a fraction of its period
    void handleMidiInput(int64_t pos, int frames) DALNOK_NONBLOCKING;
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
    mutable RenderCompiler compiler_; // live content and delay-line caches (control thread)
    std::map<DalnokMediaId, PoolEntry> pool_;
    UndoStack history_; // undo and redo (A-06)
    std::string recoveryDirectory_; // control thread only; never part of the render snapshot
    uint64_t revision_ = 1, savedRevision_ = 1;
    // Per-track change tracking (A-05). Edits and undo stamp only the tracks they changed; any other revision
    // bump (loads, relinks, plug-in loading or editor edits) stamps every track through globalRevision_.
    std::map<DalnokTrackId, uint64_t> trackRevisions_;
    uint64_t globalRevision_ = 1;
    std::vector<DalnokTrackId> changedTracks(const Model &before) const;
    void stampTracks(const std::vector<DalnokTrackId> &ids) { for (auto id : ids) trackRevisions_[id] = revision_; }
    void bumpRevisionAll() { ++revision_; globalRevision_ = revision_; }
    uint64_t firstParameterRevision_ = 0, lastParameterRevision_ = 0;
    void markParameterRevision() {
        if (lastParameterRevision_ != revision_ - 1) firstParameterRevision_ = revision_;
        lastParameterRevision_ = revision_;
    }
    DalnokTrackId nextTrack_ = 1;
    DalnokClipId nextClip_ = 1;
    struct ClipboardEntry { ClipState clip; int32_t row = 0; };
    std::vector<ClipboardEntry> clipboard_;
    DalnokMediaId nextMedia_ = 1;
    int32_t nextColor_ = 0;
    std::unique_ptr<AudioDuplexDevice> duplex_;
    std::string duplexInputUid_, inputUid_, inputError_;
    bool monitorWanted() const;        // some track monitors its input (control thread, from the model)
    void syncInput();                  // opens or closes the monitoring input to match monitorWanted()
    bool openDuplex(const std::string &uid, int highestChannel, std::string &err); // replaces the output device
    void closeDuplex();                // back to the output device
    // Latency probe: the audio thread owns probeFrame_ and writes probeBuf_ until probeDone_ (then the control thread).
    std::vector<float> probeBuf_, probeBurst_; // capture; the burst played at each click (Hann-windowed 2 kHz, 2 ms)
    std::atomic<bool> probeActive_{false}, probeDone_{false}, probeFailed_{false};
    int probeChannel_ = 0, probePeriod_ = 12000, probeFirst_ = 2400;
    int64_t probeFrame_ = 0;
    bool probeOwnsInput_ = false;
    // Stream check: armed by streamStarted(); the audio thread owns checkFrame_ and writes checkRef_/checkIn_ until
    // checkDone_. checkAdd_ is the burst train it adds to the output.
    std::string checkUid_;
    int checkChannel_ = -1;
    std::vector<float> checkAdd_, checkRef_, checkIn_;
    std::atomic<bool> checkActive_{false}, checkDone_{false};
    int64_t checkFrame_ = 0;
    uint64_t streamGeneration_ = 0;
    int64_t streamLatency_ = -1; // this stream's measured round trip (-1: not measured)
    LatencyResult streamCheck_;
    void streamStarted();        // a new duplex stream (real or simulated) is running
    void streamEnded();
    void analyzeStreamCheck();   // control thread, once checkDone_
    const float *const *rtInputs_ = nullptr; // this callback's device inputs (audio thread)
    int rtInputCount_ = 0;
    static constexpr int kMaxCaptureBlock = 8192;
    std::unique_ptr<AudioDevice> device_;
    std::string outputUid_;
    PluginHostService pluginHost_;        // plug-in instances, loading and isolation (A-06)
    std::shared_ptr<StreamPlan> streamPlan_; // streamed clips and the playhead, for the stream cache (A-09)
    void updateStreamPlan(const RenderState &state);
    // Offline renders: pin the streamed blocks [from, from + n) of `state` needs before rendering it.
    static void leaseStreams(StreamCache::Lease &lease, const RenderState &state, int64_t from, int64_t n);
    void updateWorkgroup();               // after the device starts, changes or stops: tell isolated hosts
    int32_t nextPlugin_ = 1;
    int32_t nextMarker_ = 1;
    bool groupClutch_ = false;
    // Recording (control thread)
    int64_t simulatedLatency_ = 0;
    RecordingState rec_; // capture, the take in progress and its audio-thread state (A-06)
    bool simulatedInput_ = false;
    // Recording (shared with the audio thread)
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
    uint32_t rtTake_ = 0;
    float clickY1_ = 0, clickY2_ = 0, clickCoefNow_ = 0, clickEnv_ = 0;
    int clickLeft_ = 0;
    RecordedMidi rtMidiEvents_[256]{};
    int rtMidiCount_ = 0;
    PluginNote rtLiveNotes_[256]{}; // this callback's live notes for a plugin instrument
    int rtLiveNoteCount_ = 0;
    // Auditioning from the piano roll (previewNote): notes for one track's instrument, never recorded. While any sounds,
    // and for 2 s after the last is released (release tails), that track plays live input instead of the armed one.
    struct PreviewNote { DalnokTrackId track; uint8_t pitch, velocity; bool on; };
    SpscQueue<PreviewNote, 256> previewNotes_;
    std::mutex previewProducer_; // control threads (the queue has one producer at a time)
    DalnokTrackId rtPreviewTrack_ = 0;
    int rtPreviewHeld_ = 0;
    int64_t rtPreviewHoldFrames_ = 0;
    std::atomic<float> masterPeakL_{0.0f}, masterPeakR_{0.0f};
    uint32_t humanizeSeed_ = 0x2545F491u; // each Humanize differs, and runs repeat from a fresh engine
    std::unique_ptr<LoudnessMeter> loudness_; // the master while playing (BS.1770; metronome excluded)
    float masterDcL_ = 0, masterDcR_ = 0; // audio thread (meterLevel)

    // Shared atomics.
    Transport transport_; // play state, playhead, cycle, punch, metronome (control and audio threads)
    std::atomic<int32_t> soloCount_{0};
    // Click oscillator coefficients (control thread computes them; see syncRuntimes).
    std::atomic<float> clickCoef_{0}, clickAccentCoef_{0}, clickSin_{0}, clickAccentSin_{0}, clickDecay_{0};
    // Moves a take (the last of `takes`, trimmed to whole bars) into a launcher slot; removes `takes`.
    DalnokClipId takeToSlot(const std::vector<DalnokClipId> &takes, int32_t slot, std::string &err);
    struct LaunchEvent { DalnokTrackId track; int32_t slot; int64_t frame; };
    std::atomic<bool> launcherRecording_{false};
    SpscQueue<LaunchEvent, 4096> launchEvents_;
    std::vector<LaunchEvent> launchLog_; // control thread
    int64_t launcherRecordStart_ = 0;      // this take loops the cycle and becomes one take per pass

    // Diagnostics (written by the audio thread).
    std::atomic<uint64_t> callbacks_{0}, framesRendered_{0}, maxCallbackNs_{0}, lastCallbackNs_{0};
    std::atomic<uint32_t> maxFrames_{0}, overloads_{0}, swaps_{0};
    std::atomic<uint32_t> retiredHighWater_{0};
    std::atomic<uint64_t> pendingSnapshotCallbacks_{0}, adoptionSkips_{0};
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
