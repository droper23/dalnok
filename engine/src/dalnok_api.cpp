// C API facade over the C++ engine.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "dalnok/dalnok.h"
#include "commands.hpp"
#include "engine.hpp"
#include "import/import.hpp"

#include <algorithm>
#include <cstring>

using namespace dalnok;

struct DalnokEngine {
    Engine impl;
    explicit DalnokEngine(double sr) : impl(sr) {}
};

struct DalnokProjectData {
    std::unique_ptr<Engine::PreparedProject> impl;
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
DalnokStatus statusFor(bool ok, const std::string &err) {
    if (ok) return DALNOK_OK;
    return err.rfind("no such", 0) == 0 ? DALNOK_ERR_NOT_FOUND : DALNOK_ERR_INVALID_ARG;
}
} // namespace

extern "C" {

// ---- Lifecycle ----------------------------------------------------------

DalnokEngine *dalnok_engine_create(double sample_rate) { return new DalnokEngine(sample_rate); }
void dalnok_engine_destroy(DalnokEngine *e) { delete e; }

DalnokStatus dalnok_engine_start_device(DalnokEngine *e, char *err, size_t err_len) {
    if (!e) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.startDevice(msg)) {
        copyOut(err, err_len, msg);
        return DALNOK_ERR_DEVICE;
    }
    return DALNOK_OK;
}
void dalnok_engine_stop_device(DalnokEngine *e) {
    if (e) e->impl.stopDevice();
}
bool dalnok_engine_device_running(const DalnokEngine *e) { return e && e->impl.deviceRunning(); }
double dalnok_engine_sample_rate(const DalnokEngine *e) { return e ? e->impl.sampleRate() : 0; }
void dalnok_engine_collect_garbage(DalnokEngine *e) {
    if (e) e->impl.collectGarbage();
}

// ---- Devices, pump, meters ------------------------------------------------

int32_t dalnok_output_devices(DalnokDeviceInfo *out, int32_t capacity) {
    const auto list = listOutputDevices();
    for (int32_t i = 0; out && i < capacity && i < static_cast<int32_t>(list.size()); ++i) {
        const auto &d = list[static_cast<size_t>(i)];
        out[i] = DalnokDeviceInfo{};
        copyOut(out[i].uid, sizeof out[i].uid, d.uid);
        copyOut(out[i].name, sizeof out[i].name, d.name);
        out[i].sample_rate = d.sampleRate;
        out[i].output_channels = d.outputChannels;
        out[i].is_default = d.isDefault;
    }
    return static_cast<int32_t>(list.size());
}

DalnokStatus dalnok_engine_set_output_device(DalnokEngine *e, const char *uid, char *err, size_t err_len) {
    if (!e) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.setOutputDevice(uid ? uid : "", msg)) {
        copyOut(err, err_len, msg);
        return DALNOK_ERR_DEVICE;
    }
    return DALNOK_OK;
}
size_t dalnok_engine_output_device(const DalnokEngine *e, char *buf, size_t len) {
    return copyOut(buf, len, e ? e->impl.outputDeviceUid() : "");
}
bool dalnok_engine_device_alive(const DalnokEngine *e) { return e && e->impl.deviceAlive(); }
double dalnok_engine_hardware_sample_rate(const DalnokEngine *e) { return e ? e->impl.hardwareSampleRate() : 0; }

DalnokStatus dalnok_engine_pump(DalnokEngine *e, float *l, float *r, int32_t frames) {
    return e && e->impl.pump(l, r, frames) ? DALNOK_OK : DALNOK_ERR_INVALID_ARG;
}

DalnokStatus dalnok_meter_track(DalnokEngine *e, DalnokTrackId t, float *l, float *r) {
    float a = 0, b = 0;
    if (!e || !e->impl.readTrackMeter(t, a, b)) return DALNOK_ERR_NOT_FOUND;
    if (l) *l = a;
    if (r) *r = b;
    return DALNOK_OK;
}
void dalnok_meter_master(DalnokEngine *e, float *l, float *r) {
    float a = 0, b = 0;
    if (e) e->impl.readMasterMeter(a, b);
    if (l) *l = a;
    if (r) *r = b;
}

// ---- Media ----------------------------------------------------------------

DalnokStatus dalnok_media_load(const char *path, double sample_rate, DalnokMedia **out, char *err, size_t err_len) {
    if (!path || !out) return DALNOK_ERR_INVALID_ARG;
    *out = nullptr;
    std::vector<std::vector<float>> ch;
    std::string msg;
    if (!decodeAudioFile(path, sample_rate, ch, msg)) {
        copyOut(err, err_len, msg);
        return DALNOK_ERR_IO;
    }
    *out = new DalnokMedia{std::make_shared<const Media>(std::move(ch), sample_rate)};
    return DALNOK_OK;
}

DalnokMedia *dalnok_media_from_samples(const float *const *channels, int32_t count, int64_t frames, double sr) {
    if (!channels || count < 1 || count > 2 || frames <= 0 || sr <= 0) return nullptr;
    std::vector<std::vector<float>> ch;
    for (int32_t c = 0; c < count; ++c) ch.emplace_back(channels[c], channels[c] + frames);
    return new DalnokMedia{std::make_shared<const Media>(std::move(ch), sr)};
}

void dalnok_media_release(DalnokMedia *m) { delete m; }
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
int32_t dalnok_track_count(const DalnokEngine *e) {
    return e ? static_cast<int32_t>(e->impl.model().tracks.size()) : 0;
}
DalnokTrackId dalnok_track_at(const DalnokEngine *e, int32_t i) {
    if (!e || i < 0 || i >= dalnok_track_count(e)) return 0;
    return e->impl.model().tracks[static_cast<size_t>(i)].id;
}

DalnokStatus dalnok_track_info(const DalnokEngine *e, DalnokTrackId id, DalnokTrackInfo *out) {
    if (!e || !out) return DALNOK_ERR_INVALID_ARG;
    const TrackState *t = e->impl.model().track(id);
    if (!t) return DALNOK_ERR_NOT_FOUND;
    *out = DalnokTrackInfo{};
    out->id = t->id;
    copyOut(out->name, sizeof out->name, t->name);
    out->color = t->color;
    out->custom_color = t->customColor;
    out->gain_db = t->gainDb;
    out->pan = t->pan;
    out->muted = t->muted;
    out->solo = t->solo;
    for (const auto &c : e->impl.model().clips) out->clip_count += c.track == id;
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
    const PoolEntry *pe = e->impl.poolEntry(c->media);
    *out = DalnokClipInfo{};
    out->id = c->id;
    out->track = c->track;
    out->media = c->media;
    out->start = c->start;
    out->offset = c->offset;
    out->length = c->length;
    out->media_frames = pe ? pe->frames : 0;
    out->offline = !pe || !pe->handle->impl;
    out->fade_in = c->fadeIn;
    out->fade_out = c->fadeOut;
    out->fade_curve = c->fadeCurve;
    out->gain_db = c->gainDb;
    out->rate = c->rate;
    out->pitch = c->pitch;
    out->preserve_pitch = c->preservePitch;
    out->processing = e->impl.clipProcessing(*c);
    copyOut(out->name, sizeof out->name, c->name);
    return DALNOK_OK;
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
DalnokStatus dalnok_project_save(DalnokEngine *e, const char *path, char *err, size_t err_len) {
    if (!e || !path) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.saveProject(path, msg)) {
        copyOut(err, err_len, msg);
        return DALNOK_ERR_IO;
    }
    return DALNOK_OK;
}
DalnokStatus dalnok_project_save_snapshot(DalnokEngine *e, const char *path, char *err, size_t err_len) {
    if (!e || !path) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.saveProject(path, msg, false, false)) {
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
        return msg.rfind("cannot open", 0) == 0 ? DALNOK_ERR_IO : DALNOK_ERR_FORMAT;
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
    auto p = Engine::prepareProject(path, sr, missing, msg);
    if (!p) {
        copyOut(err, err_len, msg);
        return msg.rfind("cannot open", 0) == 0 ? DALNOK_ERR_IO : DALNOK_ERR_FORMAT;
    }
    if (missing_out) *missing_out = missing;
    *out = new DalnokProjectData{std::move(p)};
    return DALNOK_OK;
}
DalnokStatus dalnok_project_apply(DalnokEngine *e, DalnokProjectData *data) {
    std::unique_ptr<DalnokProjectData> owned(data);
    if (!e || !data || !data->impl) return DALNOK_ERR_INVALID_ARG;
    if (data->impl->sampleRate != e->impl.sampleRate()) return DALNOK_ERR_INVALID_ARG;
    e->impl.applyProject(std::move(data->impl));
    return DALNOK_OK;
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

// ---- Command catalog --------------------------------------------------------

DalnokStatus dalnok_command_run(DalnokEngine *e, const char *name, const char *args, char *result, size_t len) {
    if (!e || !name) return DALNOK_ERR_INVALID_ARG;
    std::string out;
    const auto st = runCommand(e->impl, name, args ? args : "", out);
    copyOut(result, len, out);
    return st;
}
int32_t dalnok_command_count(void) {
    int32_t n;
    commandCatalog(n);
    return n;
}
bool dalnok_command_info(int32_t index, const char **name, const char **title, const char **args_help) {
    int32_t n;
    const CommandDef *defs = commandCatalog(n);
    if (index < 0 || index >= n) return false;
    if (name) *name = defs[index].name;
    if (title) *title = defs[index].title;
    if (args_help) *args_help = defs[index].args;
    return true;
}

// ---- Transport ----------------------------------------------------------------

void dalnok_transport_play(DalnokEngine *e) {
    if (e) e->impl.play();
}
void dalnok_transport_pause(DalnokEngine *e) {
    if (e) e->impl.pause();
}
void dalnok_transport_seek(DalnokEngine *e, int64_t frame) {
    if (e) e->impl.seek(frame);
}
bool dalnok_transport_is_playing(const DalnokEngine *e) { return e && e->impl.playing(); }
int64_t dalnok_transport_position(const DalnokEngine *e) { return e ? e->impl.position() : 0; }

// ---- Offline ------------------------------------------------------------------

DalnokStatus dalnok_render_offline(DalnokEngine *e, int64_t start, int64_t frames, float *l, float *r) {
    return e && e->impl.renderOffline(start, frames, l, r) ? DALNOK_OK : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_render_to_wav(DalnokEngine *e, const char *path, int64_t start, int64_t frames, int32_t bits,
                                  char *err, size_t err_len) {
    if (!e || !path) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.renderToWav(path, start, frames, bits, msg)) {
        copyOut(err, err_len, msg);
        return DALNOK_ERR_IO;
    }
    return DALNOK_OK;
}

// ---- Diagnostics --------------------------------------------------------------

void dalnok_engine_stats(const DalnokEngine *e, DalnokStats *out) {
    if (e && out) e->impl.stats(*out);
}
void dalnok_engine_reset_stats(DalnokEngine *e) {
    if (e) e->impl.resetStats();
}

} // extern "C"
