// C API: media, pool, queries, edit commands, undo and project files (split from dalnok_api.cpp, A-06).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "vec.hpp"
#include "dalnok/dalnok.h"
#include "dalnok_api_internal.hpp"
#include "commands.hpp"
#include "capture_recovery.hpp"
#include "engine.hpp"
#include "stream_cache.hpp"
#include "fx/builtin.hpp"
#include "midi.hpp"
#include "record.hpp"
#include "plugins.hpp"
#include "import/import.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>


extern "C" {

// ---- Media ----------------------------------------------------------------

DalnokStatus dalnok_media_load(const char *path, double sample_rate, DalnokMedia **out, char *err, size_t err_len) {
    if (!path || !out) return DALNOK_ERR_INVALID_ARG;
    *out = nullptr;
    std::string msg;
    auto media = Media::loadFile(path, sample_rate, msg); // long files stream from a cache file (A-09)
    if (!media) {
        copyOut(err, err_len, msg);
        return DALNOK_ERR_IO;
    }
    *out = new DalnokMedia{std::move(media)};
    return DALNOK_OK;
}

DalnokMedia *dalnok_media_from_samples(const float *const *channels, int32_t count, int64_t frames, double sr) {
    if (!channels || count < 1 || count > 2 || frames <= 0 || sr <= 0) return nullptr;
    std::vector<std::vector<float>> ch;
    for (int32_t c = 0; c < count; ++c) ch.emplace_back(channels[c], channels[c] + frames);
    return new DalnokMedia{std::make_shared<const Media>(std::move(ch), sr)};
}

void dalnok_media_release(DalnokMedia *m) { delete m; }
void dalnok_stream_set_limits(double seconds, int32_t mb) { dalnok::StreamCache::shared().setLimits(seconds, mb); }
void dalnok_stream_stats(DalnokStreamStats *out) {
    if (!out) return;
    const auto s = dalnok::StreamCache::shared().stats();
    *out = DalnokStreamStats{s.residentBytes, s.budgetBytes, s.blocksLoaded, s.blocksEvicted, s.missedFrames, s.residentBlocks};
}
bool dalnok_media_streamed(const DalnokMedia *m) { return m && m->impl && m->impl->streamed(); }
int64_t dalnok_media_frames(const DalnokMedia *m) { return m && m->impl ? m->impl->frames() : 0; }
int32_t dalnok_media_channels(const DalnokMedia *m) { return m && m->impl ? m->impl->channelCount() : 0; }
double dalnok_media_sample_rate(const DalnokMedia *m) { return m && m->impl ? m->impl->sampleRate() : 0; }

int64_t dalnok_media_peaks(const DalnokMedia *m, int32_t channel, int64_t start, double fpc, float *mins,
                           float *maxs, int64_t count) {
    if (!m || !m->impl || !mins || !maxs) return 0;
    return m->impl->peaks(channel, start, fpc, mins, maxs, count);
}

// ---- Pool -----------------------------------------------------------------

DalnokMediaId dalnok_pool_add(DalnokEngine *e, DalnokMedia *m, const char *path) {
    if (!e || !m || !m->impl) return 0;
    return e->impl.poolAdd(m->impl, path ? path : "");
}
const DalnokMedia *dalnok_pool_media(const DalnokEngine *e, DalnokMediaId id) {
    if (!e) return nullptr;
    const PoolEntry *pe = e->impl.poolEntry(id);
    return pe && pe->handle->impl ? pe->handle.get() : nullptr;
}
DalnokStatus dalnok_pool_relink(DalnokEngine *e, DalnokMediaId id, DalnokMedia *m, const char *path, char *err,
                                size_t err_len) {
    if (!e || !m || !m->impl) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.poolRelink(id, m->impl, path ? path : "", msg)) {
        copyOut(err, err_len, msg);
        return DALNOK_ERR_NOT_FOUND;
    }
    return DALNOK_OK;
}
size_t dalnok_pool_path(const DalnokEngine *e, DalnokMediaId id, char *buf, size_t len) {
    const PoolEntry *pe = e ? e->impl.poolEntry(id) : nullptr;
    return copyOut(buf, len, pe ? pe->path : "");
}

// ---- Queries --------------------------------------------------------------

uint64_t dalnok_model_revision(const DalnokEngine *e) { return e ? e->impl.revision() : 0; }
uint64_t dalnok_track_revision(const DalnokEngine *e, DalnokTrackId t) { return e ? e->impl.trackRevision(t) : 0; }
bool dalnok_model_only_parameters_since(const DalnokEngine *e, uint64_t revision) {
    return e && e->impl.onlyParametersSince(revision);
}
DalnokStatus dalnok_track_parameters(const DalnokEngine *e, DalnokTrackId id, float *gain, float *pan, bool *muted, bool *solo) {
    if (!e || !gain || !pan || !muted || !solo) return DALNOK_ERR_INVALID_ARG;
    const TrackState *t = e->impl.model().track(id);
    if (!t) return DALNOK_ERR_NOT_FOUND;
    *gain = t->gainDb; *pan = t->pan; *muted = t->muted; *solo = t->solo;
    return DALNOK_OK;
}
int32_t dalnok_track_count(const DalnokEngine *e) {
    return e ? static_cast<int32_t>(e->impl.model().tracks.size()) : 0;
}
DalnokTrackId dalnok_track_at(const DalnokEngine *e, int32_t i) {
    if (!e || i < 0 || i >= dalnok_track_count(e)) return 0;
    return e->impl.model().tracks[static_cast<size_t>(i)].id;
}

namespace {
int32_t clipCount(const Model &m, DalnokTrackId track) {
    int32_t n = 0;
    for (const auto &c : m.clips) n += c.track == track;
    return n;
}
void fillTrackInfo(const Model &m, const TrackState *t, DalnokTrackInfo *out) {
#include "generated/DalnokTrackInfo.inc"
}
void fillClipInfo(const Engine &impl, const ClipState *c, DalnokClipInfo *out) {
    const PoolEntry *pe = impl.poolEntry(c->media);
#include "generated/DalnokClipInfo.inc"
}
} // namespace

DalnokStatus dalnok_track_info(const DalnokEngine *e, DalnokTrackId id, DalnokTrackInfo *out) {
    if (!e || !out) return DALNOK_ERR_INVALID_ARG;
    const TrackState *t = e->impl.model().track(id);
    if (!t) return DALNOK_ERR_NOT_FOUND;
    fillTrackInfo(e->impl.model(), t, out);
    return DALNOK_OK;
}

DalnokClipId dalnok_track_clip_at(const DalnokEngine *e, DalnokTrackId track, int32_t index) {
    if (!e || index < 0) return 0;
    int32_t i = 0;
    for (const auto &c : e->impl.model().clips)
        if (c.track == track && i++ == index) return c.id;
    return 0;
}

DalnokStatus dalnok_clip_info(const DalnokEngine *e, DalnokClipId id, DalnokClipInfo *out) {
    if (!e || !out) return DALNOK_ERR_INVALID_ARG;
    const ClipState *c = e->impl.model().clip(id);
    if (!c) return DALNOK_ERR_NOT_FOUND;
    fillClipInfo(e->impl, c, out);
    return DALNOK_OK;
}

int32_t dalnok_track_clips(const DalnokEngine *e, DalnokTrackId track, DalnokClipInfo *out, int32_t capacity) {
    if (!e || !e->impl.model().track(track)) return -1;
    int32_t n = 0;
    for (const auto &c : e->impl.model().clips) {
        if (c.track != track) continue;
        if (out && n < capacity) fillClipInfo(e->impl, &c, &out[n]);
        ++n;
    }
    return n;
}

int64_t dalnok_session_length(const DalnokEngine *e) { return e ? e->impl.sessionLength() : 0; }

// ---- Commands ---------------------------------------------------------------

DalnokTrackId dalnok_track_add(DalnokEngine *e, const char *name) {
    std::string err;
    return e ? e->impl.addTrack(name ? name : "", err) : 0;
}
DalnokStatus dalnok_track_remove(DalnokEngine *e, DalnokTrackId t) {
    std::string err;
    return e ? statusFor(e->impl.removeTrack(t, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_track_rename(DalnokEngine *e, DalnokTrackId t, const char *name) {
    std::string err;
    return e ? statusFor(e->impl.renameTrack(t, name ? name : "", err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_track_set_gain_db(DalnokEngine *e, DalnokTrackId t, float db) {
    std::string err;
    return e ? statusFor(e->impl.setGainDb(t, db, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_track_set_pan(DalnokEngine *e, DalnokTrackId t, float pan) {
    std::string err;
    return e ? statusFor(e->impl.setPan(t, pan, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_track_set_mute(DalnokEngine *e, DalnokTrackId t, bool muted) {
    std::string err;
    return e ? statusFor(e->impl.setMute(t, muted, err), err) : DALNOK_ERR_INVALID_ARG;
}

DalnokStatus dalnok_track_set_color(DalnokEngine *e, DalnokTrackId t, int32_t rgb) {
    std::string err;
    return e ? statusFor(e->impl.setTrackColor(t, rgb, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_tracks_recolor_gradient(DalnokEngine *e) {
    std::string err;
    return e ? statusFor(e->impl.recolorAsGradient(err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_track_set_solo(DalnokEngine *e, DalnokTrackId t, bool solo) {
    std::string err;
    return e ? statusFor(e->impl.setSolo(t, solo, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_track_move(DalnokEngine *e, DalnokTrackId t, int32_t index) {
    std::string err;
    return e ? statusFor(e->impl.moveTrack(t, index, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_clip_set_fades(DalnokEngine *e, DalnokClipId c, int64_t in, int64_t out, DalnokFadeCurve curve) {
    std::string err;
    return e ? statusFor(e->impl.setClipFades(c, in, out, static_cast<int32_t>(curve), err), err) : DALNOK_ERR_INVALID_ARG;
}

DalnokStatus dalnok_clip_set_stretch(DalnokEngine *e, DalnokClipId c, int64_t length, double rate, float semi, bool pp) {
    std::string err;
    return e ? statusFor(e->impl.setClipStretch(c, length, rate, semi, pp, err), err) : DALNOK_ERR_INVALID_ARG;
}
int32_t dalnok_engine_poll_jobs(DalnokEngine *e) {
    if (!e) return 0;
    e->impl.pollJobs();
    return e->impl.pendingJobs();
}

DalnokStatus dalnok_clip_set_muted(DalnokEngine *e, DalnokClipId c, bool muted) {
    std::string err;
    return e ? statusFor(e->impl.setClipMuted(c, muted, err), err) : DALNOK_ERR_INVALID_ARG;
}
bool dalnok_clip_muted(const DalnokEngine *e, DalnokClipId c) {
    const ClipState *clip = e ? e->impl.model().clip(c) : nullptr;
    return clip && clip->muted;
}

DalnokStatus dalnok_clip_set_gain_db(DalnokEngine *e, DalnokClipId c, float db) {
    std::string err;
    return e ? statusFor(e->impl.setClipGain(c, db, err), err) : DALNOK_ERR_INVALID_ARG;
}

DalnokClipId dalnok_clip_add(DalnokEngine *e, DalnokTrackId t, DalnokMediaId m, int64_t start, int64_t offset,
                             int64_t length) {
    std::string err;
    return e ? e->impl.addClip(t, m, start, offset, length, err) : 0;
}
DalnokStatus dalnok_clip_remove(DalnokEngine *e, DalnokClipId c) {
    std::string err;
    return e ? statusFor(e->impl.removeClip(c, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_clip_move(DalnokEngine *e, DalnokClipId c, DalnokTrackId t, int64_t start) {
    std::string err;
    return e ? statusFor(e->impl.moveClip(c, t, start, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_clips_nudge(DalnokEngine *e, const DalnokClipId *clips, int32_t count, int64_t delta) {
    if (!e || !clips || count <= 0) return DALNOK_ERR_INVALID_ARG;
    std::string err;
    return statusFor(e->impl.nudgeClips(std::vector<DalnokClipId>(clips, clips + count), delta, err), err);
}
int32_t dalnok_clips_copy(DalnokEngine *e, const DalnokClipId *clips, int32_t count, int64_t start, int32_t track_shift,
                          DalnokClipId *out, int32_t capacity) {
    if (!e || !clips || count <= 0) return 0;
    std::string err;
    auto ids = e->impl.copyClips(std::vector<DalnokClipId>(clips, clips + count), start, track_shift, err);
    for (int32_t i = 0; out && i < capacity && i < static_cast<int32_t>(ids.size()); ++i) out[i] = ids[static_cast<size_t>(i)];
    return static_cast<int32_t>(ids.size());
}
DalnokStatus dalnok_clipboard_copy(DalnokEngine *e, const DalnokClipId *clips, int32_t count) {
    if (!e || !clips || count <= 0) return DALNOK_ERR_INVALID_ARG;
    std::string err;
    return statusFor(e->impl.copyToClipboard(std::vector<DalnokClipId>(clips, clips + count), err), err);
}
int32_t dalnok_clipboard_count(const DalnokEngine *e) { return e ? static_cast<int32_t>(e->impl.clipboardCount()) : 0; }
int32_t dalnok_clipboard_paste(DalnokEngine *e, DalnokTrackId track, int64_t start, DalnokClipId *out, int32_t capacity) {
    if (!e) return 0;
    std::string err;
    auto ids = e->impl.pasteClipboard(track, start, err);
    for (int32_t i = 0; out && i < capacity && i < static_cast<int32_t>(ids.size()); ++i) out[i] = ids[static_cast<size_t>(i)];
    return static_cast<int32_t>(ids.size());
}
DalnokStatus dalnok_clips_remove(DalnokEngine *e, const DalnokClipId *clips, int32_t count) {
    if (!e || !clips || count <= 0) return DALNOK_ERR_INVALID_ARG;
    std::string err;
    return statusFor(e->impl.removeClips(std::vector<DalnokClipId>(clips, clips + count), err), err);
}
DalnokStatus dalnok_clip_set_region(DalnokEngine *e, DalnokClipId c, int64_t start, int64_t offset, int64_t length) {
    std::string err;
    return e ? statusFor(e->impl.setClipRegion(c, start, offset, length, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_clip_split(DalnokEngine *e, DalnokClipId c, int64_t at, DalnokClipId *right_out) {
    if (!e) return DALNOK_ERR_INVALID_ARG;
    std::string err;
    const auto id = e->impl.splitClip(c, at, err);
    if (right_out) *right_out = id;
    return statusFor(id != 0, err);
}

// ---- Undo -------------------------------------------------------------------

bool dalnok_undo(DalnokEngine *e) { return e && e->impl.undo(); }
bool dalnok_redo(DalnokEngine *e) { return e && e->impl.redo(); }
bool dalnok_can_undo(const DalnokEngine *e) { return e && e->impl.canUndo(); }
bool dalnok_can_redo(const DalnokEngine *e) { return e && e->impl.canRedo(); }
size_t dalnok_undo_name(const DalnokEngine *e, char *buf, size_t len) {
    return copyOut(buf, len, e ? e->impl.undoName() : "");
}
size_t dalnok_redo_name(const DalnokEngine *e, char *buf, size_t len) {
    return copyOut(buf, len, e ? e->impl.redoName() : "");
}
void dalnok_undo_begin_group(DalnokEngine *e, const char *name) {
    if (e) e->impl.beginGroup(name ? name : "");
}
void dalnok_undo_end_group(DalnokEngine *e) {
    if (e) e->impl.endGroup();
}

DalnokStatus dalnok_capture_recover_wav(const char *spool, const char *output, uint64_t *frames_out,
                                        uint32_t *trailing_bytes_out, char *err, size_t err_len) {
    if (frames_out) *frames_out = 0;
    if (trailing_bytes_out) *trailing_bytes_out = 0;
    if (!spool || !output) return DALNOK_ERR_INVALID_ARG;
    uint64_t frames = 0; uint32_t trailing = 0; std::string message;
    if (!recoverCapture(spool, output, frames, trailing, message)) {
        copyOut(err, err_len, message);
        return DALNOK_ERR_IO;
    }
    if (frames_out) *frames_out = frames;
    if (trailing_bytes_out) *trailing_bytes_out = trailing;
    return DALNOK_OK;
}

// ---- Project ----------------------------------------------------------------

DalnokStatus dalnok_project_save_copying(DalnokEngine *e, const char *path, bool copy_media, char *err,
                                         size_t err_len) {
    if (!e || !path) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.saveProject(path, msg, copy_media)) {
        copyOut(err, err_len, msg);
        return DALNOK_ERR_IO;
    }
    return DALNOK_OK;
}
void dalnok_project_new(DalnokEngine *e) {
    if (e) e->impl.newProject();
}
void dalnok_debug_set_scalar_mix(bool scalar) { dalnok::vec::setScalar(scalar); }
int32_t dalnok_project_format_version(void) { return dalnok::projectFormatVersion(); }
DalnokStatus dalnok_project_save(DalnokEngine *e, const char *path, char *err, size_t err_len) {
    if (!e || !path) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.saveProject(path, msg)) {
        copyOut(err, err_len, msg);
        return DALNOK_ERR_IO;
    }
    return DALNOK_OK;
}
DalnokStatus dalnok_project_export_dawproject(DalnokEngine *e, const char *path, char *notes, size_t notes_len, char *err,
                                              size_t err_len) {
    if (!e || !path) return DALNOK_ERR_INVALID_ARG;
    std::string msg, text;
    std::vector<std::string> lines;
    const bool ok = e->impl.exportDawproject(path, lines, msg);
    for (const auto &l : lines) text += l + "\n";
    copyOut(notes, notes_len, text);
    if (!ok) { copyOut(err, err_len, msg); return DALNOK_ERR_IO; }
    return DALNOK_OK;
}
DalnokStatus dalnok_project_save_snapshot(DalnokEngine *e, const char *path, char *err, size_t err_len) {
    if (!e || !path) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    e->impl.savingRecoverySnapshot_ = true;
    const bool saved = e->impl.saveProject(path, msg, false, false);
    e->impl.savingRecoverySnapshot_ = false;
    if (!saved) {
        copyOut(err, err_len, msg);
        return DALNOK_ERR_IO;
    }
    return DALNOK_OK;
}
DalnokStatus dalnok_project_load(DalnokEngine *e, const char *path, int32_t *missing_out, char *err,
                                 size_t err_len) {
    if (!e || !path) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    int32_t missing = 0;
    if (!e->impl.loadProject(path, missing, msg)) {
        copyOut(err, err_len, msg);
        return msg.rfind("cannot open", 0) == 0 || msg == "cannot write pre-load recovery snapshot"
                   ? DALNOK_ERR_IO : DALNOK_ERR_FORMAT;
    }
    if (missing_out) *missing_out = missing;
    return DALNOK_OK;
}
bool dalnok_project_dirty(const DalnokEngine *e) { return e && e->impl.dirty(); }

DalnokStatus dalnok_project_prepare(const char *path, double sr, DalnokProjectData **out, int32_t *missing_out,
                                    char *err, size_t err_len) {
    if (!path || !out || !(sr > 0)) return DALNOK_ERR_INVALID_ARG;
    *out = nullptr;
    std::string msg;
    int32_t missing = 0;
    std::unique_ptr<Engine::PreparedProject> p;
    try { // untrusted file: nothing may throw across the C API (audit A-10)
        p = Engine::prepareProject(path, sr, missing, msg);
    } catch (const std::exception &x) {
        msg = std::string("project file is damaged (") + x.what() + ")";
    } catch (...) {
        msg = "project file is damaged";
    }
    if (!p) {
        copyOut(err, err_len, msg);
        return msg.rfind("cannot open", 0) == 0 ? DALNOK_ERR_IO : DALNOK_ERR_FORMAT;
    }
    if (missing_out) *missing_out = missing;
    *out = new DalnokProjectData{std::move(p)};
    return DALNOK_OK;
}
void dalnok_project_set_recovery_directory(DalnokEngine *e, const char *path) {
    if (e) e->impl.setRecoveryDirectory(path ? path : "");
}
DalnokStatus dalnok_project_apply(DalnokEngine *e, DalnokProjectData *data) {
    std::unique_ptr<DalnokProjectData> owned(data);
    if (!e || !data || !data->impl) return DALNOK_ERR_INVALID_ARG;
    if (data->impl->sampleRate != e->impl.sampleRate()) return DALNOK_ERR_INVALID_ARG;
    return e->impl.applyProject(std::move(data->impl)) ? DALNOK_OK : DALNOK_ERR_IO;
}
DalnokStatus dalnok_project_apply_recovery(DalnokEngine *e, DalnokProjectData *data) {
    std::unique_ptr<DalnokProjectData> owned(data);
    if (!e || !data || !data->impl) return DALNOK_ERR_INVALID_ARG;
    if (data->impl->sampleRate != e->impl.sampleRate()) return DALNOK_ERR_INVALID_ARG;
    return e->impl.applyProject(std::move(data->impl), Engine::ApplyMode::recover) ? DALNOK_OK : DALNOK_ERR_IO;
}
DalnokStatus dalnok_project_apply_deferred(DalnokEngine *e, DalnokProjectData *data) {
    std::unique_ptr<DalnokProjectData> owned(data);
    if (!e || !data || !data->impl) return DALNOK_ERR_INVALID_ARG;
    if (data->impl->sampleRate != e->impl.sampleRate()) return DALNOK_ERR_INVALID_ARG;
    return e->impl.applyProject(std::move(data->impl), Engine::ApplyMode::defer) ? DALNOK_OK : DALNOK_ERR_IO;
}
int32_t dalnok_plugins_pending(const DalnokEngine *e) { return e ? e->impl.pendingPluginCount() : 0; }
int32_t dalnok_plugins_activate_next(DalnokEngine *e, int32_t *slot_out, double *seconds_out) {
    if (!e) return -1;
    int32_t slot = 0;
    double seconds = 0;
    const int32_t left = e->impl.activateNextPlugin(slot, seconds);
    if (slot_out) *slot_out = slot;
    if (seconds_out) *seconds_out = seconds;
    return left;
}
void dalnok_plugins_set_host(DalnokEngine *e, const char *host) {
    if (e) e->impl.setPluginHost(host ? host : "");
}
void dalnok_plugins_cancel_pending(DalnokEngine *e) {
    if (e) e->impl.cancelPendingPlugins();
}
DalnokStatus dalnok_plugin_reload(DalnokEngine *e, int32_t slot, char *err, size_t err_len) {
    if (!e) return DALNOK_ERR_INVALID_ARG;
    std::string why;
    if (e->impl.reloadPlugin(slot, why)) return DALNOK_OK;
    copyOut(err, err_len, why);
    return why == "no such plug-in slot" ? DALNOK_ERR_NOT_FOUND : DALNOK_ERR_UNSUPPORTED;
}
void dalnok_project_data_release(DalnokProjectData *data) { delete data; }

DalnokStatus dalnok_project_import_report(const char *path, char *report, size_t report_len, char *err, size_t err_len) {
    if (!path) return DALNOK_ERR_INVALID_ARG;
    dalnok::import::Result r;
    std::string msg;
    if (!dalnok::import::importProject(path, r, msg)) {
        copyOut(err, err_len, msg);
        return msg.rfind("cannot open", 0) == 0 ? DALNOK_ERR_IO : DALNOK_ERR_FORMAT;
    }
    copyOut(report, report_len, json::serialize(r.report.toJson(), true));
    return DALNOK_OK;
}

DalnokStatus dalnok_project_import(const char *path, double sr, DalnokProjectData **out, int32_t *missing_out,
                                   char *report, size_t report_len, char *err, size_t err_len) {
    if (!path || !out || !(sr > 0)) return DALNOK_ERR_INVALID_ARG;
    *out = nullptr;
    std::string msg, rep;
    int32_t missing = 0;
    auto p = Engine::prepareImport(path, sr, missing, rep, msg);
    if (!p) {
        copyOut(err, err_len, msg);
        return msg.rfind("cannot open", 0) == 0 ? DALNOK_ERR_IO
             : msg.rfind("unsupported", 0) == 0 || msg.find("not implemented") != std::string::npos ? DALNOK_ERR_UNSUPPORTED
                                                                                                    : DALNOK_ERR_FORMAT;
    }
    copyOut(report, report_len, rep);
    if (missing_out) *missing_out = missing;
    *out = new DalnokProjectData{std::move(p)};
    return DALNOK_OK;
}

} // extern "C"
