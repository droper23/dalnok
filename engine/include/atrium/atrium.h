/*
 * Atrium engine — stable C API.
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
 *     mutation is an undoable command and bumps atrium_model_revision().
 *   - Front ends re-query the model when the revision changes; they never
 *     keep their own copy.
 */
#ifndef ATRIUM_H
#define ATRIUM_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ATRIUM_API_VERSION 2

typedef enum {
    ATRIUM_OK = 0,
    ATRIUM_ERR_INVALID_ARG = 1,
    ATRIUM_ERR_IO = 2,
    ATRIUM_ERR_DEVICE = 3,
    ATRIUM_ERR_NOT_FOUND = 4,
    ATRIUM_ERR_UNSUPPORTED = 5,
    ATRIUM_ERR_FORMAT = 6,
} AtriumStatus;

typedef struct AtriumEngine AtriumEngine;
typedef struct AtriumMedia AtriumMedia;
typedef int32_t AtriumTrackId;
typedef int32_t AtriumClipId;
typedef int32_t AtriumMediaId;

/* ---- Engine lifecycle ------------------------------------------------ */

/* Creates an engine running at `sample_rate`. Pass 0 to adopt the default
 * output device's rate. */
AtriumEngine *atrium_engine_create(double sample_rate);
void atrium_engine_destroy(AtriumEngine *engine);

/* Opens the system default output device and starts the audio callback. */
AtriumStatus atrium_engine_start_device(AtriumEngine *engine, char *err, size_t err_len);
void atrium_engine_stop_device(AtriumEngine *engine);
bool atrium_engine_device_running(const AtriumEngine *engine);
double atrium_engine_sample_rate(const AtriumEngine *engine);

/* Frees snapshots retired by the audio thread. Call periodically (e.g. from a
 * UI timer). Cheap when there is nothing to do. */
void atrium_engine_collect_garbage(AtriumEngine *engine);

/* ---- Media (decoded audio, independent of any engine) ---------------- */

/* Decodes an audio file into memory, converting to `sample_rate`.
 * [any thread] — safe to call from a background thread. */
AtriumStatus atrium_media_load(const char *path, double sample_rate,
                               AtriumMedia **out, char *err, size_t err_len);
/* Wraps caller-provided planar float samples (copied). 1 or 2 channels. [any thread] */
AtriumMedia *atrium_media_from_samples(const float *const *channels, int32_t channel_count,
                                       int64_t frames, double sample_rate);
void atrium_media_release(AtriumMedia *media);   /* [any thread] */
int64_t atrium_media_frames(const AtriumMedia *media);
int32_t atrium_media_channels(const AtriumMedia *media);
double atrium_media_sample_rate(const AtriumMedia *media);

/* Fills `count` columns of min/max peaks for `channel`, starting at
 * `start_frame`, each column covering `frames_per_column` frames.
 * Columns outside the media are 0. Returns columns written. [any thread] */
int64_t atrium_media_peaks(const AtriumMedia *media, int32_t channel, int64_t start_frame,
                           double frames_per_column, float *min_out, float *max_out,
                           int64_t count);

/* ---- Media pool (per project) ---------------------------------------- */

/* Adds decoded media to the project's pool; the engine takes its own
 * reference (the caller still releases `media`). `source_path` is recorded
 * for saving (may be NULL for generated audio). Adding the same path twice
 * returns the existing id. Not undoable; entries live until project new/load. */
AtriumMediaId atrium_pool_add(AtriumEngine *engine, AtriumMedia *media, const char *source_path);
/* Borrowed pointer, valid until atrium_project_new/load. NULL if the media is
 * offline (file missing when the project was loaded). */
const AtriumMedia *atrium_pool_media(const AtriumEngine *engine, AtriumMediaId id);
/* Copies the source path into `buf`; returns the full length. */
size_t atrium_pool_path(const AtriumEngine *engine, AtriumMediaId id, char *buf, size_t len);

/* ---- Model queries --------------------------------------------------- */

uint64_t atrium_model_revision(const AtriumEngine *engine);
int32_t atrium_track_count(const AtriumEngine *engine);
AtriumTrackId atrium_track_at(const AtriumEngine *engine, int32_t index);

typedef struct {
    AtriumTrackId id;
    char name[128];
    int32_t color;       /* palette index */
    float gain_db;       /* -INFINITY for silence */
    float pan;
    bool muted;
    int32_t clip_count;
} AtriumTrackInfo;
AtriumStatus atrium_track_info(const AtriumEngine *engine, AtriumTrackId track, AtriumTrackInfo *out);

/* Clips of a track in z-order (later = on top; overlapping clips: top wins). */
AtriumClipId atrium_track_clip_at(const AtriumEngine *engine, AtriumTrackId track, int32_t index);

typedef struct {
    AtriumClipId id;
    AtriumTrackId track;
    AtriumMediaId media;
    int64_t start;        /* timeline frame */
    int64_t offset;       /* frame within media */
    int64_t length;       /* frames */
    int64_t media_frames; /* total frames of the source media */
    bool offline;         /* source missing: renders silence */
    char name[128];
} AtriumClipInfo;
AtriumStatus atrium_clip_info(const AtriumEngine *engine, AtriumClipId clip, AtriumClipInfo *out);

/* Timeline length in frames (end of the last clip). */
int64_t atrium_session_length(const AtriumEngine *engine);

/* ---- Edit commands (each is one undo step unless grouped) ------------ */

AtriumTrackId atrium_track_add(AtriumEngine *engine, const char *name);
AtriumStatus atrium_track_remove(AtriumEngine *engine, AtriumTrackId track);
AtriumStatus atrium_track_rename(AtriumEngine *engine, AtriumTrackId track, const char *name);
/* Gain in dB, clamped to +12; <= -96 means silence. Smoothed on the audio thread. */
AtriumStatus atrium_track_set_gain_db(AtriumEngine *engine, AtriumTrackId track, float gain_db);
/* Pan in [-1, 1]. Mono sources: -3 dB-compensated constant power (unity at
 * center). Stereo sources: balance. */
AtriumStatus atrium_track_set_pan(AtriumEngine *engine, AtriumTrackId track, float pan);
AtriumStatus atrium_track_set_mute(AtriumEngine *engine, AtriumTrackId track, bool muted);

/* Places pool media on a track. length <= 0 means "to the end of the media".
 * Returns 0 on failure. */
AtriumClipId atrium_clip_add(AtriumEngine *engine, AtriumTrackId track, AtriumMediaId media,
                             int64_t timeline_start, int64_t source_offset, int64_t length);
AtriumStatus atrium_clip_remove(AtriumEngine *engine, AtriumClipId clip);
/* Moves a clip (optionally to another track) and brings it to the top. */
AtriumStatus atrium_clip_move(AtriumEngine *engine, AtriumClipId clip, AtriumTrackId track,
                              int64_t timeline_start);
/* Sets the clip's timeline start and source region (trim). */
AtriumStatus atrium_clip_set_region(AtriumEngine *engine, AtriumClipId clip, int64_t timeline_start,
                                    int64_t source_offset, int64_t length);
/* Splits at a timeline frame strictly inside the clip; the right part gets a new id. */
AtriumStatus atrium_clip_split(AtriumEngine *engine, AtriumClipId clip, int64_t at_frame,
                               AtriumClipId *right_out);

/* ---- Undo ------------------------------------------------------------ */

bool atrium_undo(AtriumEngine *engine);
bool atrium_redo(AtriumEngine *engine);
bool atrium_can_undo(const AtriumEngine *engine);
bool atrium_can_redo(const AtriumEngine *engine);
/* Name of the step undo/redo would apply (e.g. "Move Clip"); returns full length. */
size_t atrium_undo_name(const AtriumEngine *engine, char *buf, size_t len);
size_t atrium_redo_name(const AtriumEngine *engine, char *buf, size_t len);
/* Everything between begin and end becomes one undo step named `name`
 * (e.g. a mouse drag). Groups nest; only the outermost name is used. */
void atrium_undo_begin_group(AtriumEngine *engine, const char *name);
void atrium_undo_end_group(AtriumEngine *engine);

/* ---- Project --------------------------------------------------------- */

/* Clears the model, pool and undo history. */
void atrium_project_new(AtriumEngine *engine);
/* Writes a versioned JSON project atomically (temp file + rename). Media is
 * referenced by path (absolute and relative to the project file). */
AtriumStatus atrium_project_save(AtriumEngine *engine, const char *path, char *err, size_t err_len);
/* Replaces the current project. Missing media files become offline clips
 * (count reported in `missing_out`, may be NULL). On error the current
 * project is left untouched. */
AtriumStatus atrium_project_load(AtriumEngine *engine, const char *path, int32_t *missing_out,
                                 char *err, size_t err_len);
/* True if the model changed since the last save/load/new. */
bool atrium_project_dirty(const AtriumEngine *engine);

/* ---- Command catalog (scripting / command palette) ------------------- */

/* Runs a named command with JSON arguments (NULL or "" = {}). Writes a JSON
 * result (or {"error": "..."}) to `result`. Returns the command's status. */
AtriumStatus atrium_command_run(AtriumEngine *engine, const char *name, const char *args_json,
                                char *result, size_t result_len);
int32_t atrium_command_count(void);
/* Static strings; valid for the process lifetime. */
bool atrium_command_info(int32_t index, const char **name, const char **title, const char **args_help);

/* ---- Transport ------------------------------------------------------- */

void atrium_transport_play(AtriumEngine *engine);
void atrium_transport_pause(AtriumEngine *engine);
void atrium_transport_seek(AtriumEngine *engine, int64_t frame);
bool atrium_transport_is_playing(const AtriumEngine *engine);   /* [any thread] */
int64_t atrium_transport_position(const AtriumEngine *engine);  /* [any thread] */

/* ---- Offline rendering ----------------------------------------------- */

/* Renders the current model (ignoring the live transport) into caller-provided
 * planar stereo buffers. Deterministic. */
AtriumStatus atrium_render_offline(AtriumEngine *engine, int64_t start_frame, int64_t frames,
                                   float *left, float *right);
/* Renders [start_frame, start_frame+frames) to a WAV file.
 * bits: 16, 24 (integer PCM) or 32 (float). */
AtriumStatus atrium_render_to_wav(AtriumEngine *engine, const char *path, int64_t start_frame,
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
} AtriumStats;

void atrium_engine_stats(const AtriumEngine *engine, AtriumStats *out); /* [any thread] */
void atrium_engine_reset_stats(AtriumEngine *engine);

#ifdef __cplusplus
}
#endif
#endif /* ATRIUM_H */
