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

DalnokStatus status(bool ok, const std::string &err) {
    if (ok) return DALNOK_OK;
    return err.rfind("no such", 0) == 0 ? DALNOK_ERR_NOT_FOUND : DALNOK_ERR_INVALID_ARG;
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
         if (!needInt(a, "track", t, err) || !needNumber(a, "db", db, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setGainDb(t, static_cast<float>(db), err), err);
     }},
    {"track.setPan", "Set Track Pan", "{track, pan: -1..1}", [](ARGS) {
         DalnokTrackId t;
         double p;
         if (!needInt(a, "track", t, err) || !needNumber(a, "pan", p, err)) return DALNOK_ERR_INVALID_ARG;
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
    {"track.setArmed", "Record Enable Track", "{track, armed}", [](ARGS) {
         DalnokTrackId t;
         if (!needInt(a, "track", t, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setArmed(t, a.getBool("armed", true), err), err);
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
         return status(e.setTempo(bpm, static_cast<int32_t>(a.getNumber("numerator", e.model().meterNum)),
                                  static_cast<int32_t>(a.getNumber("denominator", e.model().meterDen)), err), err);
     }},
    {"transport.setMetronome", "Metronome", "{on, level? (0-1)}", [](ARGS) {
         e.setMetronome(a.getBool("on", true), static_cast<float>(a.getNumber("level", 0.5)));
         return DALNOK_OK;
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
         return status(e.setClipFades(c, fi, fo, curve == "equalPower" ? kFadeEqualPower : kFadeLinear, err), err);
     }},
    {"clip.setGain", "Set Clip Gain", "{clip, db}", [](ARGS) {
         DalnokClipId c;
         double db;
         if (!needInt(a, "clip", c, err) || !needNumber(a, "db", db, err)) return DALNOK_ERR_INVALID_ARG;
         return status(e.setClipGain(c, static_cast<float>(db), err), err);
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
    {"clip.move", "Move Clip", "{clip, start, track?}", [](ARGS) {
         DalnokClipId c;
         int64_t start;
         if (!needInt(a, "clip", c, err) || !needInt(a, "start", start, err)) return DALNOK_ERR_INVALID_ARG;
         const ClipState *cs = e.model().clip(c);
         if (!cs) return err = "no such clip", DALNOK_ERR_NOT_FOUND;
         const auto track = static_cast<DalnokTrackId>(a.getNumber("track", cs->track));
         return status(e.moveClip(c, track, start, err), err);
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
             e.seek(static_cast<int64_t>(std::llround(v * e.sampleRate())));
             return DALNOK_OK;
         }
         int64_t f;
         if (!needInt(a, "frame", f, err)) return DALNOK_ERR_INVALID_ARG;
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
