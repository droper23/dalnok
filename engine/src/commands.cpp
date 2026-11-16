// Named command catalog: the single entry point for scripting, the command
// palette, automation of the app, and (later) natural-language assistance.
// Every command maps onto the same Engine methods the typed C API uses.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "commands.hpp"

#include <algorithm>
#include <cmath>

namespace atrium {

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

AtriumStatus status(bool ok, const std::string &err) {
    if (ok) return ATRIUM_OK;
    return err.rfind("no such", 0) == 0 ? ATRIUM_ERR_NOT_FOUND : ATRIUM_ERR_INVALID_ARG;
}

#define ARGS [[maybe_unused]] Engine &e, [[maybe_unused]] const Value &a, [[maybe_unused]] Value &r, [[maybe_unused]] std::string &err

const CommandDef kCommands[] = {
    {"track.add", "New Track", "{name?}", [](ARGS) {
         const auto id = e.addTrack(a.getString("name", ""), err);
         r.set("id", id);
         return status(id != 0, err);
     }},
    {"track.remove", "Delete Track", "{track}", [](ARGS) {
         AtriumTrackId t;
         if (!needInt(a, "track", t, err)) return ATRIUM_ERR_INVALID_ARG;
         return status(e.removeTrack(t, err), err);
     }},
    {"track.rename", "Rename Track", "{track, name}", [](ARGS) {
         AtriumTrackId t;
         if (!needInt(a, "track", t, err)) return ATRIUM_ERR_INVALID_ARG;
         return status(e.renameTrack(t, a.getString("name", ""), err), err);
     }},
    {"track.setVolume", "Set Track Volume", "{track, db}", [](ARGS) {
         AtriumTrackId t;
         double db;
         if (!needInt(a, "track", t, err) || !needNumber(a, "db", db, err)) return ATRIUM_ERR_INVALID_ARG;
         return status(e.setGainDb(t, static_cast<float>(db), err), err);
     }},
    {"track.setPan", "Set Track Pan", "{track, pan: -1..1}", [](ARGS) {
         AtriumTrackId t;
         double p;
         if (!needInt(a, "track", t, err) || !needNumber(a, "pan", p, err)) return ATRIUM_ERR_INVALID_ARG;
         return status(e.setPan(t, static_cast<float>(p), err), err);
     }},
    {"track.setMute", "Mute or Unmute Track", "{track, muted}", [](ARGS) {
         AtriumTrackId t;
         if (!needInt(a, "track", t, err)) return ATRIUM_ERR_INVALID_ARG;
         return status(e.setMute(t, a.getBool("muted", true), err), err);
     }},
    {"clip.add", "Add Clip", "{track, media, start?, offset?, length?}", [](ARGS) {
         AtriumTrackId t;
         AtriumMediaId m;
         if (!needInt(a, "track", t, err) || !needInt(a, "media", m, err)) return ATRIUM_ERR_INVALID_ARG;
         const auto id = e.addClip(t, m, static_cast<int64_t>(a.getNumber("start", 0)),
                                   static_cast<int64_t>(a.getNumber("offset", 0)),
                                   static_cast<int64_t>(a.getNumber("length", 0)), err);
         r.set("id", id);
         return status(id != 0, err);
     }},
    {"clip.remove", "Delete Clip", "{clip}", [](ARGS) {
         AtriumClipId c;
         if (!needInt(a, "clip", c, err)) return ATRIUM_ERR_INVALID_ARG;
         return status(e.removeClip(c, err), err);
     }},
    {"clip.move", "Move Clip", "{clip, start, track?}", [](ARGS) {
         AtriumClipId c;
         int64_t start;
         if (!needInt(a, "clip", c, err) || !needInt(a, "start", start, err)) return ATRIUM_ERR_INVALID_ARG;
         const ClipState *cs = e.model().clip(c);
         if (!cs) return err = "no such clip", ATRIUM_ERR_NOT_FOUND;
         const auto track = static_cast<AtriumTrackId>(a.getNumber("track", cs->track));
         return status(e.moveClip(c, track, start, err), err);
     }},
    {"clip.setRegion", "Trim Clip", "{clip, start, offset, length}", [](ARGS) {
         AtriumClipId c;
         int64_t s, o, l;
         if (!needInt(a, "clip", c, err) || !needInt(a, "start", s, err) || !needInt(a, "offset", o, err) ||
             !needInt(a, "length", l, err))
             return ATRIUM_ERR_INVALID_ARG;
         return status(e.setClipRegion(c, s, o, l, err), err);
     }},
    {"clip.split", "Split Clip", "{clip, at}", [](ARGS) {
         AtriumClipId c;
         int64_t at;
         if (!needInt(a, "clip", c, err) || !needInt(a, "at", at, err)) return ATRIUM_ERR_INVALID_ARG;
         const auto id = e.splitClip(c, at, err);
         r.set("id", id);
         return status(id != 0, err);
     }},
    {"edit.undo", "Undo", "{}", [](ARGS) {
         r.set("done", e.undo());
         return ATRIUM_OK;
     }},
    {"edit.redo", "Redo", "{}", [](ARGS) {
         r.set("done", e.redo());
         return ATRIUM_OK;
     }},
    {"transport.play", "Play", "{}", [](ARGS) { e.play(); return ATRIUM_OK; }},
    {"transport.pause", "Pause", "{}", [](ARGS) { e.pause(); return ATRIUM_OK; }},
    {"transport.toggle", "Play / Pause", "{}", [](ARGS) {
         e.playing() ? e.pause() : e.play();
         return ATRIUM_OK;
     }},
    {"transport.seek", "Go to Position", "{frame} or {seconds}", [](ARGS) {
         double v;
         if (a.get("seconds") && needNumber(a, "seconds", v, err)) {
             e.seek(static_cast<int64_t>(std::llround(v * e.sampleRate())));
             return ATRIUM_OK;
         }
         int64_t f;
         if (!needInt(a, "frame", f, err)) return ATRIUM_ERR_INVALID_ARG;
         e.seek(f);
         return ATRIUM_OK;
     }},
    {"session.describe", "Describe Session", "{}", [](ARGS) {
         r = e.describe();
         r.set("position", e.position());
         r.set("playing", e.playing());
         r.set("canUndo", e.canUndo());
         r.set("undoName", e.undoName());
         return ATRIUM_OK;
     }},
};

#undef ARGS

} // namespace

const CommandDef *commandCatalog(int32_t &count) {
    count = static_cast<int32_t>(sizeof(kCommands) / sizeof(kCommands[0]));
    return kCommands;
}

AtriumStatus runCommand(Engine &e, const std::string &name, const std::string &argsJson, std::string &resultJson) {
    int32_t n;
    const CommandDef *defs = commandCatalog(n);
    json::Value args = json::Value::makeObject(), result = json::Value::makeObject();
    std::string err;
    AtriumStatus st = ATRIUM_ERR_NOT_FOUND;
    if (!argsJson.empty() && !json::parse(argsJson, args, err)) {
        st = ATRIUM_ERR_FORMAT;
        err = "invalid arguments JSON: " + err;
    } else if (!args.isObject()) {
        st = ATRIUM_ERR_FORMAT;
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
    if (st != ATRIUM_OK) {
        result = json::Value::makeObject();
        result.set("error", err.empty() ? std::string("failed") : err);
    }
    resultJson = json::serialize(result);
    return st;
}

} // namespace atrium
