// Project model: plain value types (copied wholesale for undo) and the media pool entry. Split from engine.hpp
// (A-06) so the render compiler and other services can use the model without the Engine class.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "dalnok/dalnok.h"
#include "render.hpp"
#include "tempo_map.hpp"
#include "warp.hpp"

#include <cstdint>
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
    std::vector<std::pair<int64_t, float>> automation; // send level in dB by timeline frame (empty: `db` applies)
    bool operator==(const Send &) const = default;
};

// Plug-in state as an immutable, shared blob. Every edit and every undo step copies the model, so the
// state chunk is shared rather than copied; a new state replaces the pointer (audit finding A-07).
struct SharedPluginState {
    std::shared_ptr<const std::string> blob;
    bool empty() const { return !blob || blob->empty(); }
    const std::string &str() const {
        static const std::string kNone;
        return blob ? *blob : kNone;
    }
    void assign(std::string s) { blob = s.empty() ? nullptr : std::make_shared<const std::string>(std::move(s)); }
    void clear() { blob.reset(); }
    bool operator==(const SharedPluginState &) const = default; // same blob (blobs are immutable)
};

// A plugin on a track: the instrument (instrument tracks) or an insert effect. The live instance
// lives in Engine::pluginHost_ (PluginHostService) by id, outside the undoable model, so undo never reloads plugin code.
struct PluginSlot {
    int32_t id = 0;
    std::string format = "vst3", path, classId, name, vendor;
    bool instrument = false;
    std::vector<uint32_t> controls; // parameters on the device panel's controller (empty = the first automatable ones)
    bool bypassed = false;          // footswitch/bypass: effects pass audio through, instruments go silent (undoable)
    bool folded = false;            // shown folded (a narrow strip) in the device chain; no effect on audio (undoable)
    int32_t sidechain = 0;          // DalnokTrackId whose pre-fader signal feeds this plug-in's sidechain input (0 = none)
    SharedPluginState state; // last known plugin state (used when the plugin is missing, and for saving)
    bool operator==(const PluginSlot &) const = default;
};

// Automation: breakpoints in timeline frames. Volume values are dB; pan values are -1 (left) to 1 (right).
struct AutoPoint {
    int64_t frame = 0;
    float value = 0;
    bool operator==(const AutoPoint &) const = default;
};
// Targets: volume, pan, mute (values 0 or 1, stepped), and send k's level in dB (kAutoSend + k).
enum AutoTarget : int32_t { kAutoVolume = 0, kAutoPan = 1, kAutoMute = 2, kAutoSend = 16 };
// A plug-in parameter lane: values are normalized 0-1 (the plug-in's own range is applied at render).
struct PluginAuto {
    int32_t slot = 0;
    uint32_t param = 0;
    std::vector<AutoPoint> points;
    bool operator==(const PluginAuto &) const = default;
};

// Lane heights a track may have (points; the app's default is 88).
constexpr float kMinTrackHeight = 40, kMaxTrackHeight = 400;

struct TrackState {
    DalnokTrackId id = 0;
    std::vector<AutoPoint> volumeAuto, panAuto; // empty = not automated (the fader and knob apply)
    std::vector<AutoPoint> muteAuto;            // 0 or 1, stepped (empty: the mute button applies)
    std::vector<PluginAuto> pluginAuto;         // plug-in parameter lanes
    int32_t kind = kTrackAudio;
    DalnokTrackId output = 0;  // 0 = master; otherwise a bus track
    DalnokTrackId stack = 0;   // member of this summing stack (a bus track), 0 = none
    bool isStack = false;      // a bus track that is a summing stack (its members follow it in display order)
    bool collapsed = false;    // stack shown closed (members hidden in the arrangement)
    float height = 0;          // lane height in points (view only; 0 = the arrangement's default)
    bool hidden = false;       // hidden from the arrangement and mixer (still plays)
    std::vector<Send> sends;   // to bus tracks
    bool armed = false;       // record-enabled
    int32_t inputChannel = 0; // zero-based input of the recording device (audio tracks)
    bool inputStereo = false; // records and monitors inputChannel (left) and inputChannel + 1 (right) as one stereo take
    bool inputMonitor = false; // Input Monitoring: hear the input through this track's strip (audio tracks)
    bool phaseInvert = false;  // polarity flipped at the head of the strip, before the inserts (API 46)
    int32_t group = 0;         // TrackGroup id (0 = none)
    std::vector<PluginSlot> plugins; // instrument first (if any), then inserts in processing order
    std::string name;
    int32_t color = 0;        // gradient step (see "06 - Design/Track Colors")
    int32_t customColor = -1; // 0xRRGGBB pinned by the user, or -1 = automatic
    float gainDb = 0;
    float pan = 0;
    bool muted = false;
    bool solo = false;
    std::shared_ptr<TrackRuntime> runtime; // shared across model copies
    bool operator==(const TrackState &) const = default; // used to find which tracks an edit changed (A-05)
};

// MIDI note in frames, relative to the start of its clip's source (like an audio offset).
struct MidiNote {
    int64_t start = 0, length = 0;
    uint8_t pitch = 60, velocity = 100;
};
using NoteList = std::shared_ptr<const std::vector<MidiNote>>; // immutable; shared across undo copies
// A MIDI controller event in a clip, in frames from the start of the clip's source (like a note). controller 0-127 is
// a control change (value 0-127); kPitchBendController is pitch bend (value 0-16383, 8192 = centre).
constexpr uint8_t kPitchBendController = 128;
struct MidiCC {
    int64_t start = 0;
    uint8_t controller = 1;
    uint16_t value = 0;
};
using CCList = std::shared_ptr<const std::vector<MidiCC>>; // sorted by start; immutable, shared like notes

struct ClipState {
    DalnokClipId id = 0;
    int32_t folder = 0; // take folder this clip belongs to (0 = none)
    int32_t slot = -1;  // clip launcher slot (>= 0): not on the timeline; loops when launched
    int32_t follow = 0, followLoops = 1; // launcher follow action: 0 none, 1 next slot, 2 stop; after N loops
    bool muted = false; // clip is retained but does not contribute audio or MIDI
    bool alt = false;   // a take inside a folder: kept, not played (the comp's pieces play)
    NoteList notes; // non-null: MIDI clip (media = 0)
    CCList controllers; // MIDI clips: controller events (null = none)
    bool midi() const { return notes != nullptr; }
    DalnokTrackId track = 0;
    DalnokMediaId media = 0;
    int64_t start = 0, offset = 0, length = 0;
    // Loop (Logic's region Loop, Ableton's clip loop): when loopLength > 0 the clip repeats the source window
    // [offset, offset + loopLength) for its whole length, starting loopPhase frames into that window (a split's
    // right part, a trimmed left edge). Not for time-stretched or warped audio.
    int64_t loopLength = 0, loopPhase = 0;
    bool looped() const { return loopLength > 0; }
    int64_t fadeIn = 0, fadeOut = 0; // frames
    int32_t fadeCurve = 0;           // FadeCurve
    float gainDb = 0;                // clip (region/item) gain
    double rate = 1.0;               // source frames per timeline frame (≠1: time-stretched)
    float pitch = 0;                 // transposition in semitones (preservePitch only)
    bool preservePitch = true;       // false: varispeed (pitch follows rate)
    // Audio follows tempo (Ableton's warp): tempo changes keep the clip on its beats and time-stretch it (pitch kept).
    bool followsTempo = false;
    WarpMap warp;                    // audio quantize: segments at their own speeds (null: one speed, `rate`)
    bool warped() const { return warp && !warp->empty(); }
    bool stretched() const { return std::fabs(rate - 1.0) > 1e-9 || pitch != 0 || warped(); }
    int64_t sourceLength() const { return static_cast<int64_t>(std::llround(static_cast<double>(length) * rate)); }
    std::string name;
    bool operator==(const ClipState &) const = default; // note lists compare by identity (they are immutable)
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

// A named position on the timeline (navigation and arrangement landmarks).
struct Marker {
    int32_t id = 0;
    int64_t frame = 0;
    std::string name;
};

// Track group (Logic's Groups): members share the linked settings. Volume and pan move relatively, toggles copy.
struct TrackGroup {
    int32_t id = 0;
    std::string name;
    bool volume = true, pan = false, mute = true, solo = true, arm = true, monitor = true;
    bool operator==(const TrackGroup &) const = default;
};

struct Model {
    std::vector<TrackState> tracks; // display order
    std::vector<TrackGroup> groups;
    std::vector<Marker> markers;    // sorted by frame
    std::vector<TakeFolder> folders;
    float masterGainDb = 0; // the master fader
    int32_t scenes = 8;     // launcher slots per track
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

} // namespace dalnok
