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

#define DALNOK_API_VERSION 47

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
 * Records every armed audio track (from its input channel on `input_device_uid`, or DALNOK_SIMULATED_INPUT) and/or
 * the armed instrument track (MIDI). The input device may differ from the output device: the engine then runs both
 * as one private aggregate clocked by the output (the input drift-corrected), so the output never changes.
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
    /* Recording with cycle on: one take per pass, gathered in a take folder per armed audio track. */
    int32_t take_folder_count;
    int32_t take_folders[64];
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
/* Record into launcher slot `slot` (-1 = the arrangement, the default): each recorded track's take goes to
 * that slot, trimmed to the whole bars it covers, replacing the slot's clip (part of the "Record" undo step). Not saved. */
void dalnok_record_set_slot(DalnokEngine *engine, int32_t slot);
int32_t dalnok_record_slot(const DalnokEngine *engine);
/* Device-reported round trip (input + output) plus the manual offset. Not loopback-measured. */
int64_t dalnok_record_latency(const DalnokEngine *engine);
void dalnok_record_set_latency_offset(DalnokEngine *engine, int64_t frames);
/* Armed-track monitoring (off by default; risk of feedback): every record-enabled audio track also plays its input
 * through its channel strip, as with Input Monitoring. */
void dalnok_record_set_monitoring(DalnokEngine *engine, bool on);
/* Live waveform of the take in progress: the peak (absolute) of every DALNOK_LIVE_PEAK_FRAMES frames recorded on
 * `track`, from the start of the take (timeline position: dalnok_record_start_frame, wrapping at the cycle for a
 * cycle take). Copies up to `capacity`; returns the total number (0 when the track is not recording). */
#define DALNOK_LIVE_PEAK_FRAMES 256

/* ---- Latency measurement -----------------------------------------------
 * Plays a click every quarter second on the current output (everything else silent) and listens on `input_channel`
 * of `input_device_uid`, which must hear that output: a cable from an output to that input, or an interface's
 * loopback input. After about 2.5 s, poll returns true with the measured round trip: the frames from writing a
 * sample to the output to reading it back, the median over the clicks. Recording compensates
 * dalnok_record_latency = reported + offset; set the offset to measured - reported to use the measurement.
 * Fails if recording, or when fewer than 3 clicks are heard clearly and consistently. Control thread only. */
typedef struct {
    bool ok;                  /* false: `error` says why */
    int64_t measured_frames;  /* median round trip */
    int64_t reported_frames;  /* what the devices report for the same input and output */
    int32_t clicks;           /* clicks heard clearly */
    int32_t spread_frames;    /* largest minus smallest delay among them */
    float level;              /* the loudest click as heard (linear peak) */
    char error[256];
} DalnokLatencyResult;
DalnokStatus dalnok_latency_measure_start(DalnokEngine *engine, const char *input_device_uid, int32_t input_channel,
                                          char *err, size_t err_len);
/* False while measuring; true once finished (the input returns to monitoring, or closes). */
bool dalnok_latency_measure_poll(DalnokEngine *engine, DalnokLatencyResult *result);
/* Automatic check (API 45). A device's round trip can differ from one start of its stream to the next (a Scarlett
 * Solo reads 1136 or 1142 frames). With a loopback input set here, every duplex stream the engine opens on that device
 * (recording, Input Monitoring, a device restart) measures its own round trip in its first 0.75 s: a -80 dBFS burst
 * train is added to the output and what the engine played is cross-correlated with what the loopback returns, so it
 * is inaudible and works while the project plays. Takes on that stream use the measured round trip instead of
 * dalnok_record_latency's reported + offset (a take shorter than the check keeps reported + offset). The output must
 * be on the same interface as the loopback. Empty uid or channel < 0 turns it off. Control thread only. */
DalnokStatus dalnok_latency_auto_set(DalnokEngine *engine, const char *loopback_uid, int32_t channel, char *err, size_t err_len);
/* The current (or last) stream's check: returns the stream's number (it increases with every stream start; 0 = none
 * yet) and fills `result`: ok with measured_frames once heard; otherwise `error` is "listening", "off", or why it
 * failed. `spread_frames` carries the correlation x 1000. */
uint64_t dalnok_latency_auto_result(DalnokEngine *engine, DalnokLatencyResult *result);
int32_t dalnok_record_live_peaks(DalnokEngine *engine, DalnokTrackId track, float *out, int32_t capacity);

/* ---- Input monitoring --------------------------------------------------
 * The input device used for Input Monitoring (and the default for recording). While any audio track monitors
 * (dalnok_track_set_input_monitor, or armed with dalnok_record_set_monitoring), the engine opens this input together
 * with the current output device and plays each monitored track's input channel through its inserts, fader, pan
 * and routing, whether or not the transport rolls. Empty or NULL = no input. Control thread only. */
DalnokStatus dalnok_input_set_device(DalnokEngine *engine, const char *device_uid, char *err, size_t err_len);
/* True while the input device is open (monitoring or recording). */
bool dalnok_input_running(const DalnokEngine *engine);
/* Why the input could not be opened for monitoring (empty if it is fine). Returns the length. */
int32_t dalnok_input_error(const DalnokEngine *engine, char *out, size_t out_len);
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
/* Notes played on MIDI inputs since the last call (on and off, in order), for step input (API 47). The engine
 * keeps the last 512; returns how many were written. */
typedef struct { uint8_t pitch, velocity; bool on; } DalnokInputNote;
int32_t dalnok_midi_take_input_notes(DalnokEngine *engine, DalnokInputNote *out, int32_t capacity);
/* Capture MIDI (API 47): the latest phrase played on MIDI inputs since the last capture becomes a clip on `track`
 * (whole bars; at its timeline place if the transport was running, else from the playhead's bar). Returns the clip,
 * 0 with a message when nothing was played. Call dalnok_midi_take_input_notes regularly (the app does on every
 * display tick) so no input is dropped. */
DalnokClipId dalnok_midi_capture(DalnokEngine *engine, DalnokTrackId track, char *err, size_t err_len);
int32_t dalnok_midi_capture_pending(DalnokEngine *engine); /* notes played since the last capture */
uint64_t dalnok_midi_dropped(const DalnokEngine *engine);

/* Runs the live render path (transport fades, smoothing, meters) for `frames`
 * without a device. Fails if a device is running. For tests and simulation. */
DalnokStatus dalnok_engine_pump(DalnokEngine *engine, float *left, float *right, int32_t frames);

/* ---- Meters ---------------------------------------------------------- */

/* Linear post-fader peak since the previous read, per channel; reading resets.
 * Only the live path (device or pump) feeds meters. */
DalnokStatus dalnok_meter_track(DalnokEngine *engine, DalnokTrackId track, float *left, float *right);
void dalnok_meter_master(DalnokEngine *engine, float *left, float *right);
/* Loudness after ITU-R BS.1770-4 / EBU R128 (API 47): momentary (400 ms), short-term (3 s) and gated integrated
 * loudness in LUFS, their maxima, and true peak (4x oversampled) in dBTP; -INFINITY until there is a value.
 * Live: the master while playing (the metronome is left out); reset starts a new measurement. */
typedef struct {
    float momentary, short_term, integrated, true_peak, max_momentary, max_short_term;
} DalnokLoudness;
void dalnok_loudness_live(const DalnokEngine *engine, DalnokLoudness *out);
void dalnok_loudness_reset(DalnokEngine *engine);
/* Loudness of an offline render of [start_frame, start_frame + frames) (what an export of that range contains). */
DalnokStatus dalnok_render_loudness(DalnokEngine *engine, int64_t start_frame, int64_t frames, DalnokLoudness *out,
                                    char *err, size_t err_len);
/* A plug-in slot's peak input and output (linear) since the last read; the read resets them.
 * Instruments report output only. Any pointer may be NULL. */
DalnokStatus dalnok_meter_plugin(DalnokEngine *engine, int32_t slot, float *in_left, float *in_right,
                                 float *out_left, float *out_right);
/* The latest `frames` (<= 8192) samples entering and leaving a plug-in, mixed to mono, for displays (spectrum,
 * scope). The first call starts the tap and returns 0; later calls return the samples copied. Main thread.
 * Only the live path feeds it. Either pointer may be NULL. */
int32_t dalnok_plugin_tap(DalnokEngine *engine, int32_t slot, float *in, float *out, int32_t frames);
/* The same window of the plug-in's output in stereo (goniometer). Starts the tap like dalnok_plugin_tap. */
int32_t dalnok_plugin_tap_stereo(DalnokEngine *engine, int32_t slot, float *left, float *right, int32_t frames);
/* Exact magnitude response (dB) at `count` frequencies, for plug-ins that can compute it (Dalnok's EQs).
 * DALNOK_ERR_NOT_FOUND otherwise. Main thread. */
/* What a loaded plug-in declares it is, '|'-separated (VST3 subcategories such as "Fx|Dynamics", CLAP features,
 * Audio Unit tags, a built-in's category). Returns the full length; empty when it declares nothing. Main thread. */
size_t dalnok_plugin_categories(const DalnokEngine *engine, int32_t slot, char *text, size_t len);
DalnokStatus dalnok_plugin_response(const DalnokEngine *engine, int32_t slot, const double *hz, int32_t count, double *db);
/* The master fader (dB, <= +12; <= -96 is silence). Undoable; the master meter reads after it. */
DalnokStatus dalnok_master_set_gain_db(DalnokEngine *engine, float gain_db);
float dalnok_master_gain_db(const DalnokEngine *engine);

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
/* Streaming from disk (A-09, API 38). Audio files longer than `stream_after_seconds` (default 60) are decoded once into
 * a cache file at the engine rate and played from a process-wide block cache of at most `cache_mb` (default 256).
 * The audio thread only reads blocks already in memory; a block not loaded in time plays silence and is counted.
 * Applies to media loaded afterwards. DALNOK_STREAM_SECONDS, DALNOK_STREAM_CACHE_MB and DALNOK_STREAM_DIR (cache
 * folder; default the user's cache directory) set the defaults. [any thread] */
void dalnok_stream_set_limits(double stream_after_seconds, int32_t cache_mb);
typedef struct {
    uint64_t resident_bytes;  /* block memory held by the cache */
    uint64_t budget_bytes;
    uint64_t blocks_loaded, blocks_evicted;
    uint64_t missed_frames;   /* frames played as silence because their block was not resident */
    uint32_t resident_blocks;
} DalnokStreamStats;
void dalnok_stream_stats(DalnokStreamStats *out);
bool dalnok_media_streamed(const DalnokMedia *media);
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
/* True only when every change since revision was a scalar track/master parameter. */
bool dalnok_model_only_parameters_since(const DalnokEngine *engine, uint64_t revision);
/* The model revision at which this track's own state or its clips last changed. A view that cached a track at
 * revision r can reuse it while this stays <= r. Changes outside edits (loading, relinking, plug-in loading)
 * move every track. */
uint64_t dalnok_track_revision(const DalnokEngine *engine, DalnokTrackId track);
DalnokStatus dalnok_track_parameters(const DalnokEngine *engine, DalnokTrackId track,
                                     float *gain_db, float *pan, bool *muted, bool *solo);
int32_t dalnok_track_count(const DalnokEngine *engine);
DalnokTrackId dalnok_track_at(const DalnokEngine *engine, int32_t index);

/* BEGIN GENERATED DalnokTrackInfo (scripts/gen-api.py) */
typedef struct {
    DalnokTrackId id;
    char name[128];
    int32_t color;                 /* gradient step (automatic color) */
    int32_t custom_color;          /* 0xRRGGBB pinned by the user, or -1 = automatic */
    float gain_db;                 /* -INFINITY for silence */
    float pan;
    bool muted;
    bool solo;
    int32_t clip_count;            /* clips on the track, takes and launcher slots included */
    int32_t kind;                  /* DalnokTrackKind */
    bool armed;                    /* record-enabled */
    int32_t input_channel;         /* zero-based audio input (audio tracks) */
    bool input_monitor;            /* Input Monitoring: the input plays through the track (audio tracks) */
    int32_t group;                 /* track group (0 = none) */
    DalnokTrackId stack;           /* the summing stack this track belongs to (0 = none) */
    bool is_stack;                 /* a bus that is a summing stack */
    bool collapsed;                /* stack shown closed */
    float height;                  /* lane height in points, view only (0 = the default height) */
    bool hidden;                   /* hidden from the arrangement and mixer (still plays) */
    DalnokTrackId output;          /* the bus this track plays into (0 = master) */
    bool phase_invert;             /* polarity inverted before the inserts (API 46) */
} DalnokTrackInfo;
/* END GENERATED DalnokTrackInfo */
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

/* Plug-in delay compensation in frames: every path to the master is delayed to this, playback renders the
 * timeline this far ahead of the playhead, and offline renders pre-roll by it, so tracks stay aligned
 * whatever latency their plug-ins (and their buses' plug-ins) add. */
int32_t dalnok_latency_compensation(const DalnokEngine *engine);

/* ---- Take folders and comping ------------------------------------------
 * A take folder holds a track's takes (alternate clips, not played) and a comp: ordered segments saying which
 * take plays where. The comp is realized as ordinary clips tagged with the folder, with short equal-power
 * crossfades where takes change; it is rebuilt on every comp change (edits to those pieces don't persist). */
typedef struct { int64_t from, to; int32_t take; } DalnokCompSegment; /* take = index into the folder's takes */
/* Gathers audio clips on one track into a new folder (later clips cover earlier ones). Returns its id or 0. */
int32_t dalnok_take_folder_create(DalnokEngine *engine, DalnokTrackId track, const DalnokClipId *takes, int32_t count);
int32_t dalnok_take_folders(const DalnokEngine *engine, DalnokTrackId track, int32_t *out, int32_t capacity);
int32_t dalnok_take_folder_takes(const DalnokEngine *engine, int32_t folder, DalnokClipId *out, int32_t capacity);
int32_t dalnok_take_folder_comp(const DalnokEngine *engine, int32_t folder, DalnokCompSegment *out, int32_t capacity);
DalnokStatus dalnok_take_folder_set_comp(DalnokEngine *engine, int32_t folder, const DalnokCompSegment *segments, int32_t count);

/* ---- Clip launcher ----------------------------------------------------
 * Every track has launcher slots (scenes) beside its timeline lane. A slot holds a copy of a clip that loops
 * when launched, replacing that track's arrangement until stopped. Launches land on the next bar (exactly on
 * the sample); launching while stopped starts the transport there. Exports play the arrangement only. */
int32_t dalnok_launcher_scenes(const DalnokEngine *engine);
DalnokClipId dalnok_launcher_copy_clip(DalnokEngine *engine, DalnokClipId clip, int32_t slot); /* replaces the slot; undoable */
/* A copy of any clip (e.g. a slot clip) on a compatible track's timeline at `start`. Undoable. */
DalnokClipId dalnok_clip_place_copy(DalnokEngine *engine, DalnokClipId clip, DalnokTrackId track, int64_t start);
DalnokStatus dalnok_launcher_launch(DalnokEngine *engine, DalnokTrackId track, int32_t slot);   /* -1: back to the arrangement */
DalnokStatus dalnok_launcher_launch_scene(DalnokEngine *engine, int32_t slot);
void dalnok_launcher_stop_all(DalnokEngine *engine);
int32_t dalnok_launcher_playing(const DalnokEngine *engine, DalnokTrackId track);              /* slot or -1 */
int64_t dalnok_launcher_slot_start(const DalnokEngine *engine, DalnokTrackId track); /* where the playing slot's first loop began */
/* A launch waiting for its bar (API 45): returns the slot it will switch to (-1 = back to the arrangement) and, if
 * `at` is given, the timeline frame where it lands; returns -2 when nothing is queued on that track. */
int32_t dalnok_launcher_queued(const DalnokEngine *engine, DalnokTrackId track, int64_t *at);
/* Follow action for a slot clip: after `loops` loops, 1 = play the next filled slot, 2 = stop (0 = none). Undoable. */
DalnokStatus dalnok_launcher_set_follow(DalnokEngine *engine, DalnokClipId clip, int32_t action, int32_t loops);
/* Performance recording: while on, every launch and follow is logged; turning it off writes the
 * performance into the arrangement as clips (one undo step "Record Launcher"). */
void dalnok_launcher_set_recording(DalnokEngine *engine, bool on);
bool dalnok_launcher_recording(const DalnokEngine *engine);

/* ---- Track stacks -----------------------------------------------------
 * A summing stack is a bus placed above its members (which move to follow it and are routed into it).
 * Closing a stack is a display state, saved with the project. Stacks don't nest yet. */
DalnokTrackId dalnok_track_stack_create(DalnokEngine *engine, const DalnokTrackId *members, int32_t count, const char *name);
DalnokStatus dalnok_track_stack_set_collapsed(DalnokEngine *engine, DalnokTrackId stack, bool collapsed);
/* Lane height in points (40-400, view only, undoable). track 0 = every track; height 0 = back to the default. */
DalnokStatus dalnok_track_set_height(DalnokEngine *engine, DalnokTrackId track, float height);
/* Hide a track from the arrangement and mixer (API 26; it keeps playing). track 0 + hidden=false shows all. Undoable. */
DalnokStatus dalnok_track_set_hidden(DalnokEngine *engine, DalnokTrackId track, bool hidden);
bool dalnok_track_hidden(const DalnokEngine *engine, DalnokTrackId track);
/* Phase (polarity) invert (API 46): the track's whole source flips before its inserts, so pre- and post-fader sends
 * carry it too. Saved with the project (format 14); one undo step. Read it from DalnokTrackInfo.phase_invert. */
DalnokStatus dalnok_track_set_phase_invert(DalnokEngine *engine, DalnokTrackId track, bool on);
DalnokStatus dalnok_track_stack_ungroup(DalnokEngine *engine, DalnokTrackId stack);

/* Sidechain: feeds `source`'s post-insert, pre-fader signal into the plug-in's sidechain input (0 = none).
 * Only plug-ins with an auxiliary input bus use it (dalnok_plugin_has_sidechain). Undoable. */
DalnokStatus dalnok_plugin_set_sidechain(DalnokEngine *engine, DalnokTrackId track, int32_t slot, DalnokTrackId source);
DalnokTrackId dalnok_plugin_sidechain(const DalnokEngine *engine, DalnokTrackId track, int32_t slot);
bool dalnok_plugin_has_sidechain(const DalnokEngine *engine, int32_t slot);
/* Bypass (API 25): a bypassed effect passes audio through untouched (it leaves the insert chain and the
 * delay compensation); a bypassed instrument is silent. Saved with the project; undoable. */
DalnokStatus dalnok_plugin_set_bypassed(DalnokEngine *engine, DalnokTrackId track, int32_t slot, bool bypassed);
/* Markers (API 26): named timeline positions, sorted by frame. Edits are undoable; saved from format 11. */
typedef struct {
    int32_t id;
    int64_t frame;
    char name[128];
} DalnokMarker;
int32_t dalnok_marker_count(const DalnokEngine *engine);
DalnokStatus dalnok_marker_at(const DalnokEngine *engine, int32_t index, DalnokMarker *out);
int32_t dalnok_marker_add(DalnokEngine *engine, int64_t frame, const char *name); /* returns the id, 0 on failure */
DalnokStatus dalnok_marker_remove(DalnokEngine *engine, int32_t id);
DalnokStatus dalnok_marker_move(DalnokEngine *engine, int32_t id, int64_t frame);
DalnokStatus dalnok_marker_rename(DalnokEngine *engine, int32_t id, const char *name);
/* Duplicates a track below itself (API 26): settings, sends, automation, clips and plug-ins with their state.
 * Take folders stay with the original. Stacks are refused. Returns the new track, 0 on failure. One undo step. */
DalnokTrackId dalnok_track_duplicate(DalnokEngine *engine, DalnokTrackId track);
/* Reorders a track's plug-ins (API 26): moves `slot` to `index` (0 = first in the chain). Undoable. */
DalnokStatus dalnok_plugin_move(DalnokEngine *engine, DalnokTrackId track, int32_t slot, int32_t index);
/* Copies plug-ins to another track (or the same one) at `index` in its chain (-1 = the end), in their chain order:
 * new instances with the same state, one undo step (API 47). An instrument replaces the target's instrument; an empty
 * audio track (no clips) becomes an instrument track. Writes up to `capacity` new slot ids to `out` (may be null) and
 * returns how many were pasted (0 on failure). */
int32_t dalnok_plugins_copy(DalnokEngine *engine, DalnokTrackId from, const int32_t *slots, int32_t count,
                            DalnokTrackId to, int32_t index, int32_t *out, int32_t capacity);
bool dalnok_plugin_bypassed(const DalnokEngine *engine, DalnokTrackId track, int32_t slot);
/* Folding (API 40): the device chain shows a folded plug-in as a narrow strip (name, bypass, meter). Saved with
 * the project; undoable; no effect on audio. */
DalnokStatus dalnok_plugin_set_folded(DalnokEngine *engine, DalnokTrackId track, int32_t slot, bool folded);
bool dalnok_plugin_folded(const DalnokEngine *engine, DalnokTrackId track, int32_t slot);

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
/* Automation writing: while held, a track's fader (target 0) or pan (1) value plays instead of its lane
 * (the app records the moves and replaces the lane's points afterwards). Live only. */
void dalnok_track_automation_hold(DalnokEngine *engine, DalnokTrackId track, int32_t target, bool hold);
/* Plug-in parameter automation: values are normalized 0-1; applied once per processing block (up to 512
 * frames) just before the plug-in runs. Removing the plug-in removes its lanes. */
DalnokStatus dalnok_plugin_set_automation(DalnokEngine *engine, DalnokTrackId track, int32_t slot, uint32_t param,
                                          const DalnokAutoPoint *points, int32_t count);
int32_t dalnok_plugin_automation(const DalnokEngine *engine, DalnokTrackId track, int32_t slot, uint32_t param,
                                 DalnokAutoPoint *out, int32_t capacity);
DalnokStatus dalnok_track_info(const DalnokEngine *engine, DalnokTrackId track, DalnokTrackInfo *out);

/* Clips of a track in z-order (later = on top; overlapping clips: top wins). */
DalnokClipId dalnok_track_clip_at(const DalnokEngine *engine, DalnokTrackId track, int32_t index);

/* BEGIN GENERATED DalnokClipInfo (scripts/gen-api.py) */
typedef struct {
    DalnokClipId id;
    DalnokTrackId track;
    DalnokMediaId media;
    int64_t start;                 /* timeline frame */
    int64_t offset;                /* frame within media */
    int64_t length;                /* frames */
    int64_t media_frames;          /* total frames of the source media */
    bool offline;                  /* source missing: renders silence */
    int64_t fade_in;               /* frames */
    int64_t fade_out;              /* frames */
    int32_t fade_curve;            /* DalnokFadeCurve */
    float gain_db;                 /* clip gain; -INFINITY = silent */
    double rate;                   /* source frames per timeline frame (1 = normal speed) */
    float pitch;                   /* semitones (time-stretch mode only) */
    bool preserve_pitch;           /* false = varispeed */
    bool processing;               /* stretched audio still rendering in the background (silent until ready) */
    char name[128];
    bool midi;                     /* MIDI clip (media = 0; see dalnok_midi_clip_notes) */
    int32_t note_count;
    int32_t folder;                /* take folder (0 = none) */
    bool alt;                      /* a take inside a folder: kept, not played (the comp's pieces play) */
    int32_t slot;                  /* clip launcher slot (>= 0: not on the timeline), -1 = timeline */
    int32_t follow;                /* launcher follow action: 0 none, 1 next filled slot, 2 stop */
    int32_t follow_loops;          /* after this many loops */
    bool muted;                    /* clip muted */
    int32_t warp_points;           /* audio quantize: warp anchors (dalnok_clip_warp) */
    int64_t loop_length;           /* clip loop: the repeating window (0 = not looped) */
    bool follows_tempo;            /* audio follows tempo changes (time-stretched) */
    int64_t loop_phase;            /* clip loop: where its first pass starts in the window */
} DalnokClipInfo;
/* END GENERATED DalnokClipInfo */
DalnokStatus dalnok_clip_info(const DalnokEngine *engine, DalnokClipId clip, DalnokClipInfo *out);
/* Every clip of a track in z-order (takes and launcher slots included), in one pass: writes up to `capacity`
 * entries and returns the track's clip count (call with capacity 0 to size the buffer), or -1 if there is no such
 * track. Reading a track clip by clip (dalnok_track_clip_at + dalnok_clip_info) costs a scan of the whole project
 * per clip. */
int32_t dalnok_track_clips(const DalnokEngine *engine, DalnokTrackId track, DalnokClipInfo *out, int32_t capacity);

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
/* Copy / paste / duplicate (API 26): copies clips with fades, gain, stretch and MIDI notes, one undo step.
 * The earliest clip lands at `start`; each clip moves `track_shift` tracks down (0 = same tracks). Returns the
 * number of new clips (written to `out`, in the given order), 0 on failure with nothing changed. */
int32_t dalnok_clips_copy(DalnokEngine *engine, const DalnokClipId *clips, int32_t count, int64_t start, int32_t track_shift,
                          DalnokClipId *out, int32_t capacity);
/* Clipboard (API 26): copies held by the engine (not undoable; cleared when another project loads), so a cut
 * clip can still be pasted. Paste puts the topmost copied track's clips on `track` (the rest keep their spacing
 * below it) with the earliest clip at `start`; one undo step. Returns the number of new clips, 0 on failure. */
DalnokStatus dalnok_clipboard_copy(DalnokEngine *engine, const DalnokClipId *clips, int32_t count);
int32_t dalnok_clipboard_count(const DalnokEngine *engine);
int32_t dalnok_clipboard_paste(DalnokEngine *engine, DalnokTrackId track, int64_t start, DalnokClipId *out, int32_t capacity);
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
/* Muted clips remain editable and saved; they do not contribute audio or MIDI. */
DalnokStatus dalnok_clip_set_muted(DalnokEngine *engine, DalnokClipId clip, bool muted);
bool dalnok_clip_muted(const DalnokEngine *engine, DalnokClipId clip);

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
    bool loading;      /* queued for deferred activation (dalnok_project_apply_deferred) */
    bool isolated;     /* runs in its own dalnok-plughost process (ADR-0014) */
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
/* The plug-in's text for a parameter at any normalized value, without changing it (printed knob scales).
 * NUL-terminated, truncated to `len`. DALNOK_ERR_NOT_FOUND if the plug-in can't say. */
DalnokStatus dalnok_plugin_parameter_text(const DalnokEngine *engine, int32_t slot, uint32_t id, double normalized,
                                          char *text, size_t len);
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
/* Isolated plug-ins (DalnokPluginSlotInfo.isolated; ADR-0015) cannot be embedded: their editor opens in a window
 * owned by the plug-in's own process, a floating panel that follows Dalnok (hidden while another application is
 * active). Shows it, or brings it to the front, titled `title`, with its top-left at (x, y) in AppKit screen
 * coordinates (NaN centers it). dalnok_plugin_close_editor closes it. Main thread. (API 36) */
DalnokStatus dalnok_plugin_show_editor_window(DalnokEngine *engine, int32_t slot, const char *title, double x, double y,
                                              char *err, size_t err_len);
typedef struct {
    bool open;                 /* opened and not closed by the user */
    bool visible;              /* on screen now (an open editor hides while another application is active) */
    double x, y, width, height;            /* window frame, AppKit screen coordinates */
    double content_width, content_height;  /* the editor's area */
    int64_t window_number;     /* the window server's number (CGWindowList), owned by process_id */
    int64_t level;
    int32_t process_id;        /* the plug-in's dalnok-plughost process */
} DalnokPluginEditorWindow;
DalnokStatus dalnok_plugin_editor_window(DalnokEngine *engine, int32_t slot, DalnokPluginEditorWindow *out);
/* An isolated editor's window has the keyboard while Dalnok stays active, so keys it does not use (Space, ⌘S, ⌘Z
 * outside a text field) are passed back here, oldest first. Returns false when there are none. The front end replays
 * each one as its own key event. Main thread. (API 39) */
typedef struct {
    int32_t slot;
    uint16_t key_code;                       /* virtual key code */
    uint64_t modifiers;                      /* NSEventModifierFlags */
    char characters[16];                     /* UTF-8 */
    char characters_ignoring_modifiers[16];  /* UTF-8 */
} DalnokEditorKey;
bool dalnok_plugin_take_editor_key(DalnokEngine *engine, DalnokEditorKey *out);
/* Not a key: the editor window's title-bar Controls button (API 40). The front end shows the plug-in's controls
 * (Dalnok's parameter view) for `slot` instead of replaying a key. */
#define DALNOK_EDITOR_SHOW_CONTROLS 0xFFFF
/* Writes the editor window's pixels to a PNG (visual checks, self-tests). */
DalnokStatus dalnok_plugin_editor_snapshot(DalnokEngine *engine, int32_t slot, const char *png_path);

/* ---- Instruments, MIDI clips, tempo --------------------------------- */

/* Adds a track that plays MIDI clips through the built-in Dalnok Poly synth.
 * It becomes the armed instrument track (plays live MIDI input). */
DalnokTrackId dalnok_track_add_instrument(DalnokEngine *engine, const char *name);
/* Record-enable. Arming a track disarms other tracks of the same kind. */
DalnokStatus dalnok_track_set_armed(DalnokEngine *engine, DalnokTrackId track, bool armed);
DalnokStatus dalnok_track_set_input(DalnokEngine *engine, DalnokTrackId track, int32_t input_channel);
/* ---- Track groups (Logic's Groups) ---------------------------------------
 * Members share the linked settings: a change on one applies to the others in the same undo step. Volume and pan
 * move relatively (in dB / pan units; a fader at -inf stays there), mute, solo, record enable (audio tracks) and
 * Input Monitoring copy. The clutch suspends every group (not saved). Groups never change the sound by themselves. */
typedef struct {
    int32_t id;
    char name[128];
    bool volume, pan, mute, solo, arm, monitor; /* what the group links */
    int32_t members;                            /* tracks in it (read only) */
} DalnokGroupInfo;
int32_t dalnok_groups(const DalnokEngine *engine, DalnokGroupInfo *out, int32_t capacity); /* returns the count */
/* A new group (default links: volume, mute, solo, record, Input Monitoring) holding `members`; returns its id or 0. */
int32_t dalnok_group_create(DalnokEngine *engine, const char *name, const DalnokTrackId *members, int32_t count);
DalnokStatus dalnok_group_remove(DalnokEngine *engine, int32_t group);   /* members keep their settings */
DalnokStatus dalnok_group_set(DalnokEngine *engine, const DalnokGroupInfo *info); /* name and links, by id */
DalnokStatus dalnok_track_set_group(DalnokEngine *engine, DalnokTrackId track, int32_t group); /* 0 = none */
void dalnok_groups_set_clutch(DalnokEngine *engine, bool suspended);
bool dalnok_groups_clutch(const DalnokEngine *engine);

/* Input Monitoring (the I button): hear the track's input through its channel strip, recording or not. Saved with
 * the project, not an undo step. Audio tracks only. */
DalnokStatus dalnok_track_set_input_monitor(DalnokEngine *engine, DalnokTrackId track, bool on);

/* Auditions a note on an instrument track (piano-roll edits, as other DAWs do): `on` starts it at `velocity`, and the
 * same pitch with on = false releases it. It plays through the track's instrument (built-in or plug-in, isolated or not)
 * and its inserts whether or not the transport plays, without arming the track, and is never recorded. While notes
 * sound, and for 2 s after the last release, the track takes live MIDI input in place of the armed one. A release
 * (on = false) of a note that is not sounding is silent but still processes the instrument for those 2 s: sample-based
 * plug-ins that finish loading in their first blocks are then ready for the first note (open a piano roll with one).
 * DALNOK_ERR_NOT_FOUND: no such instrument track. [control thread] (API 39) */
DalnokStatus dalnok_track_preview_note(DalnokEngine *engine, DalnokTrackId track, uint8_t pitch, uint8_t velocity, bool on);

/* A note in frames relative to the clip's source origin (timeline = clip start + start - clip offset). */
typedef struct {
    int64_t start, length;
    uint8_t pitch, velocity; /* 0-127, 1-127 */
} DalnokNote;
/* An empty audio track (no clips) becomes an instrument track (API 47). */
DalnokClipId dalnok_midi_clip_add(DalnokEngine *engine, DalnokTrackId track, int64_t start, int64_t length);
/* Replaces all notes (one undo step). */
DalnokStatus dalnok_midi_clip_set_notes(DalnokEngine *engine, DalnokClipId clip, const DalnokNote *notes, int32_t count);
/* Copies up to `capacity` notes sorted by start; returns the total count (-1 if not a MIDI clip). */
int32_t dalnok_midi_clip_notes(const DalnokEngine *engine, DalnokClipId clip, DalnokNote *out, int32_t capacity);
/* Moves note starts toward a grid of `grid_beats` anchored at frame 0 (strength 0-1). */
DalnokStatus dalnok_midi_quantize(DalnokEngine *engine, DalnokClipId clip, double grid_beats, double strength);
/* Groove (API 47): offsets in beats for each step of a pattern on a grid (step k of `count`). Extract measures them
 * from a clip (MIDI notes, or an audio clip's hits); apply moves a MIDI clip's notes to grid + offset, `strength` of
 * the way (one undo step). Swing 8ths at 60 %: grid 0.5, offsets {0, 0.1}. */
DalnokStatus dalnok_groove_extract(DalnokEngine *engine, DalnokClipId clip, double grid_beats, int32_t count, double *offsets);
DalnokStatus dalnok_groove_apply(DalnokEngine *engine, DalnokClipId clip, double grid_beats, const double *offsets, int32_t count,
                                 double strength);
/* MIDI functions (Logic's MIDI Functions / Ableton's note tools), API 47. They act on `selected` (count 0 = every note
 * in the clip's window), as one undo step, and write the selected notes as they are afterwards to `out` (same order,
 * may be null). Arguments:
 *   LEGATO           -                       each note lasts until the next selected start
 *   FIXED_LENGTH     a = length in beats
 *   SCALE_QUANTIZE   a = root (0 = C .. 11), b = scale (0 major, 1 minor, 2 dorian, 3 mixolydian, 4 major
 *                    pentatonic, 5 minor pentatonic, 6 harmonic minor, 7 blues); nearest degree, ties go down
 *   HUMANIZE         a = timing range ± ms, b = velocity range ±
 *   SET_VELOCITY     a = 1-127;  SCALE_VELOCITY  a = percent */
/* MIDI controller events in a clip (API 47), frames from the clip source's start like notes. controller 0-127 is a
 * control change (value 0-127: 1 mod wheel, 7 volume, 10 pan, 11 expression, 64 sustain, ...); 128 is pitch bend
 * (value 0-16383, 8192 = centre). Plug-in instruments get them (VST3 through the plug-in's MIDI mapping), and a
 * plug-in instrument played live gets the keyboard's controllers and pitch bend. Saved from format 17. */
typedef struct { int64_t start; int32_t controller; int32_t value; } DalnokMidiCC;
#define DALNOK_PITCH_BEND 128
DalnokStatus dalnok_midi_clip_set_controllers(DalnokEngine *engine, DalnokClipId clip, const DalnokMidiCC *events, int32_t count);
int32_t dalnok_midi_clip_controllers(const DalnokEngine *engine, DalnokClipId clip, DalnokMidiCC *out, int32_t capacity); /* total */
typedef enum {
    DALNOK_MIDI_LEGATO = 0, DALNOK_MIDI_FIXED_LENGTH = 1, DALNOK_MIDI_SCALE_QUANTIZE = 2, DALNOK_MIDI_HUMANIZE = 3,
    DALNOK_MIDI_SET_VELOCITY = 4, DALNOK_MIDI_SCALE_VELOCITY = 5
} DalnokMidiFunction;
DalnokStatus dalnok_midi_transform(DalnokEngine *engine, DalnokClipId clip, int32_t function, const DalnokNote *selected,
                                   int32_t count, double a, double b, DalnokNote *out);
/* Audio quantize (API 47; Logic's Flex quantize, with slices). The clip's transients (attack starts, in source frames;
 * `sensitivity` 0-1, 0.5 typical): returns the total count, writes up to `capacity`, -1 if not an audio clip. */
int32_t dalnok_audio_transients(const DalnokEngine *engine, DalnokClipId clip, double sensitivity, int64_t *out, int32_t capacity);
/* Quantizes an audio clip in place (one clip, one undo step): a warp map moves each transient toward the grid of
 * `grid_beats` (tempo map) by `strength` (0-1]. Each attack (its first 50 ms) plays at the clip's own speed; the rest
 * between two transients is time-stretched (pitch kept) to fit, with a 5 ms crossfade centred on every anchor, 6 ms
 * before the attack. The clip's start and end stay. Quantizing again starts from the recorded timing. Trims and splits
 * keep the warp. DALNOK_ERR_INVALID_ARG: no transients, MIDI, varispeed, offline. */
DalnokStatus dalnok_audio_quantize(DalnokEngine *engine, DalnokClipId clip, double grid_beats, double strength, double sensitivity);
/* The clip's warp anchors: source frames in its media and times from the clip's start (dalnok_clip_info warp_points
 * of them). Returns the total count (0: no warp, -1: no such audio clip). */
int32_t dalnok_clip_warp(const DalnokEngine *engine, DalnokClipId clip, int64_t *source, int64_t *time, int32_t capacity);
/* Sets the warp (count 0 removes it: one speed again). One undo step. */
DalnokStatus dalnok_clip_set_warp(DalnokEngine *engine, DalnokClipId clip, const int64_t *source, const int64_t *time, int32_t count);
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
/* Tests and benchmarks (A-13): true makes the mix use plain scalar loops instead of the platform's vector routines,
 * so the two can be compared. Process-wide; call while nothing renders. */
void dalnok_debug_set_scalar_mix(bool scalar);
/* The newest project format version this build reads and writes (engine/api/project-format.json describes it). */
int32_t dalnok_project_format_version(void);
/* Write a recovery snapshot without marking the current project saved or copying media.
 * Use a separate recovery path, never the primary project file. [control thread] */
DalnokStatus dalnok_project_save_snapshot(DalnokEngine *engine, const char *path, char *err, size_t err_len);
/* Export a DAWproject (.dawproject: ZIP with project.xml, metadata.xml and the audio): tracks, the arrangement
 * (audio and MIDI clips in seconds, fades, time-stretch as warp markers), volume, pan, mute, solo, outputs and
 * sends. `notes` receives one line per thing the format didn't carry (plug-ins, automation, ...). [control thread] */
DalnokStatus dalnok_project_export_dawproject(DalnokEngine *engine, const char *path, char *notes, size_t notes_len,
                                              char *err, size_t err_len);
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
/* Set a directory for pre-activation recovery copies; NULL disables it. [control thread] */
void dalnok_project_set_recovery_directory(DalnokEngine *engine, const char *directory);
DalnokStatus dalnok_project_apply(DalnokEngine *engine, DalnokProjectData *data);
/* Apply as an unsaved project without activating its plug-ins; consumes data. */
DalnokStatus dalnok_project_apply_recovery(DalnokEngine *engine, DalnokProjectData *data);
/* Apply without blocking on plug-ins (ADR-0013): the project is live at once with every plug-in slot unloaded
 * and queued (DalnokPluginSlotInfo.loading); consumes data. Then call dalnok_plugins_activate_next repeatedly
 * on the main thread, returning to the run loop between calls. [control thread] */
DalnokStatus dalnok_project_apply_deferred(DalnokEngine *engine, DalnokProjectData *data);
int32_t dalnok_plugins_pending(const DalnokEngine *engine);
/* Loads the next queued plug-in; returns how many remain (queued or loading), or -1 if none was. `slot_out` and
 * `seconds_out` (optional) report the slot finished in this call and how long its initialization took. Isolated
 * plug-ins (dalnok_plugins_set_host) load in their own processes without blocking: the call starts up to four hosts
 * and returns at once with *slot_out = 0 until one finishes; keep calling from the run loop (API 35). */
int32_t dalnok_plugins_activate_next(DalnokEngine *engine, int32_t *slot_out, double *seconds_out);
/* Leaves the remaining queued plug-ins unloaded with their saved state (reloadable); hosts still loading are killed. */
void dalnok_plugins_cancel_pending(DalnokEngine *engine);
/* Out-of-process hosting (ADR-0014): plug-ins loaded from now on run in their own `host` process (dalnok-plughost);
 * NULL or "" runs them in this process. Built-in plug-ins always run here. A crashed or unresponsive isolated
 * plug-in is reported as not loaded with its reason; dalnok_plugin_reload restarts it. [control thread] */
void dalnok_plugins_set_host(DalnokEngine *engine, const char *host);
/* How an isolated plug-in is doing on the live path (API 37). All isolated plug-ins in one callback share a deadline
 * of 40 % of its period; once it is spent the rest pass a block untouched (budget_skips, never counted as missed).
 * While an output device runs, the host's processing thread joins the device's audio workgroup. */
typedef struct {
    uint64_t missed_blocks;   /* the host answered late or was still busy */
    uint64_t budget_skips;    /* passed because other isolated plug-ins spent the callback's budget */
    bool workgroup_joined;    /* the processing thread is in the running device's audio workgroup */
    int32_t workgroup_error;  /* os_workgroup_join's result for the last workgroup offered (0 = joined) */
    uint32_t workgroup_joins; /* workgroups joined so far (one per device start or change) */
} DalnokPluginIsolationStats;
DalnokStatus dalnok_plugin_isolation_stats(DalnokEngine *engine, int32_t slot, DalnokPluginIsolationStats *out);
/* The host process's entry point (tools/dalnok-plughost). */
int dalnok_plughost_main(int argc, char **argv);
/* Loads an unloaded slot (cancelled, recovery mode, or failed) from its saved state. Not undoable.
 * DALNOK_ERR_NOT_FOUND: no such slot; DALNOK_ERR_UNSUPPORTED: it did not load (reason in err). */
DalnokStatus dalnok_plugin_reload(DalnokEngine *engine, int32_t slot, char *err, size_t err_len);
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
/* Some plug-in editors change their plug-in's state without telling the host. True when a plug-in whose editor was
 * opened since the last save now has a different state: ask before closing, as for dalnok_project_dirty. Asks those
 * plug-ins for their state, so call it when closing, not on every frame. Main thread. (API 39) */
bool dalnok_project_plugins_changed(const DalnokEngine *engine);

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
/* As dalnok_render_to_wav, then keeps rendering past the end (synth releases, delay and reverb tails) until the
 * output stays below -100 dBFS for half a second or max_tail frames were written. *tail_written (optional) gets
 * the number of extra frames. Use it for whole-arrangement exports (API 47). */
DalnokStatus dalnok_render_to_wav_tail(DalnokEngine *engine, const char *path, int64_t start_frame, int64_t frames,
                                       int32_t bits, int64_t max_tail, int64_t *tail_written, char *err,
                                       size_t err_len);
/* Bounce in Place: renders the track's clips through its plug-ins (pre-fader, with their tail) into a 32-bit float
 * WAV at `path`, adds it on a new audio track right below with the same fader, pan and output, and mutes the
 * original. One undo step. Returns the new track (0 on failure, with a message in `err`). API 47. */
/* Export formats (API 47). AAC is 256 kbit/s in an .m4a; ALAC and FLAC are lossless 24-bit; 16-bit WAV is dithered. */
typedef enum {
    DALNOK_FORMAT_WAV16 = 0, DALNOK_FORMAT_WAV24 = 1, DALNOK_FORMAT_WAV32F = 2, DALNOK_FORMAT_AIFF24 = 3,
    DALNOK_FORMAT_AAC = 4, DALNOK_FORMAT_ALAC = 5, DALNOK_FORMAT_FLAC = 6
} DalnokFileFormat;
/* As dalnok_render_to_wav_tail, in any DalnokFileFormat. */
DalnokStatus dalnok_render_to_file(DalnokEngine *engine, const char *path, int64_t start_frame, int64_t frames,
                                   int32_t format, int64_t max_tail, int64_t *tail_written, char *err, size_t err_len);
/* Export Stems (API 47): one file per track that isn't a bus and isn't muted, post-fader (sends left out), into the
 * existing `folder` as "NN Name.<ext>", all the same length (the range, plus up to max_tail frames of tail).
 * Returns the number of files written, or -1 with a message in `err`. */
int32_t dalnok_export_stems(DalnokEngine *engine, const char *folder, int32_t format, int64_t start_frame, int64_t frames,
                            int64_t max_tail, char *err, size_t err_len);
/* Dalnok Sampler and Dalnok Drums (built-in instruments "dalnok:sampler", "dalnok:drums"; API 47): load an audio
 * file into a zone (the Sampler has zone 0; Drums pads 0-15 play notes 36-51). An empty path clears it. The file's
 * path is saved in the plug-in's state. sample_path copies the zone's path (empty when none); returns its length. */
DalnokStatus dalnok_plugin_set_sample(DalnokEngine *engine, int32_t slot, int32_t zone, const char *path, char *err, size_t err_len);
size_t dalnok_plugin_sample_path(const DalnokEngine *engine, int32_t slot, int32_t zone, char *out, size_t out_len);
/* Clip loop (API 47): on, the clip's current window repeats for as long as the clip is extended (drag its right
 * edge); off, it plays its window once. Not for time-stretched or quantized audio or launcher slots. One undo step. */
DalnokStatus dalnok_clip_set_loop(DalnokEngine *engine, DalnokClipId clip, bool looped);
/* Audio follows tempo (Ableton's warp, API 47): tempo changes keep the clip on its beats and time-stretch it, pitch
 * kept (format 18). Not for varispeed clips. One undo step. */
DalnokStatus dalnok_clip_set_follow_tempo(DalnokEngine *engine, DalnokClipId clip, bool follow);
DalnokTrackId dalnok_track_bounce_in_place(DalnokEngine *engine, DalnokTrackId track, const char *path, char *err,
                                           size_t err_len);

/* ---- Diagnostics ----------------------------------------------------- */

typedef struct {
    uint64_t callbacks;          /* audio callbacks since device start */
    uint64_t frames_rendered;
    uint64_t max_callback_ns;    /* worst observed render time */
    uint64_t last_callback_ns;
    uint32_t max_frames_per_callback;
    uint32_t overloads;          /* callbacks that exceeded their time budget */
    uint32_t snapshot_swaps;
    uint32_t retired_queue_depth;
    uint32_t retired_queue_high_water;
    uint64_t pending_snapshot_callbacks;
    uint64_t snapshot_adoption_skips;
} DalnokStats;

void dalnok_engine_stats(const DalnokEngine *engine, DalnokStats *out); /* [any thread] */
void dalnok_engine_reset_stats(DalnokEngine *engine);

/* Diagnostics (tests): compiles the live snapshot, which reuses unchanged per-track content, and returns how
 * many tracks' reused content differs from a fresh build. 0 means incremental compilation matches. [control] */
int32_t dalnok_engine_snapshot_mismatches(DalnokEngine *engine);

#ifdef __cplusplus
}
#endif
#endif /* DALNOK_H */
