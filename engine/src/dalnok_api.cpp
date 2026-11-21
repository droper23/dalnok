// C API facade over the C++ engine.
// SPDX-License-Identifier: GPL-3.0-or-later
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

using namespace dalnok;

namespace {
// Built-in plug-ins (ADR-0011) are part of the engine: listed with every scan and always valid.
json::Value withBuiltins(json::Value list, bool validated) {
    for (const auto &b : builtinPlugins()) {
        json::Value v = json::Value::makeObject();
        v.set("format", "dalnok");
        v.set("name", b.name);
        v.set("vendor", "Dalnok");
        v.set("version", "1");
        v.set("kind", "effect");
        v.set("path", b.id);
        json::Value cats = json::Value::makeArray();
        cats.push(json::Value(b.category));
        v.set("categories", std::move(cats));
        if (validated) {
            json::Value scan = json::Value::makeObject();
            scan.set("status", "ok");
            scan.set("cached", false);
            v.set("scan", std::move(scan));
        }
        list.push(std::move(v));
    }
    return list;
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

int32_t dalnok_input_devices(DalnokInputDeviceInfo *out, int32_t capacity) {
    const auto list = listInputDevices();
    for (int32_t i = 0; out && i < capacity && i < static_cast<int32_t>(list.size()); ++i) {
        const auto &d = list[static_cast<size_t>(i)];
        out[i] = DalnokInputDeviceInfo{};
        copyOut(out[i].uid, sizeof out[i].uid, d.uid);
        copyOut(out[i].name, sizeof out[i].name, d.name);
        out[i].sample_rate = d.sampleRate;
        out[i].input_channels = d.inputChannels;
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

int32_t dalnok_midi_sources(DalnokMidiSourceInfo *out, int32_t capacity) {
    const auto list = listMidiSources();
    for (int32_t i = 0; out && i < capacity && i < static_cast<int32_t>(list.size()); ++i) {
        const auto &source = list[static_cast<size_t>(i)];
        out[i] = DalnokMidiSourceInfo{};
        out[i].unique_id = source.uniqueId;
        copyOut(out[i].name, sizeof out[i].name, source.name);
    }
    return static_cast<int32_t>(list.size());
}

DalnokStatus dalnok_capture_start(DalnokEngine *e, const char *uid, int32_t channel, const char *path,
                                  char *err, size_t err_len) {
    if (!e || !uid || !path || channel < 0) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.startCapture(uid, channel, path, msg)) { copyOut(err, err_len, msg); return DALNOK_ERR_DEVICE; }
    return DALNOK_OK;
}
DalnokStatus dalnok_capture_stop(DalnokEngine *e, DalnokCaptureStats *stats, char *err, size_t err_len) {
    if (!e) return DALNOK_ERR_INVALID_ARG;
    DalnokCaptureStats result{}; std::string msg;
    const bool ok = e->impl.stopCapture(result, msg);
    if (stats) *stats = result;
    if (!ok) { copyOut(err, err_len, msg); return DALNOK_ERR_DEVICE; }
    return DALNOK_OK;
}
bool dalnok_capture_active(const DalnokEngine *e) { return e && e->impl.captureActive(); }
DalnokStatus dalnok_capture_status(const DalnokEngine *e, DalnokCaptureStats *stats) {
    if (!e || !stats) return DALNOK_ERR_INVALID_ARG;
    return e->impl.captureStatus(*stats) ? DALNOK_OK : DALNOK_ERR_DEVICE;
}

DalnokStatus dalnok_record_start(DalnokEngine *e, const char *uid, const char *dir, char *err, size_t err_len) {
    if (!e) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.startRecording(uid ? uid : "", dir ? dir : "", msg)) {
        copyOut(err, err_len, msg);
        return e->impl.captureActive() ? DALNOK_ERR_INVALID_ARG : DALNOK_ERR_DEVICE;
    }
    return DALNOK_OK;
}
DalnokStatus dalnok_record_stop(DalnokEngine *e, DalnokRecordResult *out, char *err, size_t err_len) {
    if (!e) return DALNOK_ERR_INVALID_ARG;
    Engine::RecordResult r;
    std::string msg;
    const bool ok = e->impl.stopRecording(r, msg);
    if (out) {
        *out = DalnokRecordResult{};
        out->audio_clip = r.audioClip;
        out->audio_clip_count = 0;
        out->take_folder_count = 0;
        for (int32_t f : r.takeFolders)
            if (out->take_folder_count < 64) out->take_folders[out->take_folder_count++] = f;
        for (DalnokClipId c : r.audioClips)
            if (out->audio_clip_count < 64) out->audio_clips[out->audio_clip_count++] = c;
        out->midi_clip = r.midiClip;
        out->media = r.media;
        out->frames = r.frames;
        out->start_frame = r.start;
        out->latency_frames = r.latency;
        out->notes = r.notes;
        out->recovered = r.recovered;
        copyOut(out->path, sizeof out->path, r.path);
        out->capture = r.stats;
    }
    if (!ok) copyOut(err, err_len, msg);
    return ok ? DALNOK_OK : DALNOK_ERR_IO;
}
bool dalnok_record_active(const DalnokEngine *e) { return e && e->impl.recording(); }
bool dalnok_record_broken(const DalnokEngine *e) { return e && e->impl.recording() && e->impl.recordBroken(); }
int64_t dalnok_record_start_frame(const DalnokEngine *e) { return e && e->impl.recording() ? e->impl.recordStart() : -1; }
int64_t dalnok_record_latency(const DalnokEngine *e) { return e ? e->impl.recordLatency() : 0; }
void dalnok_record_set_latency_offset(DalnokEngine *e, int64_t frames) { if (e) e->impl.setRecordLatencyOffset(frames); }
void dalnok_record_set_monitoring(DalnokEngine *e, bool on) { if (e) e->impl.setMonitoring(on); }
int32_t dalnok_record_live_peaks(DalnokEngine *e, DalnokTrackId track, float *out, int32_t capacity) {
    if (!e || !e->impl.recording()) return 0;
    const std::vector<float> *p = e->impl.livePeaks(track);
    if (!p) return 0;
    const auto n = static_cast<int32_t>(std::min<size_t>(p->size(), INT32_MAX));
    for (int32_t i = 0; out && i < capacity && i < n; ++i) out[i] = (*p)[static_cast<size_t>(i)];
    return n;
}
DalnokStatus dalnok_latency_measure_start(DalnokEngine *e, const char *uid, int32_t channel, char *err, size_t err_len) {
    if (!e || !uid) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.startLatencyProbe(uid, channel, msg)) { copyOut(err, err_len, msg); return DALNOK_ERR_DEVICE; }
    return DALNOK_OK;
}
bool dalnok_latency_measure_poll(DalnokEngine *e, DalnokLatencyResult *out) {
    if (!e) return true;
    dalnok::Engine::LatencyResult r;
    if (!e->impl.pollLatencyProbe(r)) return false;
    if (out) {
        *out = DalnokLatencyResult{};
        out->ok = r.ok; out->measured_frames = r.measured; out->reported_frames = r.reported;
        out->clicks = r.clicks; out->spread_frames = r.spread; out->level = r.level;
        copyOut(out->error, sizeof out->error, r.error);
    }
    return true;
}
DalnokStatus dalnok_input_set_device(DalnokEngine *e, const char *uid, char *err, size_t err_len) {
    if (!e) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.setInputDevice(uid ? uid : "", msg)) { copyOut(err, err_len, msg); return DALNOK_ERR_DEVICE; }
    return DALNOK_OK;
}
bool dalnok_input_running(const DalnokEngine *e) { return e && e->impl.inputRunning(); }
int32_t dalnok_input_error(const DalnokEngine *e, char *out, size_t out_len) {
    if (!e) return 0;
    copyOut(out, out_len, e->impl.inputError());
    return static_cast<int32_t>(e->impl.inputError().size());
}
void dalnok_record_set_simulated_latency(DalnokEngine *e, int64_t frames) { if (e) e->impl.setSimulatedLatency(frames); }
DalnokStatus dalnok_engine_pump_input(DalnokEngine *e, const float *in, float *l, float *r, int32_t frames) {
    return e && in && e->impl.pumpInput(in, l, r, frames) ? DALNOK_OK : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_engine_pump_input_channels(DalnokEngine *e, const float *const *in, int32_t count, float *l, float *r,
                                               int32_t frames) {
    if (!e || !in || count < 1 || count > 64) return DALNOK_ERR_INVALID_ARG;
    for (int32_t c = 0; c < count; ++c) if (!in[c]) return DALNOK_ERR_INVALID_ARG;
    return e->impl.pumpInputChannels(in, count, l, r, frames) ? DALNOK_OK : DALNOK_ERR_INVALID_ARG;
}
size_t dalnok_record_scan(const char *dir, char *out, size_t len) {
    return copyOut(out, len, json::serialize(dir ? scanTakes(dir) : json::Value::makeArray()));
}
DalnokStatus dalnok_record_recover(const char *journal, char *out, size_t len, char *err, size_t err_len) {
    if (!journal) return DALNOK_ERR_INVALID_ARG;
    json::Value result;
    std::string msg;
    if (!recoverTake(journal, result, msg)) { copyOut(err, err_len, msg); return DALNOK_ERR_IO; }
    copyOut(out, len, json::serialize(result));
    return DALNOK_OK;
}

DalnokStatus dalnok_midi_open_input(DalnokEngine *e, int32_t uid, char *err, size_t err_len) {
    if (!e) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.openMidiInput(uid, msg)) { copyOut(err, err_len, msg); return DALNOK_ERR_DEVICE; }
    return DALNOK_OK;
}
DalnokStatus dalnok_midi_inject(DalnokEngine *e, uint8_t status, uint8_t d1, uint8_t d2) {
    return e && e->impl.injectMidi(status, d1, d2) ? DALNOK_OK : DALNOK_ERR_INVALID_ARG;
}
uint64_t dalnok_midi_dropped(const DalnokEngine *e) { return e ? e->impl.midiDropped() : 0; }


size_t dalnok_plugins_scan(const char *extra, bool au, char *out, size_t len) {
    auto folders = pluginFolders();
    if (extra && *extra) folders.push_back(extra);
    auto list = scanPluginBundles(folders);
    if (au) {
        auto units = listAudioUnits();
        list.insert(list.end(), units.begin(), units.end());
    }
    return copyOut(out, len, json::serialize(withBuiltins(pluginsToJson(list), false)));
}

int32_t dalnok_plugin_add(DalnokEngine *e, DalnokTrackId t, const char *path, const char *cid, char *err, size_t len) {
    if (!e || !path) return 0;
    std::string msg;
    const int32_t id = e->impl.addPlugin(t, path, cid ? cid : "", msg);
    if (!id) copyOut(err, len, msg);
    return id;
}
DalnokStatus dalnok_plugin_remove(DalnokEngine *e, DalnokTrackId t, int32_t slot) {
    std::string err;
    return e ? statusFor(e->impl.removePlugin(t, slot, err), err) : DALNOK_ERR_INVALID_ARG;
}
int32_t dalnok_track_plugin_count(const DalnokEngine *e, DalnokTrackId t) {
    const TrackState *tr = e ? e->impl.model().track(t) : nullptr;
    return tr ? static_cast<int32_t>(tr->plugins.size()) : 0;
}
DalnokStatus dalnok_track_plugin_info(const DalnokEngine *e, DalnokTrackId t, int32_t index, DalnokPluginSlotInfo *out) {
    const TrackState *tr = e ? e->impl.model().track(t) : nullptr;
    if (!tr || !out) return DALNOK_ERR_INVALID_ARG;
    if (index < 0 || index >= static_cast<int32_t>(tr->plugins.size())) return DALNOK_ERR_NOT_FOUND;
    const PluginSlot &slot = tr->plugins[static_cast<size_t>(index)];
    *out = DalnokPluginSlotInfo{};
    out->id = slot.id;
    copyOut(out->name, sizeof out->name, slot.name);
    copyOut(out->vendor, sizeof out->vendor, slot.vendor);
    copyOut(out->path, sizeof out->path, slot.path);
    out->instrument = slot.instrument;
    PluginProcessor *p = e->impl.pluginInstance(slot.id);
    const std::string failure = p ? p->failure() : std::string();
    out->loaded = p != nullptr && failure.empty();
    out->loading = !p && e->impl.pluginLoading(slot.id);
    out->isolated = p && p->isolated();
    out->latency = out->loaded ? p->latency() : 0;
    copyOut(out->error, sizeof out->error, failure.empty() ? e->impl.pluginError(slot.id) : failure + "; Load restarts it");
    return DALNOK_OK;
}
size_t dalnok_plugin_get_state(const DalnokEngine *e, int32_t slot, char *out, size_t len) {
    std::string bytes;
    if (!e || !e->impl.pluginState(slot, bytes)) return copyOut(out, len, "");
    return copyOut(out, len, base64Encode(bytes));
}
DalnokStatus dalnok_plugin_set_state(DalnokEngine *e, int32_t slot, const char *b64) {
    std::string bytes, err;
    if (!e || !b64 || !base64Decode(b64, bytes)) return DALNOK_ERR_INVALID_ARG;
    return statusFor(e->impl.setPluginState(slot, bytes, err), err);
}

DalnokStatus dalnok_plugin_parameter_text(const DalnokEngine *e, int32_t slot, uint32_t id, double normalized, char *text, size_t len) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p || !text || len == 0 || !(normalized >= 0 && normalized <= 1)) return DALNOK_ERR_INVALID_ARG;
    std::string s;
    if (!p->parameterText(id, normalized, s)) return DALNOK_ERR_NOT_FOUND;
    snprintf(text, len, "%s", s.c_str());
    return DALNOK_OK;
}
int32_t dalnok_plugin_parameter_count(const DalnokEngine *e, int32_t slot) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    return p ? p->parameterCount() : 0;
}
DalnokStatus dalnok_plugin_parameter(const DalnokEngine *e, int32_t slot, int32_t index, DalnokPluginParameter *out) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    PluginParameter pp;
    if (!p || !out) return DALNOK_ERR_INVALID_ARG;
    if (!p->parameter(index, pp)) return DALNOK_ERR_NOT_FOUND;
    *out = DalnokPluginParameter{};
    out->id = pp.id;
    copyOut(out->title, sizeof out->title, pp.title);
    copyOut(out->units, sizeof out->units, pp.units);
    copyOut(out->display, sizeof out->display, pp.display);
    out->value = pp.value;
    out->default_value = pp.defaultValue;
    out->step_count = pp.stepCount;
    out->automatable = pp.automatable;
    out->read_only = pp.readOnly;
    out->hidden = pp.hidden;
    return DALNOK_OK;
}
DalnokStatus dalnok_track_preview_note(DalnokEngine *e, DalnokTrackId track, uint8_t pitch, uint8_t velocity, bool on) {
    if (!e) return DALNOK_ERR_INVALID_ARG;
    return e->impl.previewNote(track, pitch, velocity, on) ? DALNOK_OK : DALNOK_ERR_NOT_FOUND;
}
bool dalnok_project_plugins_changed(const DalnokEngine *e) { return e && e->impl.pluginEditorStatesChanged(); }
bool dalnok_plugin_take_editor_key(DalnokEngine *e, DalnokEditorKey *out) {
    if (!e || !out) return false;
    int32_t slot = 0;
    dalnok::PluginProcessor::EditorKey k;
    if (!e->impl.takeEditorKey(slot, k)) return false;
    *out = DalnokEditorKey{};
    out->slot = slot;
    out->key_code = k.keyCode;
    out->modifiers = k.modifiers;
    std::memcpy(out->characters, k.characters, sizeof out->characters);
    std::memcpy(out->characters_ignoring_modifiers, k.charactersIgnoringModifiers, sizeof out->characters_ignoring_modifiers);
    return true;
}
DalnokStatus dalnok_plugin_set_parameter(DalnokEngine *e, int32_t slot, uint32_t id, double v) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p) return DALNOK_ERR_NOT_FOUND;
    if (!p->setParameter(id, v)) return DALNOK_ERR_INVALID_ARG;
    e->impl.touchPlugin();
    return DALNOK_OK;
}
int32_t dalnok_plugin_controls(const DalnokEngine *e, DalnokTrackId t, int32_t slot, uint32_t *ids, int32_t cap) {
    const TrackState *tr = e ? e->impl.model().track(t) : nullptr;
    if (!tr) return 0;
    for (const auto &s : tr->plugins)
        if (s.id == slot) {
            for (int32_t i = 0; ids && i < cap && i < static_cast<int32_t>(s.controls.size()); ++i) ids[i] = s.controls[static_cast<size_t>(i)];
            return static_cast<int32_t>(s.controls.size());
        }
    return 0;
}
DalnokStatus dalnok_plugin_set_controls(DalnokEngine *e, DalnokTrackId t, int32_t slot, const uint32_t *ids, int32_t count) {
    if (!e || count < 0 || (count > 0 && !ids)) return DALNOK_ERR_INVALID_ARG;
    std::string err;
    return statusFor(e->impl.setPluginControls(t, slot, std::vector<uint32_t>(ids, ids + count), err), err);
}
bool dalnok_plugin_has_editor(const DalnokEngine *e, int32_t slot) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    return p && p->hasEditor();
}
DalnokStatus dalnok_plugin_open_editor(DalnokEngine *e, int32_t slot, void *parent, int32_t *w, int32_t *h,
                                       void (*onResize)(void *, int32_t, int32_t), void *ctx, char *err, size_t len) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p || !parent) return DALNOK_ERR_INVALID_ARG;
    int32_t width = 0, height = 0;
    std::string msg;
    e->impl.noteEditorOpened(slot); // its state before the editor can change it
    if (!p->openEditor(parent, width, height, onResize, ctx, msg)) { copyOut(err, len, msg); return DALNOK_ERR_UNSUPPORTED; }
    if (w) *w = width;
    if (h) *h = height;
    return DALNOK_OK;
}
void dalnok_plugin_close_editor(DalnokEngine *e, int32_t slot) {
    if (PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr) p->closeEditor();
}
DalnokStatus dalnok_plugin_show_editor_window(DalnokEngine *e, int32_t slot, const char *title, double x, double y,
                                              char *err, size_t len) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p) return DALNOK_ERR_INVALID_ARG;
    std::string msg;
    e->impl.noteEditorOpened(slot); // its state before the editor can change it
    if (!p->showEditorWindow(title ? title : "", x, y, msg)) { copyOut(err, len, msg); return DALNOK_ERR_UNSUPPORTED; }
    return DALNOK_OK;
}
DalnokStatus dalnok_plugin_editor_window(DalnokEngine *e, int32_t slot, DalnokPluginEditorWindow *out) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p || !out) return DALNOK_ERR_INVALID_ARG;
    PluginProcessor::EditorWindowInfo i;
    if (!p->editorWindow(i)) return DALNOK_ERR_UNSUPPORTED;
    *out = DalnokPluginEditorWindow{i.open, i.visible, i.x, i.y, i.width, i.height, i.contentWidth, i.contentHeight,
                                    i.windowNumber, i.level, i.processId};
    return DALNOK_OK;
}
DalnokStatus dalnok_plugin_isolation_stats(DalnokEngine *e, int32_t slot, DalnokPluginIsolationStats *out) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p || !out) return DALNOK_ERR_INVALID_ARG;
    PluginProcessor::IsolationStats s;
    if (!p->isolationStats(s)) return DALNOK_ERR_UNSUPPORTED;
    *out = DalnokPluginIsolationStats{s.missedBlocks, s.budgetSkips, s.workgroupJoined, s.workgroupError, s.workgroupJoins};
    return DALNOK_OK;
}
DalnokStatus dalnok_plugin_editor_snapshot(DalnokEngine *e, int32_t slot, const char *path) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p || !path) return DALNOK_ERR_INVALID_ARG;
    return p->editorSnapshot(path) ? DALNOK_OK : DALNOK_ERR_UNSUPPORTED;
}

size_t dalnok_plugins_validate(const char *scanner, const char *cache, const char *extra, bool onlyExtra, bool au,
                               const char *filter, int32_t timeoutMs, bool rescan, char *out, size_t len) {
    if (!scanner || !*scanner) return copyOut(out, len, "[]");
    std::vector<std::string> folders = onlyExtra ? std::vector<std::string>{} : pluginFolders();
    if (extra && *extra) folders.push_back(extra);
    auto list = scanPluginBundles(folders);
    if (au) {
        auto units = listAudioUnits();
        list.insert(list.end(), units.begin(), units.end());
    }
    if (filter && *filter) {
        auto lower = [](std::string s) { for (auto &c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c))); return s; };
        const std::string f = lower(filter);
        std::erase_if(list, [&](const PluginInfo &p) { return lower(p.name).find(f) == std::string::npos; });
    }
    json::Value result = validatePlugins(list, scanner, cache ? cache : "", std::max(500, timeoutMs), rescan);
    if (!onlyExtra && !(filter && *filter)) result = withBuiltins(std::move(result), true);
    return copyOut(out, len, json::serialize(result));
}

DalnokTrackId dalnok_track_add_instrument(DalnokEngine *e, const char *name) {
    std::string err;
    return e ? e->impl.addInstrumentTrack(name ? name : "", err) : 0;
}
DalnokTrackId dalnok_track_add_bus(DalnokEngine *e, const char *name) {
    std::string err;
    return e ? e->impl.addBusTrack(name ? name : "", err) : 0;
}
DalnokStatus dalnok_track_set_output(DalnokEngine *e, DalnokTrackId t, DalnokTrackId bus) {
    std::string err;
    return e ? statusFor(e->impl.setTrackOutput(t, bus, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokTrackId dalnok_track_output(const DalnokEngine *e, DalnokTrackId t) {
    const auto *tr = e ? e->impl.model().track(t) : nullptr;
    return tr ? tr->output : 0;
}
DalnokStatus dalnok_track_set_send(DalnokEngine *e, DalnokTrackId t, DalnokTrackId bus, float db, bool pre) {
    std::string err;
    return e ? statusFor(e->impl.setSend(t, bus, db, pre, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_track_remove_send(DalnokEngine *e, DalnokTrackId t, DalnokTrackId bus) {
    std::string err;
    return e ? statusFor(e->impl.removeSend(t, bus, err), err) : DALNOK_ERR_INVALID_ARG;
}
int32_t dalnok_track_sends(const DalnokEngine *e, DalnokTrackId t, DalnokSend *out, int32_t cap) {
    const auto *tr = e ? e->impl.model().track(t) : nullptr;
    if (!tr) return 0;
    for (int32_t i = 0; out && i < cap && i < static_cast<int32_t>(tr->sends.size()); ++i)
        out[i] = {tr->sends[static_cast<size_t>(i)].bus, tr->sends[static_cast<size_t>(i)].db, tr->sends[static_cast<size_t>(i)].pre};
    return static_cast<int32_t>(tr->sends.size());
}
DalnokStatus dalnok_master_set_gain_db(DalnokEngine *e, float db) {
    std::string err;
    return e ? statusFor(e->impl.setMasterGainDb(db, err), err) : DALNOK_ERR_INVALID_ARG;
}
float dalnok_master_gain_db(const DalnokEngine *e) { return e ? e->impl.model().masterGainDb : 0; }
void dalnok_track_automation_hold(DalnokEngine *e, DalnokTrackId t, int32_t target, bool hold) {
    const auto *tr = e ? e->impl.model().track(t) : nullptr;
    if (!tr) return;
    (target == 1 ? tr->runtime->holdPan : tr->runtime->holdVolume).store(hold, std::memory_order_relaxed);
}
DalnokStatus dalnok_plugin_set_sidechain(DalnokEngine *e, DalnokTrackId t, int32_t slot, DalnokTrackId source) {
    std::string err;
    return e ? statusFor(e->impl.setSidechain(t, slot, source, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokTrackId dalnok_plugin_sidechain(const DalnokEngine *e, DalnokTrackId t, int32_t slot) {
    const auto *tr = e ? e->impl.model().track(t) : nullptr;
    if (!tr) return 0;
    for (const auto &p : tr->plugins) if (p.id == slot) return p.sidechain;
    return 0;
}
int32_t dalnok_marker_count(const DalnokEngine *e) { return e ? static_cast<int32_t>(e->impl.model().markers.size()) : 0; }
DalnokStatus dalnok_marker_at(const DalnokEngine *e, int32_t index, DalnokMarker *out) {
    if (!e || !out || index < 0 || index >= static_cast<int32_t>(e->impl.model().markers.size())) return DALNOK_ERR_INVALID_ARG;
    const auto &m = e->impl.model().markers[static_cast<size_t>(index)];
    *out = DalnokMarker{};
    out->id = m.id;
    out->frame = m.frame;
    std::snprintf(out->name, sizeof out->name, "%s", m.name.c_str());
    return DALNOK_OK;
}
int32_t dalnok_marker_add(DalnokEngine *e, int64_t frame, const char *name) {
    std::string err;
    return e ? e->impl.addMarker(frame, name ? name : "", err) : 0;
}
DalnokStatus dalnok_marker_remove(DalnokEngine *e, int32_t id) {
    std::string err;
    return e ? statusFor(e->impl.removeMarker(id, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_marker_move(DalnokEngine *e, int32_t id, int64_t frame) {
    std::string err;
    return e ? statusFor(e->impl.moveMarker(id, frame, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_marker_rename(DalnokEngine *e, int32_t id, const char *name) {
    std::string err;
    return e ? statusFor(e->impl.renameMarker(id, name ? name : "", err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokTrackId dalnok_track_duplicate(DalnokEngine *e, DalnokTrackId t) {
    std::string err;
    return e ? e->impl.duplicateTrack(t, err) : 0;
}
DalnokStatus dalnok_plugin_move(DalnokEngine *e, DalnokTrackId t, int32_t slot, int32_t index) {
    std::string err;
    return e ? statusFor(e->impl.movePlugin(t, slot, index, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_plugin_set_folded(DalnokEngine *e, DalnokTrackId t, int32_t slot, bool folded) {
    std::string err;
    return e ? statusFor(e->impl.setPluginFolded(t, slot, folded, err), err) : DALNOK_ERR_INVALID_ARG;
}
bool dalnok_plugin_folded(const DalnokEngine *e, DalnokTrackId t, int32_t slot) {
    if (!e) return false;
    const auto *tr = e->impl.model().track(t);
    if (!tr) return false;
    for (const auto &p : tr->plugins) if (p.id == slot) return p.folded;
    return false;
}
DalnokStatus dalnok_plugin_set_bypassed(DalnokEngine *e, DalnokTrackId t, int32_t slot, bool bypassed) {
    std::string err;
    return e ? statusFor(e->impl.setPluginBypassed(t, slot, bypassed, err), err) : DALNOK_ERR_INVALID_ARG;
}
bool dalnok_plugin_bypassed(const DalnokEngine *e, DalnokTrackId t, int32_t slot) {
    const auto *tr = e ? e->impl.model().track(t) : nullptr;
    if (!tr) return false;
    for (const auto &p : tr->plugins) if (p.id == slot) return p.bypassed;
    return false;
}
bool dalnok_plugin_has_sidechain(const DalnokEngine *e, int32_t slot) { return e && e->impl.pluginHasSidechain(slot); }
int32_t dalnok_launcher_scenes(const DalnokEngine *e) { return e ? e->impl.model().scenes : 0; }
DalnokClipId dalnok_launcher_copy_clip(DalnokEngine *e, DalnokClipId clip, int32_t slot) {
    std::string err;
    return e ? e->impl.copyToSlot(clip, slot, err) : 0;
}
DalnokStatus dalnok_launcher_launch(DalnokEngine *e, DalnokTrackId t, int32_t slot) {
    std::string err;
    return e ? statusFor(e->impl.launch(t, slot, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_launcher_launch_scene(DalnokEngine *e, int32_t slot) {
    std::string err;
    return e ? statusFor(e->impl.launchScene(slot, err), err) : DALNOK_ERR_INVALID_ARG;
}
void dalnok_launcher_stop_all(DalnokEngine *e) { if (e) e->impl.stopLauncher(); }
int32_t dalnok_launcher_playing(const DalnokEngine *e, DalnokTrackId t) { return e ? e->impl.playingSlot(t) : -1; }
DalnokClipId dalnok_clip_place_copy(DalnokEngine *e, DalnokClipId c, DalnokTrackId t, int64_t start) {
    std::string err;
    return e ? e->impl.placeCopy(c, t, start, err) : 0;
}
int64_t dalnok_launcher_slot_start(const DalnokEngine *e, DalnokTrackId t) { return e ? e->impl.slotStart(t) : 0; }
DalnokStatus dalnok_launcher_set_follow(DalnokEngine *e, DalnokClipId c, int32_t action, int32_t loops) {
    std::string err;
    return e ? statusFor(e->impl.setFollowAction(c, action, loops, err), err) : DALNOK_ERR_INVALID_ARG;
}
void dalnok_launcher_set_recording(DalnokEngine *e, bool on) { if (e) e->impl.setLauncherRecording(on); }
bool dalnok_launcher_recording(const DalnokEngine *e) { return e && e->impl.launcherRecording(); }
DalnokStatus dalnok_plugin_set_automation(DalnokEngine *e, DalnokTrackId t, int32_t slot, uint32_t param,
                                          const DalnokAutoPoint *pts, int32_t count) {
    if (!e || count < 0 || (count > 0 && !pts)) return DALNOK_ERR_INVALID_ARG;
    std::vector<dalnok::AutoPoint> points;
    for (int32_t i = 0; i < count; ++i) points.push_back({pts[i].frame, pts[i].value});
    std::string err;
    return statusFor(e->impl.setPluginAutomation(t, slot, param, std::move(points), err), err);
}
int32_t dalnok_plugin_automation(const DalnokEngine *e, DalnokTrackId t, int32_t slot, uint32_t param, DalnokAutoPoint *out, int32_t cap) {
    const auto *tr = e ? e->impl.model().track(t) : nullptr;
    if (!tr) return 0;
    for (const auto &l : tr->pluginAuto)
        if (l.slot == slot && l.param == param) {
            for (int32_t i = 0; out && i < cap && i < static_cast<int32_t>(l.points.size()); ++i)
                out[i] = {l.points[static_cast<size_t>(i)].frame, l.points[static_cast<size_t>(i)].value};
            return static_cast<int32_t>(l.points.size());
        }
    return 0;
}
DalnokTrackId dalnok_track_stack_create(DalnokEngine *e, const DalnokTrackId *members, int32_t count, const char *name) {
    if (!e || !members || count < 1) return 0;
    std::string err;
    return e->impl.makeStack(std::vector<DalnokTrackId>(members, members + count), name ? name : "", err);
}
DalnokStatus dalnok_track_set_hidden(DalnokEngine *e, DalnokTrackId t, bool hidden) {
    std::string err;
    return e ? statusFor(e->impl.setTrackHidden(t, hidden, err), err) : DALNOK_ERR_INVALID_ARG;
}
bool dalnok_track_hidden(const DalnokEngine *e, DalnokTrackId t) {
    const auto *tr = e ? e->impl.model().track(t) : nullptr;
    return tr && tr->hidden;
}
DalnokStatus dalnok_track_stack_set_collapsed(DalnokEngine *e, DalnokTrackId stack, bool collapsed) {
    std::string err;
    return e ? statusFor(e->impl.setStackCollapsed(stack, collapsed, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_track_set_height(DalnokEngine *e, DalnokTrackId t, float height) {
    std::string err;
    return e ? statusFor(e->impl.setTrackHeight(t, height, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_track_stack_ungroup(DalnokEngine *e, DalnokTrackId stack) {
    std::string err;
    return e ? statusFor(e->impl.ungroupStack(stack, err), err) : DALNOK_ERR_INVALID_ARG;
}
int32_t dalnok_take_folder_create(DalnokEngine *e, DalnokTrackId t, const DalnokClipId *takes, int32_t count) {
    if (!e || !takes || count < 1) return 0;
    std::string err;
    return e->impl.addTakeFolder(t, std::vector<DalnokClipId>(takes, takes + count), err);
}
static const dalnok::TakeFolder *findFolder(const DalnokEngine *e, int32_t id) {
    if (!e) return nullptr;
    for (const auto &f : e->impl.model().folders) if (f.id == id) return &f;
    return nullptr;
}
int32_t dalnok_take_folders(const DalnokEngine *e, DalnokTrackId t, int32_t *out, int32_t cap) {
    if (!e) return 0;
    int32_t n = 0;
    for (const auto &f : e->impl.model().folders) if (f.track == t) { if (out && n < cap) out[n] = f.id; ++n; }
    return n;
}
int32_t dalnok_take_folder_takes(const DalnokEngine *e, int32_t folder, DalnokClipId *out, int32_t cap) {
    const auto *f = findFolder(e, folder);
    if (!f) return 0;
    for (int32_t i = 0; out && i < cap && i < static_cast<int32_t>(f->takes.size()); ++i) out[i] = f->takes[static_cast<size_t>(i)];
    return static_cast<int32_t>(f->takes.size());
}
int32_t dalnok_take_folder_comp(const DalnokEngine *e, int32_t folder, DalnokCompSegment *out, int32_t cap) {
    const auto *f = findFolder(e, folder);
    if (!f) return 0;
    for (int32_t i = 0; out && i < cap && i < static_cast<int32_t>(f->comp.size()); ++i) {
        const auto &c = f->comp[static_cast<size_t>(i)];
        out[i] = {c.from, c.to, c.take};
    }
    return static_cast<int32_t>(f->comp.size());
}
DalnokStatus dalnok_take_folder_set_comp(DalnokEngine *e, int32_t folder, const DalnokCompSegment *segs, int32_t count) {
    if (!e || count < 0 || (count > 0 && !segs)) return DALNOK_ERR_INVALID_ARG;
    std::vector<dalnok::CompSegment> comp;
    for (int32_t i = 0; i < count; ++i) comp.push_back({segs[i].from, segs[i].to, segs[i].take});
    std::string err;
    return statusFor(e->impl.setComp(folder, std::move(comp), err), err);
}
int32_t dalnok_latency_compensation(const DalnokEngine *e) { return e ? e->impl.compensation() : 0; }
DalnokStatus dalnok_track_set_automation(DalnokEngine *e, DalnokTrackId t, int32_t target, const DalnokAutoPoint *pts,
                                         int32_t count) {
    if (!e || count < 0 || (count > 0 && !pts)) return DALNOK_ERR_INVALID_ARG;
    std::vector<dalnok::AutoPoint> points;
    for (int32_t i = 0; i < count; ++i) points.push_back({pts[i].frame, pts[i].value});
    std::string err;
    return statusFor(e->impl.setAutomation(t, target, std::move(points), err), err);
}
int32_t dalnok_track_automation(const DalnokEngine *e, DalnokTrackId t, int32_t target, DalnokAutoPoint *out, int32_t cap) {
    const auto *tr = e ? e->impl.model().track(t) : nullptr;
    if (!tr || (target != 0 && target != 1)) return 0;
    const auto &pts = target == 0 ? tr->volumeAuto : tr->panAuto;
    for (int32_t i = 0; out && i < cap && i < static_cast<int32_t>(pts.size()); ++i) out[i] = {pts[static_cast<size_t>(i)].frame, pts[static_cast<size_t>(i)].value};
    return static_cast<int32_t>(pts.size());
}
DalnokStatus dalnok_track_set_armed(DalnokEngine *e, DalnokTrackId t, bool armed) {
    std::string err;
    return e ? statusFor(e->impl.setArmed(t, armed, err), err) : DALNOK_ERR_INVALID_ARG;
}
int32_t dalnok_groups(const DalnokEngine *e, DalnokGroupInfo *out, int32_t capacity) {
    if (!e) return 0;
    const auto &gs = e->impl.groups();
    for (int32_t i = 0; out && i < capacity && i < static_cast<int32_t>(gs.size()); ++i) {
        const auto &g = gs[static_cast<size_t>(i)];
        out[i] = DalnokGroupInfo{};
        out[i].id = g.id;
        copyOut(out[i].name, sizeof out[i].name, g.name);
        out[i].volume = g.volume; out[i].pan = g.pan; out[i].mute = g.mute;
        out[i].solo = g.solo; out[i].arm = g.arm; out[i].monitor = g.monitor;
        for (int32_t k = 0; k < dalnok_track_count(e); ++k) {
            DalnokTrackInfo t{};
            if (dalnok_track_info(e, dalnok_track_at(e, k), &t) == DALNOK_OK && t.group == g.id) ++out[i].members;
        }
    }
    return static_cast<int32_t>(gs.size());
}
int32_t dalnok_group_create(DalnokEngine *e, const char *name, const DalnokTrackId *members, int32_t count) {
    if (!e || count < 0 || (count > 0 && !members)) return 0;
    std::string err;
    return e->impl.createGroup(name ? name : "", std::vector<DalnokTrackId>(members, members + count), err);
}
DalnokStatus dalnok_group_remove(DalnokEngine *e, int32_t g) {
    std::string err;
    return e ? statusFor(e->impl.removeGroup(g, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_group_set(DalnokEngine *e, const DalnokGroupInfo *info) {
    if (!e || !info) return DALNOK_ERR_INVALID_ARG;
    dalnok::TrackGroup g;
    g.id = info->id;
    g.name = std::string(info->name, strnlen(info->name, sizeof info->name));
    g.volume = info->volume; g.pan = info->pan; g.mute = info->mute; g.solo = info->solo; g.arm = info->arm; g.monitor = info->monitor;
    std::string err;
    return statusFor(e->impl.setGroup(g, err), err);
}
DalnokStatus dalnok_track_set_group(DalnokEngine *e, DalnokTrackId t, int32_t g) {
    std::string err;
    return e ? statusFor(e->impl.setTrackGroup(t, g, err), err) : DALNOK_ERR_INVALID_ARG;
}
void dalnok_groups_set_clutch(DalnokEngine *e, bool on) { if (e) e->impl.setGroupClutch(on); }
bool dalnok_groups_clutch(const DalnokEngine *e) { return e && e->impl.groupClutch(); }
DalnokStatus dalnok_track_set_input_monitor(DalnokEngine *e, DalnokTrackId t, bool on) {
    std::string err;
    return e ? statusFor(e->impl.setInputMonitor(t, on, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_track_set_input(DalnokEngine *e, DalnokTrackId t, int32_t ch) {
    std::string err;
    return e ? statusFor(e->impl.setInputChannel(t, ch, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokClipId dalnok_midi_clip_add(DalnokEngine *e, DalnokTrackId t, int64_t start, int64_t length) {
    std::string err;
    return e ? e->impl.addMidiClip(t, start, length, err) : 0;
}
DalnokStatus dalnok_midi_clip_set_notes(DalnokEngine *e, DalnokClipId c, const DalnokNote *notes, int32_t count) {
    if (!e || count < 0 || (count > 0 && !notes)) return DALNOK_ERR_INVALID_ARG;
    std::string err;
    return statusFor(e->impl.setNotes(c, toNotes(notes, count), err), err);
}
int32_t dalnok_midi_clip_notes(const DalnokEngine *e, DalnokClipId c, DalnokNote *out, int32_t capacity) {
    const ClipState *clip = e ? e->impl.model().clip(c) : nullptr;
    if (!clip || !clip->midi()) return -1;
    const auto &notes = *clip->notes;
    for (int32_t i = 0; out && i < capacity && i < static_cast<int32_t>(notes.size()); ++i) {
        const auto &n = notes[static_cast<size_t>(i)];
        out[i] = DalnokNote{n.start, n.length, n.pitch, n.velocity};
    }
    return static_cast<int32_t>(notes.size());
}
DalnokStatus dalnok_midi_quantize(DalnokEngine *e, DalnokClipId c, double grid, double strength) {
    std::string err;
    return e ? statusFor(e->impl.quantize(c, grid, strength, err), err) : DALNOK_ERR_INVALID_ARG;
}
DalnokStatus dalnok_tempo_set(DalnokEngine *e, double bpm, int32_t num, int32_t den) {
    std::string err;
    return e ? statusFor(e->impl.setTempo(bpm, num, den, err), err) : DALNOK_ERR_INVALID_ARG;
}
void dalnok_metronome_set(DalnokEngine *e, bool on, float level) { if (e) e->impl.setMetronome(on, level); }
void dalnok_metronome_count_in(DalnokEngine *e, int64_t until) { if (e) e->impl.setCountIn(until); }
DalnokStatus dalnok_record_set_punch(DalnokEngine *e, bool on, int64_t in, int64_t out) {
    std::string err;
    return e ? statusFor(e->impl.setPunch(on, in, out, err), err) : DALNOK_ERR_INVALID_ARG;
}
void dalnok_record_set_slot(DalnokEngine *e, int32_t slot) { if (e) e->impl.setRecordSlot(slot < 0 ? -1 : slot); }
int32_t dalnok_record_slot(const DalnokEngine *e) { return e ? e->impl.recordSlot() : -1; }
void dalnok_record_punch(const DalnokEngine *e, bool *on, int64_t *in, int64_t *out) {
    bool o = false;
    int64_t a = 0, b = 0;
    if (e) e->impl.punch(o, a, b);
    if (on) *on = o;
    if (in) *in = o ? a : 0;
    if (out) *out = o ? b : 0;
}
DalnokStatus dalnok_cycle_set(DalnokEngine *e, bool on, int64_t start, int64_t end) {
    std::string err;
    return e ? statusFor(e->impl.setCycle(on, start, end, err), err) : DALNOK_ERR_INVALID_ARG;
}
void dalnok_cycle_get(const DalnokEngine *e, bool *on, int64_t *start, int64_t *end) {
    bool o = false;
    int64_t a = 0, b = 0;
    if (e) e->impl.cycle(o, a, b);
    if (on) *on = o;
    if (start) *start = a;
    if (end) *end = b;
}
bool dalnok_metronome_enabled(const DalnokEngine *e) { return e && e->impl.metronome(); }
double dalnok_tempo_bpm(const DalnokEngine *e) { return e ? e->impl.model().bpm() : 120; }
void dalnok_meter(const DalnokEngine *e, int32_t *num, int32_t *den) {
    if (num) *num = e ? e->impl.model().meters.front().num : 4;
    if (den) *den = e ? e->impl.model().meters.front().den : 4;
}
DalnokStatus dalnok_tempo_map_set(DalnokEngine *e, const DalnokTempoPoint *tempo, int32_t tempo_count,
                                  const DalnokMeterPoint *meter, int32_t meter_count) {
    if (!e || !tempo || tempo_count < 1 || !meter || meter_count < 1) return DALNOK_ERR_INVALID_ARG;
    std::vector<dalnok::TempoPoint> t;
    for (int32_t i = 0; i < tempo_count; ++i) t.push_back({tempo[i].beat, tempo[i].bpm});
    std::vector<dalnok::MeterChange> m;
    for (int32_t i = 0; i < meter_count; ++i) m.push_back({meter[i].bar, meter[i].numerator, meter[i].denominator});
    std::string err;
    return statusFor(e->impl.setTempoMap(std::move(t), std::move(m), err), err);
}
int32_t dalnok_tempo_points(const DalnokEngine *e, DalnokTempoPoint *out, int32_t capacity) {
    if (!e) return 0;
    const auto &t = e->impl.model().tempo;
    for (int32_t i = 0; out && i < capacity && i < static_cast<int32_t>(t.size()); ++i) out[i] = {t[i].beat, t[i].bpm};
    return static_cast<int32_t>(t.size());
}
int32_t dalnok_meter_points(const DalnokEngine *e, DalnokMeterPoint *out, int32_t capacity) {
    if (!e) return 0;
    const auto &m = e->impl.model().meters;
    for (int32_t i = 0; out && i < capacity && i < static_cast<int32_t>(m.size()); ++i) out[i] = {m[i].bar, m[i].num, m[i].den};
    return static_cast<int32_t>(m.size());
}
double dalnok_beat_to_frame(const DalnokEngine *e, double beat) { return e ? e->impl.tempoMap().beatToFrameExact(beat) : 0; }
double dalnok_frame_to_beat(const DalnokEngine *e, double frame) { return e ? e->impl.tempoMap().frameToBeatExact(frame) : 0; }
double dalnok_bar_to_beat(const DalnokEngine *e, int32_t bar) { return e ? dalnok::barToBeat(e->impl.model().meters, bar) : 0; }
void dalnok_beat_to_bar(const DalnokEngine *e, double beat, int32_t *bar, double *beat_in_bar, int32_t *num, int32_t *den) {
    int32_t b = 0, n = 4, d = 4;
    double inBar = 0;
    if (e) dalnok::beatToBar(e->impl.model().meters, beat, b, inBar, n, d);
    if (bar) *bar = b;
    if (beat_in_bar) *beat_in_bar = inBar;
    if (num) *num = n;
    if (den) *den = d;
}
double dalnok_tempo_at(const DalnokEngine *e, double beat) {
    if (!e) return 120;
    const auto &t = e->impl.model().tempo;
    double bpm = t.front().bpm;
    for (const auto &p : t) if (p.beat <= beat + 1e-9) bpm = p.bpm;
    return bpm;
}

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
DalnokStatus dalnok_meter_plugin(DalnokEngine *e, int32_t slot, float *il, float *ir, float *ol, float *orr) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p) return DALNOK_ERR_NOT_FOUND;
    float *dst[4] = {il, ir, ol, orr};
    std::atomic<float> *src[4] = {&p->meterIn[0], &p->meterIn[1], &p->meterOut[0], &p->meterOut[1]};
    for (int i = 0; i < 4; ++i) {
        const float v = src[i]->exchange(0.0f, std::memory_order_relaxed);
        if (dst[i]) *dst[i] = v;
    }
    return DALNOK_OK;
}
int32_t dalnok_plugin_tap(DalnokEngine *e, int32_t slot, float *in, float *out, int32_t frames) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p || frames <= 0) return 0;
    PluginProcessor::Tap *tap = p->tap.load(std::memory_order_acquire);
    if (!tap) {
        p->tapStorage = std::make_unique<PluginProcessor::Tap>();
        p->tap.store(p->tapStorage.get(), std::memory_order_release);
        return 0;
    }
    constexpr uint32_t size = PluginProcessor::Tap::kSize, mask = size - 1;
    const uint32_t n = std::min<uint32_t>(static_cast<uint32_t>(frames), size);
    const uint32_t end = tap->pos.load(std::memory_order_acquire), start = end - n;
    for (uint32_t i = 0; i < n; ++i) {
        if (in) in[i] = tap->in[(start + i) & mask].load(std::memory_order_relaxed);
        if (out) out[i] = tap->out[(start + i) & mask].load(std::memory_order_relaxed);
    }
    return static_cast<int32_t>(n);
}
int32_t dalnok_plugin_tap_stereo(DalnokEngine *e, int32_t slot, float *left, float *right, int32_t frames) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p || frames <= 0) return 0;
    PluginProcessor::Tap *tap = p->tap.load(std::memory_order_acquire);
    if (!tap) return dalnok_plugin_tap(e, slot, nullptr, nullptr, frames); // starts it
    constexpr uint32_t size = PluginProcessor::Tap::kSize, mask = size - 1;
    const uint32_t n = std::min<uint32_t>(static_cast<uint32_t>(frames), size);
    const uint32_t end = tap->pos.load(std::memory_order_acquire), start = end - n;
    for (uint32_t i = 0; i < n; ++i) {
        if (left) left[i] = tap->outL[(start + i) & mask].load(std::memory_order_relaxed);
        if (right) right[i] = tap->outR[(start + i) & mask].load(std::memory_order_relaxed);
    }
    return static_cast<int32_t>(n);
}
size_t dalnok_plugin_categories(const DalnokEngine *e, int32_t slot, char *text, size_t len) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    const std::string c = p ? p->categories() : std::string();
    if (text && len) snprintf(text, len, "%s", c.c_str());
    return c.size();
}
DalnokStatus dalnok_plugin_response(const DalnokEngine *e, int32_t slot, const double *hz, int32_t count, double *db) {
    PluginProcessor *p = e ? e->impl.pluginInstance(slot) : nullptr;
    if (!p || !hz || !db || count <= 0) return DALNOK_ERR_INVALID_ARG;
    return p->response(hz, count, db) ? DALNOK_OK : DALNOK_ERR_NOT_FOUND;
}
void dalnok_meter_master(DalnokEngine *e, float *l, float *r) {
    float a = 0, b = 0;
    if (e) e->impl.readMasterMeter(a, b);
    if (l) *l = a;
    if (r) *r = b;
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
int32_t dalnok_engine_snapshot_mismatches(DalnokEngine *e) {
    return e ? e->impl.snapshotMismatches() : -1;
}

} // extern "C"
