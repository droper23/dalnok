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
 */
#ifndef ATRIUM_H
#define ATRIUM_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ATRIUM_API_VERSION 1

typedef enum {
    ATRIUM_OK = 0,
    ATRIUM_ERR_INVALID_ARG = 1,
    ATRIUM_ERR_IO = 2,
    ATRIUM_ERR_DEVICE = 3,
    ATRIUM_ERR_NOT_FOUND = 4,
    ATRIUM_ERR_UNSUPPORTED = 5,
} AtriumStatus;

typedef struct AtriumEngine AtriumEngine;
typedef struct AtriumMedia AtriumMedia;
typedef int32_t AtriumTrackId;
typedef int32_t AtriumClipId;

/* ---- Engine lifecycle ------------------------------------------------ */

/* Creates an engine running at `sample_rate` (used for offline work and as
 * the preferred device rate). Pass 0 to adopt the default device's rate. */
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

/* ---- Media (decoded audio) ------------------------------------------- */

/* Decodes an audio file into memory, converting to `sample_rate`.
 * [any thread] — safe to call from a background thread. */
AtriumStatus atrium_media_load(const char *path, double sample_rate,
                               AtriumMedia **out, char *err, size_t err_len);
/* Wraps caller-provided planar float samples (copied). [any thread] */
AtriumMedia *atrium_media_from_samples(const float *const *channels, int32_t channel_count,
                                       int64_t frames, double sample_rate);
void atrium_media_release(AtriumMedia *media);   /* [any thread] */
int64_t atrium_media_frames(const AtriumMedia *media);
int32_t atrium_media_channels(const AtriumMedia *media);
double atrium_media_sample_rate(const AtriumMedia *media);

/* Fills `count` columns of min/max peaks for `channel`, starting at
 * `start_frame`, each column covering `frames_per_column` frames.
 * Columns beyond the media end are 0. Returns columns written. [any thread] */
int64_t atrium_media_peaks(const AtriumMedia *media, int32_t channel, int64_t start_frame,
                           double frames_per_column, float *min_out, float *max_out,
                           int64_t count);

/* ---- Session model --------------------------------------------------- */

AtriumTrackId atrium_track_add(AtriumEngine *engine, const char *name);
AtriumStatus atrium_track_remove(AtriumEngine *engine, AtriumTrackId track);
/* Gain in dB (clamped to [-inf, +12]; values <= -96 mean silence). Lock-free,
 * smoothed on the audio thread. */
AtriumStatus atrium_track_set_gain_db(AtriumEngine *engine, AtriumTrackId track, float gain_db);
/* Pan in [-1, 1]. Mono sources: -3 dB-compensated constant power (unity at
 * center). Stereo sources: balance. */
AtriumStatus atrium_track_set_pan(AtriumEngine *engine, AtriumTrackId track, float pan);
AtriumStatus atrium_track_set_mute(AtriumEngine *engine, AtriumTrackId track, bool muted);

/* Places `media` on `track`. `source_offset`/`length` select a region of the
 * media (length <= 0 means "to the end"). The engine retains `media`. */
AtriumClipId atrium_clip_add(AtriumEngine *engine, AtriumTrackId track, AtriumMedia *media,
                             int64_t timeline_start, int64_t source_offset, int64_t length);
AtriumStatus atrium_clip_remove(AtriumEngine *engine, AtriumClipId clip);

/* Timeline length in frames (end of the last clip). */
int64_t atrium_session_length(const AtriumEngine *engine);

/* ---- Transport ------------------------------------------------------- */

void atrium_transport_play(AtriumEngine *engine);
void atrium_transport_pause(AtriumEngine *engine);
void atrium_transport_seek(AtriumEngine *engine, int64_t frame);
bool atrium_transport_is_playing(const AtriumEngine *engine);   /* [any thread] */
int64_t atrium_transport_position(const AtriumEngine *engine);  /* [any thread] */

/* ---- Offline rendering ----------------------------------------------- */

/* Renders the current session (ignoring the live transport) into
 * caller-provided planar stereo buffers. Deterministic. */
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
