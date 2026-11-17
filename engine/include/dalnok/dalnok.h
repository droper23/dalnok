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

#define DALNOK_API_VERSION 7

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
} DalnokTrackInfo;
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
/* Moves a clip (optionally to another track) and brings it to the top. */
DalnokStatus dalnok_clip_move(DalnokEngine *engine, DalnokClipId clip, DalnokTrackId track,
                              int64_t timeline_start);
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
