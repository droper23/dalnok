// Named command catalog: the single entry point for scripting, the command
// palette, automation of the app, and (later) natural-language assistance.
// Every command maps onto the same Engine methods the typed C API uses.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "commands.hpp"

#include <algorithm>
#include <cmath>

namespace dalnok {

namespace {

using json::Value;

bool needNumber(const Value &a, const char *key, double &out, std::string &err) {
    const Value *v = a.get(key);
    if (!v || !v->isNumber()) {
        err = std::string("missing numeric argument '") + key + "'";
        return false;
    }
    out = v->number;
    return true;
}

template <typename Int>
bool needInt(const Value &a, const char *key, Int &out, std::string &err) {
    double d;
    if (!needNumber(a, key, d, err)) return false;
    if (d != std::floor(d)) {
        err = std::string("argument '") + key + "' must be an integer";
        return false;
    }
    out = static_cast<Int>(d);
    return true;
}

// A gain in dB the catalog accepts: finite and at most `max` (anything at or below -96 dB means silence). The engine
// clamps for faders being dragged past their end; a command with an out-of-range value is a mistake and says so.
bool needDb(const Value &a, const char *key, double max, double &out, std::string &err) {
    if (!needNumber(a, key, out, err)) return false;
    if (!std::isfinite(out) || out > max + 1e-9) {
        err = std::string("argument '") + key + "' must be at most " + std::to_string(static_cast<int>(max)) + " dB";
        return false;
    }
    return true;
}

DalnokStatus status(bool ok, const std::string &err) {
    if (ok) return DALNOK_OK;
    return err.rfind("no such", 0) == 0 ? DALNOK_ERR_NOT_FOUND : DALNOK_ERR_INVALID_ARG;
}

bool clipIds(const Value &a, std::vector<DalnokClipId> &ids, std::string &err) {
    const Value *list = a.get("clips");
    if (!list || !list->isArray() || list->array.empty()) { err = "clips must be a nonempty array"; return false; }
    for (const auto &v : list->array) {
        if (!v.isNumber() || !std::isfinite(v.number) || v.number < 1 || v.number > INT32_MAX || std::floor(v.number) != v.number) {
            err = "invalid clip id"; return false;
        }
        ids.push_back(static_cast<DalnokClipId>(v.number));
    }
    return true;
}

#define ARGS [[maybe_unused]] Engine &e, [[maybe_unused]] const Value &a, [[maybe_unused]] Value &r, [[maybe_unused]] std::string &err

const CommandDef kCommands[] = {
    {"track.add", "New Track", "{name?}", [](ARGS) {
         const auto id = e.addTrack(a.getString("name", ""), err);
         r.set("id", id);
         return status(id != 0, err);
     }},
    {"track.remove", "Delete Track", "{track}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.removeTrack(t, err), err);
     }},
    {"track.rename", "Rename Track", "{track, name}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.renameTrack(t, a.getString("name", ""), err), err);
     }},
    {"track.setVolume", "Set Track Volume", "{track, db}", [](ARGS) {
         DalnokTrackId t;
         double db;
         if (!needInt(a, "track", t, err) || !needDb(a, "db", 12, db, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setGainDb(t, static_cast<float>(db), err), err);
     }},
    {"track.setPan", "Set Track Pan", "{track, pan: -1..1}", [](ARGS) {
         DalnokTrackId t;
         double p;
         if (!needInt(a, "track", t, err) || !needNumber(a, "pan", p, err)) return DALNOK_ERR_INVALID_ARG;
         if (!(p >= -1 && p <= 1)) return err = "pan must be -1..1", DALNOK_ERR_INVALID_ARG;
         return status(e.setPan(t, static_cast<float>(p), err), err);
     }},
    {"track.setMute", "Mute or Unmute Track", "{track, muted}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setMute(t, a.getBool("muted", true), err), err);
     }},
    {"track.setSolo", "Solo or Unsolo Track", "{track, solo}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setSolo(t, a.getBool("solo", true), err), err);
     }},
    {"track.setColor", "Set Track Color", "{track, color: \"#rrggbb\" | \"auto\"}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         const std::string c = a.getString("color", "auto");
         int32_t rgb = -1;
         if (c != "auto") {
             if (c.size() != 7 || c[0] != '#') return err = "color must be #rrggbb or auto", DALNOK_ERR_INVALID_ARG;
             rgb = static_cast<int32_t>(std::strtol(c.c_str() + 1, nullptr, 16));
         }
         return status(e.setTrackColor(t, rgb, err), err);
     }},
    {"tracks.recolorGradient", "Recolor Tracks as Gradient", "{}", [](ARGS) {
         return status(e.recolorAsGradient(err), err);
     }},
    {"track.move", "Move Track", "{track, index}", [](ARGS) {
         DalnokTrackId t;
         int32_t i;
         if (!needInt(a, "track", t, err) || !needInt(a, "index", i, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.moveTrack(t, i, err), err);
     }},
    {"track.addInstrument", "New Instrument Track", "{name?}", [](ARGS) {
         const auto id = e.addInstrumentTrack(a.getString("name", ""), err);
         r.set("id", id);
         return status(id != 0, err);
     }},
    {"track.addBus", "New Bus", "{name?}", [](ARGS) {
         const auto id = e.addBusTrack(a.getString("name", ""), err);
         if (!id) return DALNOK_ERR_INVALID_ARG;
         r.set("track", id);
         return DALNOK_OK;
     }},
    {"track.setOutput", "Set Track Output", "{track, bus (0 = master)}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setTrackOutput(t, static_cast<DalnokTrackId>(a.getNumber("bus", 0)), err), err);
     }},
    {"track.setSend", "Send", "{track, bus, db?, pre?}", [](ARGS) {
         DalnokTrackId t, b;
         if (!needInt(a, "track", t, err) || !needInt(a, "bus", b, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setSend(t, b, static_cast<float>(a.getNumber("db", 0)), a.getBool("pre", false), err), err);
     }},
    {"track.removeSend", "Remove Send", "{track, bus}", [](ARGS) {
         DalnokTrackId t, b;
         if (!needInt(a, "track", t, err) || !needInt(a, "bus", b, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.removeSend(t, b, err), err);
     }},
    {"track.setAutomation", "Set Automation", "{track, target (\"volume\" | \"pan\"), points: [[frame, value], ...]}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         const std::string target = a.getString("target", "volume");
         if (target != "volume" && target != "pan") { err = "target is volume or pan"; return DALNOK_ERR_INVALID_ARG; }
         std::vector<AutoPoint> points;
         if (const json::Value *pl = a.get("points"); pl && pl->isArray())
             for (const auto &p : pl->array) {
                 if (!p.isArray() || p.array.size() != 2 || !p.array[0].isNumber() || !p.array[1].isNumber()) {
                     err = "each point is [frame, value]"; return DALNOK_ERR_INVALID_ARG;
                 }
                 points.push_back({static_cast<int64_t>(p.array[0].number), static_cast<float>(p.array[1].number)});
             }
         return status(e.setAutomation(t, target == "volume" ? kAutoVolume : kAutoPan, std::move(points), err), err);
     }},
    {"track.makeStack", "Create Track Stack", "{tracks: [track, ...], name?}", [](ARGS) {
         std::vector<DalnokTrackId> members;
         if (const json::Value *l = a.get("tracks"); l && l->isArray())
             for (const auto &v : l->array) if (v.isNumber()) members.push_back(static_cast<DalnokTrackId>(v.number));
         const auto id = e.makeStack(members, a.getString("name", ""), err);
         if (!id) return DALNOK_ERR_INVALID_ARG;
         r.set("track", id);
         return DALNOK_OK;
     }},
    {"track.ungroupStack", "Ungroup Track Stack", "{track}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.ungroupStack(t, err), err);
     }},
    {"plugin.setSidechain", "Sidechain", "{track, slot, source (track, 0 = none)}", [](ARGS) {
         DalnokTrackId t, src; int32_t slot;
         if (!needInt(a, "track", t, err) || !needInt(a, "slot", slot, err) || !needInt(a, "source", src, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setSidechain(t, slot, src, err), err);
     }},
    {"marker.add", "Add Marker", "{frame, name?}", [](ARGS) {
         double f;
         if (!needNumber(a, "frame", f, err) || !std::isfinite(f) || f < 0) return err = "frame must be >= 0", DALNOK_ERR_INVALID_ARG;
         return e.addMarker(static_cast<int64_t>(f), a.getString("name", ""), err) ? DALNOK_OK : DALNOK_ERR_INVALID_ARG;
     }},
    {"marker.remove", "Delete Marker", "{id}", [](ARGS) {
         int32_t id;
         if (!needInt(a, "id", id, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.removeMarker(id, err), err);
     }},
    {"marker.move", "Move Marker", "{id, frame}", [](ARGS) {
         int32_t id; double f;
         if (!needInt(a, "id", id, err) || !needNumber(a, "frame", f, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.moveMarker(id, static_cast<int64_t>(f), err), err);
     }},
    {"marker.rename", "Rename Marker", "{id, name}", [](ARGS) {
         int32_t id;
         if (!needInt(a, "id", id, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.renameMarker(id, a.getString("name", ""), err), err);
     }},
    {"track.setHidden", "Hide Track", "{track (0 = all, with hidden false), hidden}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setTrackHidden(t, a.getBool("hidden", true), err), err);
     }},
    {"track.setHeight", "Track Height", "{track (0 = all), height (points, 0 = default)}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setTrackHeight(t, static_cast<float>(a.getNumber("height", 0)), err), err);
     }},
    {"track.duplicate", "Duplicate Track", "{track}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return e.duplicateTrack(t, err) ? DALNOK_OK : DALNOK_ERR_INVALID_ARG;
     }},
    {"audio.quantize", "Quantize Audio", "{clip, grid (quarter notes, default 0.25), strength (0-1], sensitivity (0-1)}", [](ARGS) {
         DalnokClipId c;
         if (!needInt(a, "clip", c, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.quantizeAudio(c, a.getNumber("grid", 0.25), a.getNumber("strength", 1), a.getNumber("sensitivity", 0.5), err), err);
     }},
    {"plugins.copy", "Paste Plug-ins", "{from, slots: [slot…], to, index (-1 = end)}", [](ARGS) {
         DalnokTrackId from, to;
         if (!needInt(a, "from", from, err) || !needInt(a, "to", to, err)) return DALNOK_ERR_INVALID_ARG;
         std::vector<int32_t> slots;
         if (const json::Value *list = a.get("slots"); list && list->isArray())
             for (const auto &v : list->array) if (v.isNumber()) slots.push_back(static_cast<int32_t>(v.number));
         if (slots.empty()) return err = "slots: a list of plug-in slot ids", DALNOK_ERR_INVALID_ARG;
         return e.copyPlugins(from, slots, to, static_cast<int32_t>(a.getNumber("index", -1)), err).empty() ? DALNOK_ERR_INVALID_ARG : DALNOK_OK;
     }},
    {"plugin.move", "Move Plug-in", "{track, slot, index}", [](ARGS) {
         DalnokTrackId t; int32_t slot, index;
         if (!needInt(a, "track", t, err) || !needInt(a, "slot", slot, err) || !needInt(a, "index", index, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.movePlugin(t, slot, index, err), err);
     }},
    {"plugin.setBypassed", "Bypass Plug-in", "{track, slot, bypassed}", [](ARGS) {
         DalnokTrackId t; int32_t slot;
         if (!needInt(a, "track", t, err) || !needInt(a, "slot", slot, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setPluginBypassed(t, slot, a.getBool("bypassed", true), err), err);
     }},
    {"plugin.setFolded", "Fold Plug-in", "{track, slot, folded}", [](ARGS) {
         DalnokTrackId t; int32_t slot;
         if (!needInt(a, "track", t, err) || !needInt(a, "slot", slot, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setPluginFolded(t, slot, a.getBool("folded", true), err), err);
     }},
    {"plugin.setAutomation", "Plug-in Automation", "{track, slot, param, points: [[frame, value 0-1], ...]}", [](ARGS) {
         DalnokTrackId t; int32_t slot; double param;
         if (!needInt(a, "track", t, err) || !needInt(a, "slot", slot, err) || !needNumber(a, "param", param, err)) return DALNOK_ERR_INVALID_ARG;
         std::vector<AutoPoint> points;
         if (const json::Value *pl = a.get("points"); pl && pl->isArray())
             for (const auto &p : pl->array)
                 if (p.isArray() && p.array.size() == 2) points.push_back({static_cast<int64_t>(p.array[0].number), static_cast<float>(p.array[1].number)});
         return status(e.setPluginAutomation(t, slot, static_cast<uint32_t>(param), std::move(points), err), err);
     }},
    {"launcher.copyClip", "Copy to Launcher Slot", "{clip, slot}", [](ARGS) {
         DalnokClipId c; int32_t slot;
         if (!needInt(a, "clip", c, err) || !needInt(a, "slot", slot, err)) return DALNOK_ERR_INVALID_ARG;
         const auto id = e.copyToSlot(c, slot, err);
         if (!id) return DALNOK_ERR_INVALID_ARG;
         r.set("clip", id);
         return DALNOK_OK;
     }},
    {"launcher.launch", "Launch Slot", "{track, slot (-1 = back to the arrangement)}", [](ARGS) {
         DalnokTrackId t; int32_t slot;
         if (!needInt(a, "track", t, err) || !needInt(a, "slot", slot, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.launch(t, slot, err), err);
     }},
    {"launcher.setFollow", "Follow Action", "{clip, action (0 none, 1 next, 2 stop), loops?}", [](ARGS) {
         DalnokClipId c; int32_t action;
         if (!needInt(a, "clip", c, err) || !needInt(a, "action", action, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setFollowAction(c, action, static_cast<int32_t>(a.getNumber("loops", 1)), err), err);
     }},
    {"launcher.launchScene", "Launch Scene", "{slot}", [](ARGS) {
         int32_t slot;
         if (!needInt(a, "slot", slot, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.launchScene(slot, err), err);
     }},
    {"master.setGain", "Master Volume", "{db}", [](ARGS) {
         double db;
         if (!needDb(a, "db", 12, db, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setMasterGainDb(static_cast<float>(db), err), err);
     }},
    {"takes.makeFolder", "Make Take Folder", "{track, clips: [clip, ...]}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         std::vector<DalnokClipId> clips;
         if (const json::Value *l = a.get("clips"); l && l->isArray())
             for (const auto &v : l->array) if (v.isNumber()) clips.push_back(static_cast<DalnokClipId>(v.number));
         const auto id = e.addTakeFolder(t, std::move(clips), err);
         if (!id) return DALNOK_ERR_INVALID_ARG;
         r.set("folder", id);
         return DALNOK_OK;
     }},
    {"takes.setComp", "Comp", "{folder, comp: [[from, to, take], ...]}", [](ARGS) {
         int32_t f;
         if (!needInt(a, "folder", f, err)) return DALNOK_ERR_INVALID_ARG;
         std::vector<CompSegment> comp;
         if (const json::Value *l = a.get("comp"); l && l->isArray())
             for (const auto &v : l->array) {
                 if (!v.isArray() || v.array.size() != 3) { err = "each segment is [from, to, take]"; return DALNOK_ERR_INVALID_ARG; }
                 comp.push_back({static_cast<int64_t>(v.array[0].number), static_cast<int64_t>(v.array[1].number),
                                 static_cast<int32_t>(v.array[2].number)});
             }
         return status(e.setComp(f, std::move(comp), err), err);
     }},
    {"track.setArmed", "Record Enable Track", "{track, armed}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setArmed(t, a.getBool("armed", true), err), err);
     }},
    {"group.create", "New Group", "{name, tracks: [id...]}", [](ARGS) {
         std::vector<DalnokTrackId> members;
         if (const json::Value *v = a.get("tracks"); v && v->isArray())
             for (const auto &x : v->array) members.push_back(static_cast<DalnokTrackId>(x.number));
         return e.createGroup(a.getString("name", ""), members, err) ? DALNOK_OK : status(false, err);
     }},
    {"group.remove", "Delete Group", "{group}", [](ARGS) {
         int32_t g;
         if (!needInt(a, "group", g, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.removeGroup(g, err), err);
     }},
    {"track.setGroup", "Set Track Group", "{track, group (0 = none)}", [](ARGS) {
         DalnokTrackId t;
         int32_t g;
         if (!needInt(a, "track", t, err) || !needInt(a, "group", g, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setTrackGroup(t, g, err), err);
     }},
    {"track.setInputMonitor", "Input Monitoring", "{track, on}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setInputMonitor(t, a.getBool("on", true), err), err);
     }},
    {"track.setPhaseInvert", "Invert Track Phase", "{track, on}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setPhaseInvert(t, a.getBool("on", true), err), err);
     }},
    {"track.setInput", "Set Track Input", "{track, channel (zero-based)}", [](ARGS) {
         DalnokTrackId t;
         int32_t ch;
         if (!needInt(a, "track", t, err) || !needInt(a, "channel", ch, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setInputChannel(t, ch, err), err);
     }},
    {"project.setTempo", "Set Tempo and Meter", "{bpm, numerator?, denominator?}", [](ARGS) {
         double bpm;
         if (!needNumber(a, "bpm", bpm, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setTempo(bpm, static_cast<int32_t>(a.getNumber("numerator", e.model().meters.front().num)),
                                  static_cast<int32_t>(a.getNumber("denominator", e.model().meters.front().den)), err), err);
     }},
    {"project.setTempoMap", "Set Tempo and Meter Map",
     "{tempo: [[beat, bpm], ...] (first at beat 0), meter?: [[bar (zero-based), numerator, denominator], ...]}", [](ARGS) {
         const json::Value *tl = a.get("tempo");
         if (!tl || !tl->isArray() || tl->array.empty()) { err = "tempo must be a nonempty array"; return DALNOK_ERR_INVALID_ARG; }
         std::vector<TempoPoint> tempo;
         for (const auto &p : tl->array) {
             if (!p.isArray() || p.array.size() != 2 || !p.array[0].isNumber() || !p.array[1].isNumber()) {
                 err = "each tempo point is [beat, bpm]"; return DALNOK_ERR_INVALID_ARG;
             }
             tempo.push_back({p.array[0].number, p.array[1].number});
         }
         std::vector<MeterChange> meters = e.model().meters;
         if (const json::Value *ml = a.get("meter")) {
             meters.clear();
             if (!ml->isArray()) { err = "meter must be an array"; return DALNOK_ERR_INVALID_ARG; }
             for (const auto &p : ml->array) {
                 if (!p.isArray() || p.array.size() != 3 || !p.array[0].isNumber() || !p.array[1].isNumber() || !p.array[2].isNumber()) {
                     err = "each meter change is [bar, numerator, denominator]"; return DALNOK_ERR_INVALID_ARG;
                 }
                 meters.push_back({static_cast<int32_t>(p.array[0].number), static_cast<int32_t>(p.array[1].number),
                                   static_cast<int32_t>(p.array[2].number)});
             }
         }
         return status(e.setTempoMap(std::move(tempo), std::move(meters), err), err);
     }},
    {"transport.setPunch", "Punch In/Out", "{on, in?, out? (frames)}", [](ARGS) {
         bool on; int64_t in, out;
         e.punch(on, in, out);
         return status(e.setPunch(a.getBool("on", true), static_cast<int64_t>(a.getNumber("in", on ? static_cast<double>(in) : 0)),
                                  static_cast<int64_t>(a.getNumber("out", on ? static_cast<double>(out) : 0)), err), err);
     }},
    {"launcher.setRecordSlot", "Record Into Launcher Slot", "{slot (-1 = arrangement)}", [](ARGS) {
         e.setRecordSlot(std::max(-1, static_cast<int32_t>(a.getNumber("slot", -1))));
         return DALNOK_OK;
     }},
    {"transport.setCycle", "Cycle", "{on, start?, end? (frames)}", [](ARGS) {
         bool on; int64_t start, end;
         e.cycle(on, start, end);
         return status(e.setCycle(a.getBool("on", true), static_cast<int64_t>(a.getNumber("start", static_cast<double>(start))),
                                  static_cast<int64_t>(a.getNumber("end", static_cast<double>(end))), err), err);
     }},
    {"transport.setMetronome", "Metronome", "{on, level? (0-1)}", [](ARGS) {
         e.setMetronome(a.getBool("on", true), static_cast<float>(a.getNumber("level", 0.5)));
         return DALNOK_OK;
     }},
    {"plugin.add", "Add Plug-in", "{track, path (VST3 bundle), class? (hex id)}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         const auto id = e.addPlugin(t, a.getString("path", ""), a.getString("class", ""), err);
         r.set("slot", id);
         return id ? DALNOK_OK : (err.rfind("no such", 0) == 0 ? DALNOK_ERR_NOT_FOUND : DALNOK_ERR_IO);
     }},
    {"plugin.remove", "Remove Plug-in", "{track, slot}", [](ARGS) {
         DalnokTrackId t;
         int32_t slot;
         if (!needInt(a, "track", t, err) || !needInt(a, "slot", slot, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.removePlugin(t, slot, err), err);
     }},
    {"midi.addClip", "New MIDI Clip", "{track, start, length}", [](ARGS) {
         DalnokTrackId t;
         int64_t start, length;
         if (!needInt(a, "track", t, err) || !needInt(a, "start", start, err) || !needInt(a, "length", length, err))
             return DALNOK_ERR_INVALID_ARG;
         const auto id = e.addMidiClip(t, start, length, err);
         r.set("id", id);
         return status(id != 0, err);
     }},
    {"midi.setNotes", "Edit Notes", "{clip, notes: [[start, length, pitch, velocity], ...]}", [](ARGS) {
         DalnokClipId c;
         if (!needInt(a, "clip", c, err)) return DALNOK_ERR_INVALID_ARG;
         const Value *list = a.get("notes");
         if (!list || !list->isArray()) { err = "missing array argument 'notes'"; return DALNOK_ERR_INVALID_ARG; }
         std::vector<MidiNote> notes;
         for (const auto &n : list->array) {
             if (!n.isArray() || n.array.size() != 4) { err = "each note is [start, length, pitch, velocity]"; return DALNOK_ERR_INVALID_ARG; }
             for (const auto &x : n.array)
                 if (!x.isNumber() || x.number != std::floor(x.number)) { err = "note values must be integers"; return DALNOK_ERR_INVALID_ARG; }
             if (n.array[2].number < 0 || n.array[2].number > 127 || n.array[3].number < 1 || n.array[3].number > 127) {
                 err = "pitch must be 0-127 and velocity 1-127";
                 return DALNOK_ERR_INVALID_ARG;
             }
             notes.push_back({static_cast<int64_t>(n.array[0].number), static_cast<int64_t>(n.array[1].number),
                              static_cast<uint8_t>(n.array[2].number), static_cast<uint8_t>(n.array[3].number)});
         }
         return status(e.setNotes(c, std::move(notes), err), err);
     }},
    {"midi.quantize", "Quantize Notes", "{clip, grid (beats, e.g. 0.25 = 16ths), strength? (0-1)}", [](ARGS) {
         DalnokClipId c;
         double grid;
         if (!needInt(a, "clip", c, err) || !needNumber(a, "grid", grid, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.quantize(c, grid, a.getNumber("strength", 1.0), err), err);
     }},
    {"clip.setFades", "Set Clip Fades", "{clip, fadeIn, fadeOut, curve?: linear|equalPower}", [](ARGS) {
         DalnokClipId c;
         int64_t fi, fo;
         if (!needInt(a, "clip", c, err) || !needInt(a, "fadeIn", fi, err) || !needInt(a, "fadeOut", fo, err))
             return DALNOK_ERR_INVALID_ARG;
         const auto curve = a.getString("curve", "linear");
         if (curve != "linear" && curve != "equalPower") return err = "curve must be linear or equalPower", DALNOK_ERR_INVALID_ARG;
         if (const ClipState *clip = e.model().clip(c); clip && fi >= 0 && fo >= 0 && fi > clip->length - fo)
             return err = "fades are longer than the clip", DALNOK_ERR_INVALID_ARG;
         return status(e.setClipFades(c, fi, fo, curve == "equalPower" ? kFadeEqualPower : kFadeLinear, err), err);
     }},
    {"clip.setGain", "Set Clip Gain", "{clip, db}", [](ARGS) {
         DalnokClipId c;
         double db;
         if (!needInt(a, "clip", c, err) || !needDb(a, "db", 24, db, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setClipGain(c, static_cast<float>(db), err), err);
     }},
    {"clip.setMuted", "Mute or Unmute Clip", "{clip, muted}", [](ARGS) {
         DalnokClipId c;
         if (!needInt(a, "clip", c, err)) return DALNOK_ERR_INVALID_ARG;
         const auto *m = a.get("muted");
         if (!m || !m->isBool()) return err = "muted must be a boolean", DALNOK_ERR_INVALID_ARG;
         return status(e.setClipMuted(c, m->boolean, err), err);
     }},
    {"clip.setStretch", "Time Stretch Clip", "{clip, length?, rate?, pitch?, preservePitch?}", [](ARGS) {
         DalnokClipId c;
         if (!needInt(a, "clip", c, err)) return DALNOK_ERR_INVALID_ARG;
         const ClipState *cs = e.model().clip(c);
         if (!cs) return err = "no such clip", DALNOK_ERR_NOT_FOUND;
         const double rate = a.getNumber("rate", cs->rate);
         const auto length = static_cast<int64_t>(a.getNumber("length", static_cast<double>(cs->sourceLength()) / rate));
         return status(e.setClipStretch(c, length, rate, static_cast<float>(a.getNumber("pitch", cs->pitch)),
                                        a.getBool("preservePitch", cs->preservePitch), err), err);
     }},
    {"clip.add", "Add Clip", "{track, media, start?, offset?, length?}", [](ARGS) {
         DalnokTrackId t;
         DalnokMediaId m;
         if (!needInt(a, "track", t, err) || !needInt(a, "media", m, err)) return DALNOK_ERR_INVALID_ARG;
         const auto id = e.addClip(t, m, static_cast<int64_t>(a.getNumber("start", 0)),
                                   static_cast<int64_t>(a.getNumber("offset", 0)),
                                   static_cast<int64_t>(a.getNumber("length", 0)), err);
         r.set("id", id);
         return status(id != 0, err);
     }},
    {"clip.remove", "Delete Clip", "{clip}", [](ARGS) {
         DalnokClipId c;
         if (!needInt(a, "clip", c, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.removeClip(c, err), err);
     }},
    {"clips.remove", "Delete Clips", "{clips: [id, ...]}", [](ARGS) {
         std::vector<DalnokClipId> ids;
         if (!clipIds(a, ids, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.removeClips(ids, err), err);
     }},
    {"clip.move", "Move Clip", "{clip, start, track?}", [](ARGS) {
         DalnokClipId c;
         int64_t start;
         if (!needInt(a, "clip", c, err) || !needInt(a, "start", start, err)) return DALNOK_ERR_INVALID_ARG;
         const ClipState *cs = e.model().clip(c);
         if (!cs) return err = "no such clip", DALNOK_ERR_NOT_FOUND;
         const auto track = static_cast<DalnokTrackId>(a.getNumber("track", cs->track));
         return status(e.moveClip(c, track, start, err), err);
     }},
    {"clips.copy", "Paste Clips", "{clips: [id, ...], start: frame, trackShift?: places}", [](ARGS) {
         std::vector<DalnokClipId> ids;
         double start;
         if (!clipIds(a, ids, err) || !needNumber(a, "start", start, err) || !std::isfinite(start) || start < 0)
             return err = "clips must be a nonempty array and start a frame >= 0", DALNOK_ERR_INVALID_ARG;
         const auto shift = static_cast<int32_t>(a.getNumber("trackShift", 0));
         return e.copyClips(ids, static_cast<int64_t>(start), shift, err).empty() ? DALNOK_ERR_INVALID_ARG : DALNOK_OK;
     }},
    {"clipboard.copy", "Copy Clips", "{clips: [id, ...]}", [](ARGS) {
         std::vector<DalnokClipId> ids;
         if (!clipIds(a, ids, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.copyToClipboard(ids, err), err);
     }},
    {"clipboard.paste", "Paste Clips", "{track, start: frame}", [](ARGS) {
         DalnokTrackId t; double start;
         if (!needInt(a, "track", t, err) || !needNumber(a, "start", start, err) || !std::isfinite(start) || start < 0)
             return err = "track and start (frame >= 0) are required", DALNOK_ERR_INVALID_ARG;
         return e.pasteClipboard(t, static_cast<int64_t>(start), err).empty() ? DALNOK_ERR_INVALID_ARG : DALNOK_OK;
     }},
    {"clips.nudge", "Nudge Clips", "{clips: [id, ...], delta: frames}", [](ARGS) {
         std::vector<DalnokClipId> ids;
         double delta;
         if (!clipIds(a, ids, err) || !needNumber(a, "delta", delta, err) ||
             !std::isfinite(delta) || std::floor(delta) != delta || std::fabs(delta) > 9007199254740991.0)
             return err = "clips must be a nonempty array and delta an exact integer", DALNOK_ERR_INVALID_ARG;
         return status(e.nudgeClips(ids, static_cast<int64_t>(delta), err), err);
     }},
    {"clip.setRegion", "Trim Clip", "{clip, start, offset, length}", [](ARGS) {
         DalnokClipId c;
         int64_t s, o, l;
         if (!needInt(a, "clip", c, err) || !needInt(a, "start", s, err) || !needInt(a, "offset", o, err) ||
             !needInt(a, "length", l, err))
             return DALNOK_ERR_INVALID_ARG;
         return status(e.setClipRegion(c, s, o, l, err), err);
     }},
    {"clip.split", "Split Clip", "{clip, at}", [](ARGS) {
         DalnokClipId c;
         int64_t at;
         if (!needInt(a, "clip", c, err) || !needInt(a, "at", at, err)) return DALNOK_ERR_INVALID_ARG;
         const auto id = e.splitClip(c, at, err);
         r.set("id", id);
         return status(id != 0, err);
     }},
    {"edit.undo", "Undo", "{}", [](ARGS) {
         r.set("done", e.undo());
         return DALNOK_OK;
     }},
    {"edit.redo", "Redo", "{}", [](ARGS) {
         r.set("done", e.redo());
         return DALNOK_OK;
     }},
    {"transport.play", "Play", "{}", [](ARGS) { e.play(); return DALNOK_OK; }},
    {"transport.pause", "Pause", "{}", [](ARGS) { e.pause(); return DALNOK_OK; }},
    {"transport.toggle", "Play / Pause", "{}", [](ARGS) {
         e.playing() ? e.pause() : e.play();
         return DALNOK_OK;
     }},
    {"transport.seek", "Go to Position", "{frame} or {seconds}", [](ARGS) {
         double v;
         if (a.get("seconds") && needNumber(a, "seconds", v, err)) {
             if (!(v >= 0 && v < 1e9)) return err = "seconds must be 0 or more", DALNOK_ERR_INVALID_ARG;
             e.seek(static_cast<int64_t>(std::llround(v * e.sampleRate())));
             return DALNOK_OK;
         }
         int64_t f;
         if (!needInt(a, "frame", f, err)) return DALNOK_ERR_INVALID_ARG;
         if (f < 0) return err = "frame must be 0 or more", DALNOK_ERR_INVALID_ARG;
         e.seek(f);
         return DALNOK_OK;
     }},
    {"session.describe", "Describe Session", "{}", [](ARGS) {
         r = e.describe();
         r.set("position", e.position());
         r.set("playing", e.playing());
         r.set("canUndo", e.canUndo());
         r.set("undoName", e.undoName());
         return DALNOK_OK;
     }},
};

#undef ARGS

} // namespace

const CommandDef *commandCatalog(int32_t &count) {
    count = static_cast<int32_t>(sizeof(kCommands) / sizeof(kCommands[0]));
    return kCommands;
}

DalnokStatus runCommand(Engine &e, const std::string &name, const std::string &argsJson, std::string &resultJson) {
    int32_t n;
    const CommandDef *defs = commandCatalog(n);
    json::Value args = json::Value::makeObject(), result = json::Value::makeObject();
    std::string err;
    DalnokStatus st = DALNOK_ERR_NOT_FOUND;
    if (!argsJson.empty() && !json::parse(argsJson, args, err)) {
        st = DALNOK_ERR_FORMAT;
        err = "invalid arguments JSON: " + err;
    } else if (!args.isObject()) {
        st = DALNOK_ERR_FORMAT;
        err = "arguments must be a JSON object";
    } else {
        err = "unknown command '" + name + "'";
        for (int32_t i = 0; i < n; ++i) {
            if (name == defs[i].name) {
                err.clear();
                st = defs[i].run(e, args, result, err);
                break;
            }
        }
    }
    if (st != DALNOK_OK) {
        result = json::Value::makeObject();
        result.set("error", err.empty() ? std::string("failed") : err);
    }
    resultJson = json::serialize(result);
    return st;
}

} // namespace dalnok
