/*
 * Dalnok engine — stable C API.
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This header is the only boundary between the engine and any front end
 * (Swift on macOS today; other UIs and scripting later). Keep it plain C.
 *
 * Threading contract:
 *   - All functions are "control thread" functions (call from one thread at a
 *     time, normally the UI/main thread) unless marked [any thread].
 *   - The real-time audio thread is owned by the engine and never calls back
 *     into front-end code.
 *
 * Model contract:
 *   - The engine owns the project model (tracks, clips, media pool). Every
 *     mutation is an undoable command and bumps dalnok_model_revision().
 *   - Front ends re-query the model when the revision changes; they never
 *     keep their own copy.
 */
#ifndef DALNOK_H
#define DALNOK_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DALNOK_API_VERSION 15

typedef enum {
    DALNOK_OK = 0,
    DALNOK_ERR_INVALID_ARG = 1,
    DALNOK_ERR_IO = 2,
    DALNOK_ERR_DEVICE = 3,
    DALNOK_ERR_NOT_FOUND = 4,
    DALNOK_ERR_UNSUPPORTED = 5,
    DALNOK_ERR_FORMAT = 6,
} DalnokStatus;

typedef struct DalnokEngine DalnokEngine;
typedef struct DalnokMedia DalnokMedia;
typedef int32_t DalnokTrackId;
typedef int32_t DalnokClipId;
typedef int32_t DalnokMediaId;

/* ---- Engine lifecycle ------------------------------------------------ */

/* Creates an engine running at `sample_rate`. Pass 0 to adopt the default
 * output device's rate. */
DalnokEngine *dalnok_engine_create(double sample_rate);
void dalnok_engine_destroy(DalnokEngine *engine);

/* Opens the system default output device and starts the audio callback. */
DalnokStatus dalnok_engine_start_device(DalnokEngine *engine, char *err, size_t err_len);
void dalnok_engine_stop_device(DalnokEngine *engine);
bool dalnok_engine_device_running(const DalnokEngine *engine);
double dalnok_engine_sample_rate(const DalnokEngine *engine);

/* ---- Output devices -------------------------------------------------- */

typedef struct {
    char uid[256];          /* stable identifier; pass to dalnok_engine_set_output_device */
    char name[256];
    double sample_rate;     /* the device's current hardware rate */
    int32_t output_channels;
    bool is_default;        /* current system default output */
} DalnokDeviceInfo;

/* Fills up to `capacity` entries; returns the total number of output devices. [any thread] */
int32_t dalnok_output_devices(DalnokDeviceInfo *out, int32_t capacity);
/* Switches output. NULL or "" follows the system default. On failure the
 * previous device keeps playing. Engine rate != hardware rate is converted. */
DalnokStatus dalnok_engine_set_output_device(DalnokEngine *engine, const char *uid, char *err, size_t err_len);
/* Current selection ("" = system default); returns full length. */
size_t dalnok_engine_output_device(const DalnokEngine *engine, char *buf, size_t len);
/* False once the selected device disappeared (e.g. unplugged); poll from the UI. */
bool dalnok_engine_device_alive(const DalnokEngine *engine);
double dalnok_engine_hardware_sample_rate(const DalnokEngine *engine);

/* Input device discovery does not open a device or request microphone access. */
typedef struct {
    char uid[256];
    char name[256];
    double sample_rate;
    int32_t input_channels;
    bool is_default;
} DalnokInputDeviceInfo;
/* Fills up to capacity entries; returns the total number of input devices. [any thread] */
int32_t dalnok_input_devices(DalnokInputDeviceInfo *out, int32_t capacity);

/* MIDI source discovery only; does not open ports or receive events. */
typedef struct {
    int32_t unique_id;       /* Core MIDI unique ID, stable when the OS preserves it */
    char name[256];
} DalnokMidiSourceInfo;
int32_t dalnok_midi_sources(DalnokMidiSourceInfo *out, int32_t capacity); /* [any thread] */

/* Experimental same-device mono capture to a new spool. Output must already
 * be explicitly set to device_uid, input_channel is zero-based, and engine/device rates must match. This
 * does not create a clip, monitor input, or provide latency compensation.
 * On error the spool is retained for recovery. Control thread only. */
typedef struct {
    uint64_t captured_frames, written_frames, dropped_frames;
    bool input_error, overflow, write_error, finalize_error;
} DalnokCaptureStats;
DalnokStatus dalnok_capture_start(DalnokEngine *engine, const char *device_uid, int32_t input_channel,
                                  const char *new_spool_path, char *err, size_t err_len);
DalnokStatus dalnok_capture_stop(DalnokEngine *engine, DalnokCaptureStats *stats, char *err, size_t err_len);
bool dalnok_capture_active(const DalnokEngine *engine);
/* Read status while recording; error flags require the caller to stop capture. */
DalnokStatus dalnok_capture_status(const DalnokEngine *engine, DalnokCaptureStats *stats);

/* ---- Recording -------------------------------------------------------
 * Records the armed audio track (at most one; from its input channel on
 * `input_device_uid`, which must equal the explicitly selected output device,
 * or DALNOK_SIMULATED_INPUT) and/or the armed instrument track (MIDI).
 * Starts the transport; the take begins at the first block in which the
 * transport rolls. Pausing or seeking during the take ends it with an error.
 * Audio goes to "<directory>/<Track> Take N.wav" (32-bit float) with a
 * journal; see dalnok_record_scan / dalnok_record_recover. On success the take
 * is placed as one undo step ("Record"), shifted earlier by
 * dalnok_record_latency. A failed take is never placed: its valid prefix is
 * saved as "<name> (recovered).wav" and the spool and journal are kept.
 * Control thread only. */
#define DALNOK_SIMULATED_INPUT "dalnok:simulated-input"
typedef struct {
    DalnokClipId audio_clip, midi_clip; /* 0 if none placed */
    DalnokMediaId media;
    uint64_t frames;          /* audio frames in the finished (or recovered) file */
    int64_t start_frame;      /* where the take began, before latency compensation (-1: never rolled) */
    int64_t latency_frames;   /* subtracted when placing audio */
    int32_t notes;
    bool recovered;           /* failed take; `path` holds the recovered prefix */
    char path[1024];
    DalnokCaptureStats capture;
    /* Every armed audio track records its own input; one take (clip) each, all one undo step. */
    int32_t audio_clip_count;
    DalnokClipId audio_clips[64];
} DalnokRecordResult;
DalnokStatus dalnok_record_start(DalnokEngine *engine, const char *input_device_uid, const char *directory,
                                 char *err, size_t err_len);
/* Stops, finalizes, verifies and places the take. Returns DALNOK_OK only if
 * everything succeeded; otherwise `err` explains what failed and what was kept. */
DalnokStatus dalnok_record_stop(DalnokEngine *engine, DalnokRecordResult *result, char *err, size_t err_len);
bool dalnok_record_active(const DalnokEngine *engine);
/* True once the take can no longer succeed (transport paused or jumped); stop it. */
bool dalnok_record_broken(const DalnokEngine *engine);
/* Timeline frame where the current take began, or -1 before the transport rolls. */
int64_t dalnok_record_start_frame(const DalnokEngine *engine);
/* Punch: takes record only timeline frames [in, out) while the transport rolls before and after
 * (count-in pre-roll and post-roll). Sample-accurate for audio, block-accurate for MIDI. Not saved.
 * Call before dalnok_record_start; changing it during a take moves the window for the rest of the take. */
DalnokStatus dalnok_record_set_punch(DalnokEngine *engine, bool enabled, int64_t in, int64_t out);
void dalnok_record_punch(const DalnokEngine *engine, bool *enabled, int64_t *in, int64_t *out);
/* Device-reported round trip (input + output) plus the manual offset. Not loopback-measured. */
int64_t dalnok_record_latency(const DalnokEngine *engine);
void dalnok_record_set_latency_offset(DalnokEngine *engine, int64_t frames);
/* Software input monitoring while recording audio (off by default; risk of feedback). */
void dalnok_record_set_monitoring(DalnokEngine *engine, bool on);
/* Simulated device only: the round trip it reports. Tests and simulation. */
void dalnok_record_set_simulated_latency(DalnokEngine *engine, int64_t frames);
/* One duplex cycle on DALNOK_SIMULATED_INPUT: `input` is mono, `frames` long, and appears on every
 * device input channel. */
DalnokStatus dalnok_engine_pump_input(DalnokEngine *engine, const float *input, float *left, float *right,
                                      int32_t frames);
/* As above with one buffer per device input channel (`count` <= 64). */
DalnokStatus dalnok_engine_pump_input_channels(DalnokEngine *engine, const float *const *inputs, int32_t count,
                                               float *left, float *right, int32_t frames);
/* Lists take journals in a folder as JSON [{"journal","state","wav",...}]; returns full length. [any thread] */
size_t dalnok_record_scan(const char *directory, char *json, size_t len);
/* Saves an unfinished take's valid prefix as "<name> (recovered).wav" (spool unchanged).
 * Fills JSON with the journal plus "path". [any thread] */
DalnokStatus dalnok_record_recover(const char *journal, char *json, size_t len, char *err, size_t err_len);

/* ---- MIDI input -------------------------------------------------------
 * Note messages from open inputs play the armed instrument track live (also
 * while stopped) and are recorded while recording. Timing is quantized to the
 * audio callback (at most one buffer late). */
DalnokStatus dalnok_midi_open_input(DalnokEngine *engine, int32_t unique_id, char *err, size_t err_len);
/* Feeds one channel message as if it came from a device. [control thread] */
DalnokStatus dalnok_midi_inject(DalnokEngine *engine, uint8_t status, uint8_t data1, uint8_t data2);
uint64_t dalnok_midi_dropped(const DalnokEngine *engine);

/* Runs the live render path (transport fades, smoothing, meters) for `frames`
 * without a device. Fails if a device is running. For tests and simulation. */
DalnokStatus dalnok_engine_pump(DalnokEngine *engine, float *left, float *right, int32_t frames);

/* ---- Meters ---------------------------------------------------------- */

/* Linear post-fader peak since the previous read, per channel; reading resets.
 * Only the live path (device or pump) feeds meters. */
DalnokStatus dalnok_meter_track(DalnokEngine *engine, DalnokTrackId track, float *left, float *right);
void dalnok_meter_master(DalnokEngine *engine, float *left, float *right);

/* Frees snapshots retired by the audio thread. Call periodically (e.g. from a
 * UI timer). Cheap when there is nothing to do. */
void dalnok_engine_collect_garbage(DalnokEngine *engine);

/* Convert a stopped mono/stereo capture spool to a new 32-bit float WAV.
 * The spool is unchanged; output must not already exist. Incomplete trailing
 * frame bytes are reported and omitted. [any thread] */
DalnokStatus dalnok_capture_recover_wav(const char *spool, const char *output,
                                        uint64_t *frames_out, uint32_t *trailing_bytes_out,
                                        char *err, size_t err_len);

/* ---- Media (decoded audio, independent of any engine) ---------------- */

/* Decodes an audio file into memory, converting to `sample_rate`.
 * [any thread] — safe to call from a background thread. */
DalnokStatus dalnok_media_load(const char *path, double sample_rate,
                               DalnokMedia **out, char *err, size_t err_len);
/* Wraps caller-provided planar float samples (copied). 1 or 2 channels. [any thread] */
DalnokMedia *dalnok_media_from_samples(const float *const *channels, int32_t channel_count,
                                       int64_t frames, double sample_rate);
void dalnok_media_release(DalnokMedia *media);   /* [any thread] */
int64_t dalnok_media_frames(const DalnokMedia *media);
int32_t dalnok_media_channels(const DalnokMedia *media);
double dalnok_media_sample_rate(const DalnokMedia *media);

/* Fills `count` columns of min/max peaks for `channel`, starting at
 * `start_frame`, each column covering `frames_per_column` frames.
 * Columns outside the media are 0. Returns columns written. [any thread] */
int64_t dalnok_media_peaks(const DalnokMedia *media, int32_t channel, int64_t start_frame,
                           double frames_per_column, float *min_out, float *max_out,
                           int64_t count);

/* ---- Media pool (per project) ---------------------------------------- */

/* Adds decoded media to the project's pool; the engine takes its own
 * reference (the caller still releases `media`). `source_path` is recorded
 * for saving (may be NULL for generated audio). Adding the same path twice
 * returns the existing id. Not undoable; entries live until project new/load. */
DalnokMediaId dalnok_pool_add(DalnokEngine *engine, DalnokMedia *media, const char *source_path);
/* Borrowed pointer, valid until dalnok_project_new/load. NULL if the media is
 * offline (file missing when the project was loaded). */
const DalnokMedia *dalnok_pool_media(const DalnokEngine *engine, DalnokMediaId id);
/* Copies the source path into `buf`; returns the full length. */
size_t dalnok_pool_path(const DalnokEngine *engine, DalnokMediaId id, char *buf, size_t len);
/* Points a pool entry (typically an offline one) at new media; clips using it
 * come back online. The engine takes its own reference. Not undoable. */
DalnokStatus dalnok_pool_relink(DalnokEngine *engine, DalnokMediaId id, DalnokMedia *media, const char *path,
                                char *err, size_t err_len);

/* ---- Model queries --------------------------------------------------- */

uint64_t dalnok_model_revision(const DalnokEngine *engine);
int32_t dalnok_track_count(const DalnokEngine *engine);
DalnokTrackId dalnok_track_at(const DalnokEngine *engine, int32_t index);

typedef struct {
    DalnokTrackId id;
    char name[128];
    int32_t color;       /* gradient step (automatic color) */
    int32_t custom_color;/* 0xRRGGBB pinned by the user, or -1 = automatic */
    float gain_db;       /* -INFINITY for silence */
    float pan;
    bool muted;
    bool solo;
    int32_t clip_count;
    int32_t kind;          /* DalnokTrackKind */
    bool armed;            /* record-enabled */
    int32_t input_channel; /* zero-based audio input (audio tracks) */
} DalnokTrackInfo;
typedef enum { DALNOK_TRACK_AUDIO = 0, DALNOK_TRACK_INSTRUMENT = 1, DALNOK_TRACK_BUS = 2 } DalnokTrackKind;

/* ---- Routing: buses, outputs and sends --------------------------------
 * A bus track holds no clips; it mixes what is routed (output) or sent to it, then runs its inserts,
 * fader and pan into its own output. Edits that would feed a bus back into itself fail. Solo follows
 * routing: soloing a bus keeps its sources audible; soloing a source keeps its buses audible. */
DalnokTrackId dalnok_track_add_bus(DalnokEngine *engine, const char *name);
DalnokStatus dalnok_track_set_output(DalnokEngine *engine, DalnokTrackId track, DalnokTrackId bus); /* 0 = master */
DalnokTrackId dalnok_track_output(const DalnokEngine *engine, DalnokTrackId track);
typedef struct { DalnokTrackId bus; float db; bool pre; } DalnokSend; /* pre: before the fader and pan */
DalnokStatus dalnok_track_set_send(DalnokEngine *engine, DalnokTrackId track, DalnokTrackId bus, float db, bool pre);
DalnokStatus dalnok_track_remove_send(DalnokEngine *engine, DalnokTrackId track, DalnokTrackId bus);
int32_t dalnok_track_sends(const DalnokEngine *engine, DalnokTrackId track, DalnokSend *out, int32_t capacity);

/* ---- Automation -------------------------------------------------------
 * Breakpoints in timeline frames, linear between points and held before the first and after the last.
 * Volume values are dB (<= +6; <= -95 is silence) and follow the fader's taper between points; pan is -1..1.
 * While a lane has points it overrides the fader or knob; mute and solo still apply. */
typedef enum { DALNOK_AUTO_VOLUME = 0, DALNOK_AUTO_PAN = 1 } DalnokAutoTarget;
typedef struct { int64_t frame; float value; } DalnokAutoPoint;
/* Replaces the lane (one undo step); count 0 removes it. */
DalnokStatus dalnok_track_set_automation(DalnokEngine *engine, DalnokTrackId track, int32_t target,
                                         const DalnokAutoPoint *points, int32_t count);
int32_t dalnok_track_automation(const DalnokEngine *engine, DalnokTrackId track, int32_t target,
                                DalnokAutoPoint *out, int32_t capacity); /* total count */
DalnokStatus dalnok_track_info(const DalnokEngine *engine, DalnokTrackId track, DalnokTrackInfo *out);

/* Clips of a track in z-order (later = on top; overlapping clips: top wins). */
DalnokClipId dalnok_track_clip_at(const DalnokEngine *engine, DalnokTrackId track, int32_t index);

typedef struct {
    DalnokClipId id;
    DalnokTrackId track;
    DalnokMediaId media;
    int64_t start;        /* timeline frame */
    int64_t offset;       /* frame within media */
    int64_t length;       /* frames */
    int64_t media_frames; /* total frames of the source media */
    bool offline;         /* source missing: renders silence */
    int64_t fade_in;      /* frames */
    int64_t fade_out;     /* frames */
    int32_t fade_curve;   /* DalnokFadeCurve */
    float gain_db;        /* clip gain; -INFINITY = silent */
    double rate;          /* source frames per timeline frame (1 = normal speed) */
    float pitch;          /* semitones (time-stretch mode only) */
    bool preserve_pitch;  /* false = varispeed */
    bool processing;      /* stretched audio still rendering in the background (silent until ready) */
    char name[128];
    bool midi;            /* MIDI clip (media = 0; see dalnok_midi_clip_notes) */
    int32_t note_count;
} DalnokClipInfo;
DalnokStatus dalnok_clip_info(const DalnokEngine *engine, DalnokClipId clip, DalnokClipInfo *out);

/* Timeline length in frames (end of the last clip). */
int64_t dalnok_session_length(const DalnokEngine *engine);

/* ---- Edit commands (each is one undo step unless grouped) ------------ */

DalnokTrackId dalnok_track_add(DalnokEngine *engine, const char *name);
DalnokStatus dalnok_track_remove(DalnokEngine *engine, DalnokTrackId track);
DalnokStatus dalnok_track_rename(DalnokEngine *engine, DalnokTrackId track, const char *name);
/* Gain in dB, clamped to +12; <= -96 means silence. Smoothed on the audio thread. */
DalnokStatus dalnok_track_set_gain_db(DalnokEngine *engine, DalnokTrackId track, float gain_db);
/* Pan in [-1, 1]. Mono sources: -3 dB-compensated constant power (unity at
 * center). Stereo sources: balance. */
DalnokStatus dalnok_track_set_pan(DalnokEngine *engine, DalnokTrackId track, float pan);
DalnokStatus dalnok_track_set_mute(DalnokEngine *engine, DalnokTrackId track, bool muted);
/* While any track is soloed, only soloed tracks are heard. */
DalnokStatus dalnok_track_set_solo(DalnokEngine *engine, DalnokTrackId track, bool solo);
/* Pins a track color (0xRRGGBB) or returns it to automatic (-1). */
DalnokStatus dalnok_track_set_color(DalnokEngine *engine, DalnokTrackId track, int32_t custom_rgb);
/* Re-applies the gradient to all tracks in display order (one undo step). */
DalnokStatus dalnok_tracks_recolor_gradient(DalnokEngine *engine);
/* Moves a track to `index` in display order. */
DalnokStatus dalnok_track_move(DalnokEngine *engine, DalnokTrackId track, int32_t index);

/* Places pool media on a track. length <= 0 means "to the end of the media".
 * Returns 0 on failure. */
DalnokClipId dalnok_clip_add(DalnokEngine *engine, DalnokTrackId track, DalnokMediaId media,
                             int64_t timeline_start, int64_t source_offset, int64_t length);
DalnokStatus dalnok_clip_remove(DalnokEngine *engine, DalnokClipId clip);
/* Delete selected clips atomically as one undo step. */
DalnokStatus dalnok_clips_remove(DalnokEngine *engine, const DalnokClipId *clips, int32_t count);
/* Moves a clip (optionally to another track) and brings it to the top. */
DalnokStatus dalnok_clip_move(DalnokEngine *engine, DalnokClipId clip, DalnokTrackId track,
                              int64_t timeline_start);
/* Nudge selected clips together in frames, clamped at timeline zero; one undo step. */
DalnokStatus dalnok_clips_nudge(DalnokEngine *engine, const DalnokClipId *clips, int32_t count, int64_t delta);
/* Sets the clip's timeline start and source region (trim). */
DalnokStatus dalnok_clip_set_region(DalnokEngine *engine, DalnokClipId clip, int64_t timeline_start,
                                    int64_t source_offset, int64_t length);
/* Splits at a timeline frame strictly inside the clip; the right part gets a new id. */
DalnokStatus dalnok_clip_split(DalnokEngine *engine, DalnokClipId clip, int64_t at_frame,
                               DalnokClipId *right_out);

typedef enum { DALNOK_FADE_LINEAR = 0, DALNOK_FADE_EQUAL_POWER = 1 } DalnokFadeCurve;
/* Fade lengths in frames (scaled down if they exceed the clip). A clip that
 * fades over a lower clip on the same track crossfades with it. */
DalnokStatus dalnok_clip_set_fades(DalnokEngine *engine, DalnokClipId clip, int64_t fade_in, int64_t fade_out,
                                   DalnokFadeCurve curve);

/* Time-stretch: sets the clip's timeline length and speed (it plays source
 * frames [offset, offset + length × rate)); `semitones` transposes (only when
 * preserve_pitch). preserve_pitch = false is varispeed. Rendered in the
 * background; see dalnok_engine_poll_jobs. */
DalnokStatus dalnok_clip_set_stretch(DalnokEngine *engine, DalnokClipId clip, int64_t length, double rate,
                                     float semitones, bool preserve_pitch);
/* Installs finished background renders (call from a UI timer). Returns the number still pending. */
int32_t dalnok_engine_poll_jobs(DalnokEngine *engine);

/* Clip (region) gain in dB, applied before the track fader. Clamped to +24. */
DalnokStatus dalnok_clip_set_gain_db(DalnokEngine *engine, DalnokClipId clip, float gain_db);

/* ---- Plugins (discovery only; hosting is later Phase 4 work) ---------
 * Lists VST3 and CLAP bundles in the standard folders (plus `extra_folder`,
 * may be NULL) and registered Audio Units, as JSON
 * [{"format","name","vendor","version","kind","path","categories"}].
 * kind is "instrument", "effect", "midi", or "unknown" when only a sandboxed
 * scan could tell. No plugin code is loaded. Returns full length. [any thread] */
size_t dalnok_plugins_scan(const char *extra_folder, bool include_audio_units, char *json, size_t len);
/* Stage 2: validates plugins in separate processes. Runs `scanner_path`
 * (dalnok-scan) once per plugin with `timeout_ms`, four at a time, so a crash
 * or hang only ends that process. Results are cached in `cache_path` (NULL: no
 * cache) until the bundle or AU version changes; `rescan` ignores the cache.
 * `only_extra_folder` limits bundles to `extra_folder`; `name_filter` (NULL =
 * all) keeps names containing it, case-insensitively. Each plugin gets
 * "scan": {"status": "ok"|"failed"|"crashed"|"timeout", "cached", "error"?} and
 * its kind/vendor/version from what it declared. Loads plugin code (in the
 * child processes only). Returns full length. [any thread; blocks] */
size_t dalnok_plugins_validate(const char *scanner_path, const char *cache_path, const char *extra_folder,
                               bool only_extra_folder, bool include_audio_units, const char *name_filter,
                               int32_t timeout_ms, bool rescan, char *json, size_t len);

/* ---- Hosted plugins (VST3; ADR-0009 stage 3) ---------------------------
 * Loads plugin code into this process (control thread). An instrument plugin
 * becomes the instrument of an instrument track (replacing the previous one);
 * an effect is appended to the track's insert chain. Adding and removing are
 * undo steps; the instance stays loaded for undo. Offline renders and exports
 * use separate instances with the same state. A plugin missing when a project
 * opens keeps its saved state and is bypassed (effects) or silent (instruments). */
typedef struct {
    int32_t id;
    char name[128];
    char vendor[128];
    char path[1024];
    bool instrument;
    bool loaded;
    uint32_t latency;  /* frames, as reported (not compensated yet) */
    char error[256];   /* why it is not loaded */
} DalnokPluginSlotInfo;
int32_t dalnok_plugin_add(DalnokEngine *engine, DalnokTrackId track, const char *bundle_path, const char *class_id,
                          char *err, size_t err_len); /* returns the slot id, 0 on failure */
DalnokStatus dalnok_plugin_remove(DalnokEngine *engine, DalnokTrackId track, int32_t slot);
int32_t dalnok_track_plugin_count(const DalnokEngine *engine, DalnokTrackId track);
DalnokStatus dalnok_track_plugin_info(const DalnokEngine *engine, DalnokTrackId track, int32_t index, DalnokPluginSlotInfo *out);
/* Plugin state as base64 (presets, tests); returns full length. */
size_t dalnok_plugin_get_state(const DalnokEngine *engine, int32_t slot, char *base64, size_t len);
DalnokStatus dalnok_plugin_set_state(DalnokEngine *engine, int32_t slot, const char *base64);

/* Parameters (main thread). Values are normalized 0…1; changes reach the audio
 * thread at the start of the next block. Editor edits also count as project changes. */
typedef struct {
    uint32_t id;
    char title[128];
    char units[32];
    char display[64];    /* the plugin's own text for the current value */
    double value, default_value;
    int32_t step_count;  /* 0 = continuous, 1 = toggle, n = n+1 positions */
    bool automatable, read_only, hidden;
} DalnokPluginParameter;
int32_t dalnok_plugin_parameter_count(const DalnokEngine *engine, int32_t slot);
DalnokStatus dalnok_plugin_parameter(const DalnokEngine *engine, int32_t slot, int32_t index, DalnokPluginParameter *out);
DalnokStatus dalnok_plugin_set_parameter(DalnokEngine *engine, int32_t slot, uint32_t id, double normalized);
/* The device panel's controller: which parameters it shows (saved; one undo step to change).
 * Returns the count (0 = not customized: the panel shows the first automatable parameters). */
int32_t dalnok_plugin_controls(const DalnokEngine *engine, DalnokTrackId track, int32_t slot, uint32_t *ids, int32_t capacity);
DalnokStatus dalnok_plugin_set_controls(DalnokEngine *engine, DalnokTrackId track, int32_t slot, const uint32_t *ids, int32_t count);

/* The plugin's own editor, attached to `parent_view` (an NSView). `on_resize`
 * is called when the editor asks for a new size. Main thread. */
bool dalnok_plugin_has_editor(const DalnokEngine *engine, int32_t slot);
DalnokStatus dalnok_plugin_open_editor(DalnokEngine *engine, int32_t slot, void *parent_view, int32_t *width,
                                       int32_t *height, void (*on_resize)(void *ctx, int32_t width, int32_t height),
                                       void *ctx, char *err, size_t err_len);
void dalnok_plugin_close_editor(DalnokEngine *engine, int32_t slot);

/* ---- Instruments, MIDI clips, tempo --------------------------------- */

/* Adds a track that plays MIDI clips through the built-in Dalnok Poly synth.
 * It becomes the armed instrument track (plays live MIDI input). */
DalnokTrackId dalnok_track_add_instrument(DalnokEngine *engine, const char *name);
/* Record-enable. Arming a track disarms other tracks of the same kind. */
DalnokStatus dalnok_track_set_armed(DalnokEngine *engine, DalnokTrackId track, bool armed);
DalnokStatus dalnok_track_set_input(DalnokEngine *engine, DalnokTrackId track, int32_t input_channel);

/* A note in frames relative to the clip's source origin (timeline = clip start + start - clip offset). */
typedef struct {
    int64_t start, length;
    uint8_t pitch, velocity; /* 0-127, 1-127 */
} DalnokNote;
DalnokClipId dalnok_midi_clip_add(DalnokEngine *engine, DalnokTrackId track, int64_t start, int64_t length);
/* Replaces all notes (one undo step). */
DalnokStatus dalnok_midi_clip_set_notes(DalnokEngine *engine, DalnokClipId clip, const DalnokNote *notes, int32_t count);
/* Copies up to `capacity` notes sorted by start; returns the total count (-1 if not a MIDI clip). */
int32_t dalnok_midi_clip_notes(const DalnokEngine *engine, DalnokClipId clip, DalnokNote *out, int32_t capacity);
/* Moves note starts toward a grid of `grid_beats` anchored at frame 0 (strength 0-1). */
DalnokStatus dalnok_midi_quantize(DalnokEngine *engine, DalnokClipId clip, double grid_beats, double strength);
/* Tempo and meter maps. Beats are quarter notes from the timeline origin; bars are zero-based
 * (bar 1 on screen = 0). Tempo is constant between points; meter changes start on a bar.
 * Any tempo change keeps MIDI clips and notes on their beats; audio clips keep their time.
 * dalnok_tempo_set changes the first tempo and meter and keeps later changes at their beats/bars. */
typedef struct { double beat, bpm; } DalnokTempoPoint;
typedef struct { int32_t bar, numerator, denominator; } DalnokMeterPoint;
DalnokStatus dalnok_tempo_set(DalnokEngine *engine, double bpm, int32_t numerator, int32_t denominator);
double dalnok_tempo_bpm(const DalnokEngine *engine);     /* first tempo */
void dalnok_meter(const DalnokEngine *engine, int32_t *numerator, int32_t *denominator); /* first meter */
/* Replaces both maps (one undo step). The first tempo point is at beat 0 and the first meter at bar 0. */
DalnokStatus dalnok_tempo_map_set(DalnokEngine *engine, const DalnokTempoPoint *tempo, int32_t tempo_count,
                                  const DalnokMeterPoint *meter, int32_t meter_count);
int32_t dalnok_tempo_points(const DalnokEngine *engine, DalnokTempoPoint *out, int32_t capacity); /* total count */
int32_t dalnok_meter_points(const DalnokEngine *engine, DalnokMeterPoint *out, int32_t capacity);
double dalnok_tempo_at(const DalnokEngine *engine, double beat);
/* Unrounded conversions for display; they extrapolate before 0 with the first tempo or meter. */
double dalnok_beat_to_frame(const DalnokEngine *engine, double beat);
double dalnok_frame_to_beat(const DalnokEngine *engine, double frame);
double dalnok_bar_to_beat(const DalnokEngine *engine, int32_t bar);
/* Bar (zero-based) containing `beat`, the position inside it in meter beats (zero-based), and its meter. */
void dalnok_beat_to_bar(const DalnokEngine *engine, double beat, int32_t *bar, double *beat_in_bar,
                        int32_t *numerator, int32_t *denominator);

/* ---- Undo ------------------------------------------------------------ */

bool dalnok_undo(DalnokEngine *engine);
bool dalnok_redo(DalnokEngine *engine);
bool dalnok_can_undo(const DalnokEngine *engine);
bool dalnok_can_redo(const DalnokEngine *engine);
/* Name of the step undo/redo would apply (e.g. "Move Clip"); returns full length. */
size_t dalnok_undo_name(const DalnokEngine *engine, char *buf, size_t len);
size_t dalnok_redo_name(const DalnokEngine *engine, char *buf, size_t len);
/* Everything between begin and end becomes one undo step named `name`
 * (e.g. a mouse drag). Groups nest; only the outermost name is used. */
void dalnok_undo_begin_group(DalnokEngine *engine, const char *name);
void dalnok_undo_end_group(DalnokEngine *engine);

/* ---- Project --------------------------------------------------------- */

/* Clears the model, pool and undo history. */
void dalnok_project_new(DalnokEngine *engine);
/* Writes a versioned JSON project atomically (temp file + rename). Media is
 * referenced by path (absolute and relative to the project file). */
DalnokStatus dalnok_project_save(DalnokEngine *engine, const char *path, char *err, size_t err_len);
/* Write a recovery snapshot without marking the current project saved or copying media.
 * Use a separate recovery path, never the primary project file. [control thread] */
DalnokStatus dalnok_project_save_snapshot(DalnokEngine *engine, const char *path, char *err, size_t err_len);
/* As dalnok_project_save; with copy_media, audio outside the project folder is
 * first copied into "<project folder>/Audio Files/" (identical files reused,
 * name clashes numbered) and the project then references the copies. */
DalnokStatus dalnok_project_save_copying(DalnokEngine *engine, const char *path, bool copy_media, char *err,
                                         size_t err_len);
/* Replaces the current project. Missing media files become offline clips
 * (count reported in `missing_out`, may be NULL). On error the current
 * project is left untouched. */
DalnokStatus dalnok_project_load(DalnokEngine *engine, const char *path, int32_t *missing_out,
                                 char *err, size_t err_len);
/* Two-phase load for responsive UIs: prepare parses and decodes on any
 * thread; apply swaps it in on the control thread. `sample_rate` must equal
 * the engine's rate. apply consumes `data` (also on failure). */
typedef struct DalnokProjectData DalnokProjectData;
DalnokStatus dalnok_project_prepare(const char *path, double sample_rate, DalnokProjectData **out,
                                    int32_t *missing_out, char *err, size_t err_len); /* [any thread] */
DalnokStatus dalnok_project_apply(DalnokEngine *engine, DalnokProjectData *data);
/* Apply a prepared recovery copy as an unsaved project; consumes data. */
DalnokStatus dalnok_project_apply_recovery(DalnokEngine *engine, DalnokProjectData *data);
void dalnok_project_data_release(DalnokProjectData *data); /* [any thread] */

/* Imports another DAW's project: REAPER (.rpp), Ableton Live (.als), Logic Pro
 * (.logicx), Final Cut Pro XML exported from Logic (.fcpxml), or a folder of
 * stems. Produces data for dalnok_project_apply (the result starts unsaved) and
 * a JSON migration report: {"app","version","imported":{tracks,clips,media,
 * missingMedia},"skipped":{reason:count},"notes":[...]}. [any thread] */
/* Analyzes another DAW's project without loading any audio: fills the same
 * migration report as dalnok_project_import. Fast; for previews. [any thread] */
DalnokStatus dalnok_project_import_report(const char *path, char *report_json, size_t report_len, char *err,
                                          size_t err_len);
DalnokStatus dalnok_project_import(const char *path, double sample_rate, DalnokProjectData **out,
                                   int32_t *missing_out, char *report_json, size_t report_len, char *err,
                                   size_t err_len);

/* True if the model changed since the last save/load/new. */
bool dalnok_project_dirty(const DalnokEngine *engine);

/* ---- Command catalog (scripting / command palette) ------------------- */

/* Runs a named command with JSON arguments (NULL or "" = {}). Writes a JSON
 * result (or {"error": "..."}) to `result`. Returns the command's status. */
DalnokStatus dalnok_command_run(DalnokEngine *engine, const char *name, const char *args_json,
                                char *result, size_t result_len);
int32_t dalnok_command_count(void);
/* Static strings; valid for the process lifetime. */
bool dalnok_command_info(int32_t index, const char **name, const char **title, const char **args_help);

/* ---- Transport ------------------------------------------------------- */

void dalnok_transport_play(DalnokEngine *engine);
void dalnok_transport_pause(DalnokEngine *engine);
void dalnok_transport_seek(DalnokEngine *engine, int64_t frame);
bool dalnok_transport_is_playing(const DalnokEngine *engine);   /* [any thread] */
int64_t dalnok_transport_position(const DalnokEngine *engine);  /* [any thread] */

/* Metronome: a click on each beat (accented on bar starts) while the transport
 * rolls, also while recording. Live output only; never in offline renders or exports. */
void dalnok_metronome_set(DalnokEngine *engine, bool on, float level);
bool dalnok_metronome_enabled(const DalnokEngine *engine);
/* Count-in: clicks also sound at positions before `until_frame` (0 = off), even with the metronome off. */
void dalnok_metronome_count_in(DalnokEngine *engine, int64_t until_frame);

/* Cycle (loop) playback: when playback crosses `end` it continues at `start` on the exact sample.
 * Recording plays straight through. Saved with the project; not an undo step. end - start >= 64;
 * (false, 0, 0) clears the region. */
DalnokStatus dalnok_cycle_set(DalnokEngine *engine, bool enabled, int64_t start, int64_t end);
void dalnok_cycle_get(const DalnokEngine *engine, bool *enabled, int64_t *start, int64_t *end);

/* ---- Offline rendering ----------------------------------------------- */

/* Renders the current model (ignoring the live transport) into caller-provided
 * planar stereo buffers. Deterministic. */
DalnokStatus dalnok_render_offline(DalnokEngine *engine, int64_t start_frame, int64_t frames,
                                   float *left, float *right);
/* Renders [start_frame, start_frame+frames) to a WAV file.
 * bits: 16, 24 (integer PCM) or 32 (float). */
DalnokStatus dalnok_render_to_wav(DalnokEngine *engine, const char *path, int64_t start_frame,
                                  int64_t frames, int32_t bits, char *err, size_t err_len);

/* ---- Diagnostics ----------------------------------------------------- */

typedef struct {
    uint64_t callbacks;          /* audio callbacks since device start */
    uint64_t frames_rendered;
    uint64_t max_callback_ns;    /* worst observed render time */
    uint64_t last_callback_ns;
    uint32_t max_frames_per_callback;
    uint32_t overloads;          /* callbacks that exceeded their time budget */
    uint32_t snapshot_swaps;
} DalnokStats;

void dalnok_engine_stats(const DalnokEngine *engine, DalnokStats *out); /* [any thread] */
void dalnok_engine_reset_stats(DalnokEngine *engine);

#ifdef __cplusplus
}
#endif
#endif /* DALNOK_H */
