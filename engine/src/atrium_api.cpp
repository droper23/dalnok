// C API facade over the C++ engine.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "atrium/atrium.h"
#include "commands.hpp"
#include "engine.hpp"

#include <algorithm>
#include <cstring>

using namespace atrium;

struct AtriumEngine {
    Engine impl;
    explicit AtriumEngine(double sr) : impl(sr) {}
};

namespace {
size_t copyOut(char *buf, size_t len, const std::string &s) {
    if (buf && len > 0) {
        const size_t n = std::min(len - 1, s.size());
        std::memcpy(buf, s.data(), n);
        buf[n] = '\0';
    }
    return s.size();
}
AtriumStatus statusFor(bool ok, const std::string &err) {
    if (ok) return ATRIUM_OK;
    return err.rfind("no such", 0) == 0 ? ATRIUM_ERR_NOT_FOUND : ATRIUM_ERR_INVALID_ARG;
}
} // namespace

extern "C" {

// ---- Lifecycle ----------------------------------------------------------

AtriumEngine *atrium_engine_create(double sample_rate) { return new AtriumEngine(sample_rate); }
void atrium_engine_destroy(AtriumEngine *e) { delete e; }

AtriumStatus atrium_engine_start_device(AtriumEngine *e, char *err, size_t err_len) {
    if (!e) return ATRIUM_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.startDevice(msg)) {
        copyOut(err, err_len, msg);
        return ATRIUM_ERR_DEVICE;
    }
    return ATRIUM_OK;
}
void atrium_engine_stop_device(AtriumEngine *e) {
    if (e) e->impl.stopDevice();
}
bool atrium_engine_device_running(const AtriumEngine *e) { return e && e->impl.deviceRunning(); }
double atrium_engine_sample_rate(const AtriumEngine *e) { return e ? e->impl.sampleRate() : 0; }
void atrium_engine_collect_garbage(AtriumEngine *e) {
    if (e) e->impl.collectGarbage();
}

// ---- Media ----------------------------------------------------------------

AtriumStatus atrium_media_load(const char *path, double sample_rate, AtriumMedia **out, char *err, size_t err_len) {
    if (!path || !out) return ATRIUM_ERR_INVALID_ARG;
    *out = nullptr;
    std::vector<std::vector<float>> ch;
    std::string msg;
    if (!decodeAudioFile(path, sample_rate, ch, msg)) {
        copyOut(err, err_len, msg);
        return ATRIUM_ERR_IO;
    }
    *out = new AtriumMedia{std::make_shared<const Media>(std::move(ch), sample_rate)};
    return ATRIUM_OK;
}

AtriumMedia *atrium_media_from_samples(const float *const *channels, int32_t count, int64_t frames, double sr) {
    if (!channels || count < 1 || count > 2 || frames <= 0 || sr <= 0) return nullptr;
    std::vector<std::vector<float>> ch;
    for (int32_t c = 0; c < count; ++c) ch.emplace_back(channels[c], channels[c] + frames);
    return new AtriumMedia{std::make_shared<const Media>(std::move(ch), sr)};
}

void atrium_media_release(AtriumMedia *m) { delete m; }
int64_t atrium_media_frames(const AtriumMedia *m) { return m && m->impl ? m->impl->frames() : 0; }
int32_t atrium_media_channels(const AtriumMedia *m) { return m && m->impl ? m->impl->channelCount() : 0; }
double atrium_media_sample_rate(const AtriumMedia *m) { return m && m->impl ? m->impl->sampleRate() : 0; }

int64_t atrium_media_peaks(const AtriumMedia *m, int32_t channel, int64_t start, double fpc, float *mins,
                           float *maxs, int64_t count) {
    if (!m || !m->impl || !mins || !maxs) return 0;
    return m->impl->peaks(channel, start, fpc, mins, maxs, count);
}

// ---- Pool -----------------------------------------------------------------

AtriumMediaId atrium_pool_add(AtriumEngine *e, AtriumMedia *m, const char *path) {
    if (!e || !m || !m->impl) return 0;
    return e->impl.poolAdd(m->impl, path ? path : "");
}
const AtriumMedia *atrium_pool_media(const AtriumEngine *e, AtriumMediaId id) {
    if (!e) return nullptr;
    const PoolEntry *pe = e->impl.poolEntry(id);
    return pe && pe->handle->impl ? pe->handle.get() : nullptr;
}
size_t atrium_pool_path(const AtriumEngine *e, AtriumMediaId id, char *buf, size_t len) {
    const PoolEntry *pe = e ? e->impl.poolEntry(id) : nullptr;
    return copyOut(buf, len, pe ? pe->path : "");
}

// ---- Queries --------------------------------------------------------------

uint64_t atrium_model_revision(const AtriumEngine *e) { return e ? e->impl.revision() : 0; }
int32_t atrium_track_count(const AtriumEngine *e) {
    return e ? static_cast<int32_t>(e->impl.model().tracks.size()) : 0;
}
AtriumTrackId atrium_track_at(const AtriumEngine *e, int32_t i) {
    if (!e || i < 0 || i >= atrium_track_count(e)) return 0;
    return e->impl.model().tracks[static_cast<size_t>(i)].id;
}

AtriumStatus atrium_track_info(const AtriumEngine *e, AtriumTrackId id, AtriumTrackInfo *out) {
    if (!e || !out) return ATRIUM_ERR_INVALID_ARG;
    const TrackState *t = e->impl.model().track(id);
    if (!t) return ATRIUM_ERR_NOT_FOUND;
    *out = AtriumTrackInfo{};
    out->id = t->id;
    copyOut(out->name, sizeof out->name, t->name);
    out->color = t->color;
    out->gain_db = t->gainDb;
    out->pan = t->pan;
    out->muted = t->muted;
    for (const auto &c : e->impl.model().clips) out->clip_count += c.track == id;
    return ATRIUM_OK;
}

AtriumClipId atrium_track_clip_at(const AtriumEngine *e, AtriumTrackId track, int32_t index) {
    if (!e || index < 0) return 0;
    int32_t i = 0;
    for (const auto &c : e->impl.model().clips)
        if (c.track == track && i++ == index) return c.id;
    return 0;
}

AtriumStatus atrium_clip_info(const AtriumEngine *e, AtriumClipId id, AtriumClipInfo *out) {
    if (!e || !out) return ATRIUM_ERR_INVALID_ARG;
    const ClipState *c = e->impl.model().clip(id);
    if (!c) return ATRIUM_ERR_NOT_FOUND;
    const PoolEntry *pe = e->impl.poolEntry(c->media);
    *out = AtriumClipInfo{};
    out->id = c->id;
    out->track = c->track;
    out->media = c->media;
    out->start = c->start;
    out->offset = c->offset;
    out->length = c->length;
    out->media_frames = pe ? pe->frames : 0;
    out->offline = !pe || !pe->handle->impl;
    copyOut(out->name, sizeof out->name, c->name);
    return ATRIUM_OK;
}

int64_t atrium_session_length(const AtriumEngine *e) { return e ? e->impl.sessionLength() : 0; }

// ---- Commands ---------------------------------------------------------------

AtriumTrackId atrium_track_add(AtriumEngine *e, const char *name) {
    std::string err;
    return e ? e->impl.addTrack(name ? name : "", err) : 0;
}
AtriumStatus atrium_track_remove(AtriumEngine *e, AtriumTrackId t) {
    std::string err;
    return e ? statusFor(e->impl.removeTrack(t, err), err) : ATRIUM_ERR_INVALID_ARG;
}
AtriumStatus atrium_track_rename(AtriumEngine *e, AtriumTrackId t, const char *name) {
    std::string err;
    return e ? statusFor(e->impl.renameTrack(t, name ? name : "", err), err) : ATRIUM_ERR_INVALID_ARG;
}
AtriumStatus atrium_track_set_gain_db(AtriumEngine *e, AtriumTrackId t, float db) {
    std::string err;
    return e ? statusFor(e->impl.setGainDb(t, db, err), err) : ATRIUM_ERR_INVALID_ARG;
}
AtriumStatus atrium_track_set_pan(AtriumEngine *e, AtriumTrackId t, float pan) {
    std::string err;
    return e ? statusFor(e->impl.setPan(t, pan, err), err) : ATRIUM_ERR_INVALID_ARG;
}
AtriumStatus atrium_track_set_mute(AtriumEngine *e, AtriumTrackId t, bool muted) {
    std::string err;
    return e ? statusFor(e->impl.setMute(t, muted, err), err) : ATRIUM_ERR_INVALID_ARG;
}

AtriumClipId atrium_clip_add(AtriumEngine *e, AtriumTrackId t, AtriumMediaId m, int64_t start, int64_t offset,
                             int64_t length) {
    std::string err;
    return e ? e->impl.addClip(t, m, start, offset, length, err) : 0;
}
AtriumStatus atrium_clip_remove(AtriumEngine *e, AtriumClipId c) {
    std::string err;
    return e ? statusFor(e->impl.removeClip(c, err), err) : ATRIUM_ERR_INVALID_ARG;
}
AtriumStatus atrium_clip_move(AtriumEngine *e, AtriumClipId c, AtriumTrackId t, int64_t start) {
    std::string err;
    return e ? statusFor(e->impl.moveClip(c, t, start, err), err) : ATRIUM_ERR_INVALID_ARG;
}
AtriumStatus atrium_clip_set_region(AtriumEngine *e, AtriumClipId c, int64_t start, int64_t offset, int64_t length) {
    std::string err;
    return e ? statusFor(e->impl.setClipRegion(c, start, offset, length, err), err) : ATRIUM_ERR_INVALID_ARG;
}
AtriumStatus atrium_clip_split(AtriumEngine *e, AtriumClipId c, int64_t at, AtriumClipId *right_out) {
    if (!e) return ATRIUM_ERR_INVALID_ARG;
    std::string err;
    const auto id = e->impl.splitClip(c, at, err);
    if (right_out) *right_out = id;
    return statusFor(id != 0, err);
}

// ---- Undo -------------------------------------------------------------------

bool atrium_undo(AtriumEngine *e) { return e && e->impl.undo(); }
bool atrium_redo(AtriumEngine *e) { return e && e->impl.redo(); }
bool atrium_can_undo(const AtriumEngine *e) { return e && e->impl.canUndo(); }
bool atrium_can_redo(const AtriumEngine *e) { return e && e->impl.canRedo(); }
size_t atrium_undo_name(const AtriumEngine *e, char *buf, size_t len) {
    return copyOut(buf, len, e ? e->impl.undoName() : "");
}
size_t atrium_redo_name(const AtriumEngine *e, char *buf, size_t len) {
    return copyOut(buf, len, e ? e->impl.redoName() : "");
}
void atrium_undo_begin_group(AtriumEngine *e, const char *name) {
    if (e) e->impl.beginGroup(name ? name : "");
}
void atrium_undo_end_group(AtriumEngine *e) {
    if (e) e->impl.endGroup();
}

// ---- Project ----------------------------------------------------------------

void atrium_project_new(AtriumEngine *e) {
    if (e) e->impl.newProject();
}
AtriumStatus atrium_project_save(AtriumEngine *e, const char *path, char *err, size_t err_len) {
    if (!e || !path) return ATRIUM_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.saveProject(path, msg)) {
        copyOut(err, err_len, msg);
        return ATRIUM_ERR_IO;
    }
    return ATRIUM_OK;
}
AtriumStatus atrium_project_load(AtriumEngine *e, const char *path, int32_t *missing_out, char *err,
                                 size_t err_len) {
    if (!e || !path) return ATRIUM_ERR_INVALID_ARG;
    std::string msg;
    int32_t missing = 0;
    if (!e->impl.loadProject(path, missing, msg)) {
        copyOut(err, err_len, msg);
        return msg.rfind("cannot open", 0) == 0 ? ATRIUM_ERR_IO : ATRIUM_ERR_FORMAT;
    }
    if (missing_out) *missing_out = missing;
    return ATRIUM_OK;
}
bool atrium_project_dirty(const AtriumEngine *e) { return e && e->impl.dirty(); }

// ---- Command catalog --------------------------------------------------------

AtriumStatus atrium_command_run(AtriumEngine *e, const char *name, const char *args, char *result, size_t len) {
    if (!e || !name) return ATRIUM_ERR_INVALID_ARG;
    std::string out;
    const auto st = runCommand(e->impl, name, args ? args : "", out);
    copyOut(result, len, out);
    return st;
}
int32_t atrium_command_count(void) {
    int32_t n;
    commandCatalog(n);
    return n;
}
bool atrium_command_info(int32_t index, const char **name, const char **title, const char **args_help) {
    int32_t n;
    const CommandDef *defs = commandCatalog(n);
    if (index < 0 || index >= n) return false;
    if (name) *name = defs[index].name;
    if (title) *title = defs[index].title;
    if (args_help) *args_help = defs[index].args;
    return true;
}

// ---- Transport ----------------------------------------------------------------

void atrium_transport_play(AtriumEngine *e) {
    if (e) e->impl.play();
}
void atrium_transport_pause(AtriumEngine *e) {
    if (e) e->impl.pause();
}
void atrium_transport_seek(AtriumEngine *e, int64_t frame) {
    if (e) e->impl.seek(frame);
}
bool atrium_transport_is_playing(const AtriumEngine *e) { return e && e->impl.playing(); }
int64_t atrium_transport_position(const AtriumEngine *e) { return e ? e->impl.position() : 0; }

// ---- Offline ------------------------------------------------------------------

AtriumStatus atrium_render_offline(AtriumEngine *e, int64_t start, int64_t frames, float *l, float *r) {
    return e && e->impl.renderOffline(start, frames, l, r) ? ATRIUM_OK : ATRIUM_ERR_INVALID_ARG;
}
AtriumStatus atrium_render_to_wav(AtriumEngine *e, const char *path, int64_t start, int64_t frames, int32_t bits,
                                  char *err, size_t err_len) {
    if (!e || !path) return ATRIUM_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.renderToWav(path, start, frames, bits, msg)) {
        copyOut(err, err_len, msg);
        return ATRIUM_ERR_IO;
    }
    return ATRIUM_OK;
}

// ---- Diagnostics --------------------------------------------------------------

void atrium_engine_stats(const AtriumEngine *e, AtriumStats *out) {
    if (e && out) e->impl.stats(*out);
}
void atrium_engine_reset_stats(AtriumEngine *e) {
    if (e) e->impl.resetStats();
}

} // extern "C"
