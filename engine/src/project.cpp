// Project persistence: versioned JSON, atomic writes, offline media on load.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Format (version 1):
// {
//   "format": "dalnok-project", "version": 1, "sampleRate": 48000,
//   "media":  [{"id", "path", "relativePath", "frames", "channels"}],
//   "tracks": [{"id", "name", "color", "gainDb" (null = -inf), "pan", "mute",
//               "clips": [{"id", "media", "start", "offset", "length", "name"}]}]
// }
// Positions are frames at "sampleRate"; loading into an engine at another
// rate rescales them.
#include "engine.hpp"
#include "import/import.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <set>
#include <sstream>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <vector>

namespace fs = std::filesystem;

namespace dalnok {

namespace {
constexpr int kFormatVersion = 4; // 3: shared MIDI sources preserve notes crossing split clips; 4: tempo and meter maps
constexpr int kConstantTempoVersion = 3; // written when there are no tempo or meter changes, so older builds still open it

bool readFile(const std::string &path, std::string &out, std::string &err) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        err = "cannot open " + path;
        return false;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

// Write-to-temp + fsync + rename: a crash mid-save never corrupts the old file.
bool writeFileAtomically(const std::string &path, const std::string &data, std::string &err) {
    // A unique, exclusively created temporary file avoids collisions and
    // prevents following an existing symlink when saving a recovery copy.
    std::string pattern = path + ".tmp-XXXXXX";
    std::vector<char> name(pattern.begin(), pattern.end());
    name.push_back('\0');
    const int fd = ::mkstemp(name.data());
    if (fd < 0) {
        err = "cannot create temporary file for " + path;
        return false;
    }
    const std::string tmp(name.data());
    // Replacing an existing project must not silently change its permissions.
    struct stat existing{};
    if (::stat(path.c_str(), &existing) == 0 && ::fchmod(fd, existing.st_mode & 0777) != 0) {
        ::close(fd);
        std::remove(tmp.c_str());
        err = "cannot preserve permissions for " + path;
        return false;
    }
    FILE *f = ::fdopen(fd, "wb");
    if (!f) {
        ::close(fd);
        std::remove(tmp.c_str());
        err = "cannot open temporary file for " + path;
        return false;
    }
    const bool wrote = std::fwrite(data.data(), 1, data.size(), f) == data.size() && std::fflush(f) == 0 &&
                       ::fsync(::fileno(f)) == 0;
    const bool closed = std::fclose(f) == 0;
    if (!wrote || !closed || std::rename(tmp.c_str(), path.c_str()) != 0) {
        std::remove(tmp.c_str());
        err = "failed writing " + path;
        return false;
    }
    return true;
}

int64_t toInt(const json::Value &v, std::string_view key, int64_t fallback = 0) {
    return static_cast<int64_t>(std::llround(v.getNumber(key, static_cast<double>(fallback))));
}
} // namespace

bool syncDirectory(const std::string &dir) {
    const int fd = ::open(dir.c_str(), O_RDONLY);
    if (fd < 0) return false;
    const bool ok = ::fsync(fd) == 0;
    ::close(fd);
    return ok;
}

bool writeFileDurably(const std::string &path, const std::string &data, std::string &err) {
    if (!writeFileAtomically(path, data, err)) return false;
    const auto dir = fs::path(path).parent_path();
    if (!syncDirectory(dir.empty() ? "." : dir.string())) { err = "cannot flush folder of " + path; return false; }
    return true;
}

json::Value Engine::describe() const {
    using json::Value;
    Value root = Value::makeObject();
    root.set("sampleRate", sampleRate_);
    root.set("tempo", model_.bpm());
    {
        json::Value meter = json::Value::makeArray();
        meter.push(model_.meters.front().num);
        meter.push(model_.meters.front().den);
        root.set("meter", std::move(meter));
    }
    if (cycleEnd_.load() > cycleStart_.load()) {
        json::Value cyc = json::Value::makeArray();
        cyc.push(cycleOn_.load());
        cyc.push(static_cast<double>(cycleStart_.load()));
        cyc.push(static_cast<double>(cycleEnd_.load()));
        root.set("cycle", std::move(cyc));
    }
    if (model_.tempo.size() > 1) {
        json::Value map = json::Value::makeArray();
        for (const auto &p : model_.tempo) {
            json::Value point = json::Value::makeArray();
            point.push(p.beat);
            point.push(p.bpm);
            map.push(std::move(point));
        }
        root.set("tempoMap", std::move(map));
    }
    if (model_.meters.size() > 1) {
        json::Value map = json::Value::makeArray();
        for (const auto &m : model_.meters) {
            json::Value point = json::Value::makeArray();
            point.push(m.bar);
            point.push(m.num);
            point.push(m.den);
            map.push(std::move(point));
        }
        root.set("meterMap", std::move(map));
    }

    std::set<DalnokMediaId> used;
    for (const auto &c : model_.clips) used.insert(c.media);
    Value media = Value::makeArray();
    for (const auto id : used) {
        const PoolEntry *e = poolEntry(id);
        if (!e) continue;
        Value m = Value::makeObject();
        m.set("id", id);
        m.set("path", e->path);
        m.set("frames", e->frames);
        m.set("channels", e->channels);
        if (!e->handle->impl) m.set("offline", true);
        media.push(std::move(m));
    }
    root.set("media", std::move(media));

    Value tracks = Value::makeArray();
    std::map<const std::vector<MidiNote> *, int64_t> noteSources;
    for (const auto &t : model_.tracks) {
        Value tv = Value::makeObject();
        tv.set("id", t.id);
        tv.set("name", t.name);
        if (t.kind == kTrackInstrument) { tv.set("kind", "instrument"); tv.set("instrument", "dalnok.poly"); }
        if (t.armed) tv.set("armed", true);
        if (t.inputChannel != 0) tv.set("input", t.inputChannel);
        if (!t.plugins.empty()) {
            Value list = Value::makeArray();
            for (const auto &slot : t.plugins) {
                Value pv = Value::makeObject();
                pv.set("id", slot.id);
                pv.set("format", slot.format);
                pv.set("path", slot.path);
                pv.set("class", slot.classId);
                pv.set("name", slot.name);
                if (!slot.vendor.empty()) pv.set("vendor", slot.vendor);
                if (slot.instrument) pv.set("instrument", true);
                if (!slot.controls.empty()) {
                    Value ids = Value::makeArray();
                    for (auto c : slot.controls) ids.push(static_cast<int64_t>(c));
                    pv.set("controls", std::move(ids));
                }
                std::string state;
                if (!pluginState(slot.id, state)) state = slot.state;
                pv.set("state", base64Encode(state));
                list.push(std::move(pv));
            }
            tv.set("plugins", std::move(list));
        }
        tv.set("color", t.color);
        if (t.customColor >= 0) {
            char hex[8];
            std::snprintf(hex, sizeof hex, "#%06x", t.customColor);
            tv.set("customColor", std::string(hex));
        }
        tv.set("gainDb", std::isfinite(t.gainDb) ? Value(static_cast<double>(t.gainDb)) : Value());
        tv.set("pan", static_cast<double>(t.pan));
        tv.set("mute", t.muted);
        if (t.solo) tv.set("solo", true);
        Value clips = Value::makeArray();
        for (const auto &c : model_.clips) {
            if (c.track != t.id) continue;
            Value cv = Value::makeObject();
            cv.set("id", c.id);
            if (c.midi()) {
                cv.set("kind", "midi");
                const auto source = noteSources.emplace(c.notes.get(), c.id).first;
                cv.set("noteSource", source->second);
                Value notes = Value::makeArray();
                for (const auto &n : *c.notes) {
                    Value nv = Value::makeArray();
                    nv.push(n.start); nv.push(n.length); nv.push(static_cast<int>(n.pitch)); nv.push(static_cast<int>(n.velocity));
                    notes.push(std::move(nv));
                }
                cv.set("notes", std::move(notes));
            } else {
                cv.set("media", c.media);
            }
            cv.set("start", c.start);
            cv.set("offset", c.offset);
            cv.set("length", c.length);
            cv.set("name", c.name);
            if (c.stretched()) {
                cv.set("rate", c.rate);
                if (c.pitch != 0) cv.set("pitch", static_cast<double>(c.pitch));
                if (!c.preservePitch) cv.set("preservePitch", false);
            }
            if (c.gainDb != 0) cv.set("gainDb", std::isfinite(c.gainDb) ? json::Value(static_cast<double>(c.gainDb)) : json::Value());
            if (c.fadeIn > 0) cv.set("fadeIn", c.fadeIn);
            if (c.fadeOut > 0) cv.set("fadeOut", c.fadeOut);
            if (c.fadeCurve != 0) cv.set("fadeCurve", c.fadeCurve == kFadeEqualPower ? "equalPower" : "linear");
            clips.push(std::move(cv));
        }
        tv.set("clips", std::move(clips));
        tracks.push(std::move(tv));
    }
    root.set("tracks", std::move(tracks));
    return root;
}

namespace {
bool sameContents(const fs::path &x, const fs::path &y) {
    std::error_code ec;
    if (fs::file_size(x, ec) != fs::file_size(y, ec) || ec) return false;
    std::ifstream fx(x, std::ios::binary), fy(y, std::ios::binary);
    std::vector<char> bx(1 << 16), by(1 << 16);
    while (fx && fy) {
        fx.read(bx.data(), static_cast<std::streamsize>(bx.size()));
        fy.read(by.data(), static_cast<std::streamsize>(by.size()));
        if (fx.gcount() != fy.gcount() || !std::equal(bx.begin(), bx.begin() + fx.gcount(), by.begin())) return false;
    }
    return true;
}

// Copies `src` into `dir` keeping its name. An identical file already there is
// reused; a different file with the same name gets " 2", " 3", ... appended.
bool copyIntoFolder(const fs::path &src, const fs::path &dir, fs::path &dest, std::string &err) {
    std::error_code ec;
    fs::create_directories(dir, ec);
    if (ec) {
        err = "cannot create " + dir.string() + ": " + ec.message();
        return false;
    }
    const std::string stem = src.stem().string(), ext = src.extension().string();
    for (int n = 1; n < 10000; ++n) {
        dest = dir / (n == 1 ? stem + ext : stem + " " + std::to_string(n) + ext);
        if (!fs::exists(dest)) {
            fs::copy_file(src, dest, ec);
            if (ec) {
                err = "cannot copy " + src.string() + ": " + ec.message();
                return false;
            }
            return true;
        }
        if (sameContents(src, dest)) return true;
    }
    err = "too many files named " + stem + ext;
    return false;
}
} // namespace

bool Engine::saveProject(const std::string &path, std::string &err, bool copyMedia, bool markSaved) {
    const fs::path projectDir = fs::absolute(fs::path(path)).parent_path();
    if (copyMedia) {
        // Copy first; only if every copy succeeds do the pool paths change.
        std::set<DalnokMediaId> used;
        for (const auto &c : model_.clips) used.insert(c.media);
        std::map<DalnokMediaId, std::string> newPaths;
        const fs::path audioDir = projectDir / "Audio Files";
        for (const auto id : used) {
            const PoolEntry *e = poolEntry(id);
            if (!e || e->path.empty() || !fs::exists(e->path)) continue; // offline or generated
            const auto rel = fs::path(e->path).lexically_relative(projectDir);
            if (!rel.empty() && *rel.begin() != "..") continue;         // already inside the project folder
            fs::path dest;
            if (!copyIntoFolder(e->path, audioDir, dest, err)) return false;
            newPaths[id] = dest.string();
        }
        for (const auto &[id, p] : newPaths) pool_[id].path = p;
    }
    json::Value doc = json::Value::makeObject();
    doc.set("format", "dalnok-project");
    doc.set("version", model_.tempo.size() > 1 || model_.meters.size() > 1 ? kFormatVersion : kConstantTempoVersion);
    json::Value body = describe();
    for (auto &[key, value] : body.object) {
        if (key != "media") continue;
        for (auto &m : value.array) {
            const std::string abs = m.getString("path", "");
            if (!abs.empty()) m.set("relativePath", fs::path(abs).lexically_relative(projectDir).generic_string());
        }
    }
    for (auto &kv : body.object) doc.set(kv.first, std::move(kv.second));
    if (!writeFileAtomically(path, json::serialize(doc, true), err)) return false;
    if (markSaved) savedRevision_ = revision_;
    return true;
}

std::unique_ptr<Engine::PreparedProject> Engine::prepareProject(const std::string &path, double sampleRate,
                                                               int32_t &missing, std::string &err) {
    missing = 0;
    std::string text;
    if (!readFile(path, text, err)) return nullptr;
    json::Value doc;
    if (!json::parse(text, doc, err)) {
        err = "invalid project file: " + err;
        return nullptr;
    }
    return prepareDocument(doc, fs::absolute(fs::path(path)).parent_path(), sampleRate, missing, err);
}

std::unique_ptr<Engine::PreparedProject> Engine::prepareDocument(const json::Value &doc, const fs::path &projectDir,
                                                                double sampleRate, int32_t &missing, std::string &err) {
    missing = 0;
    if (!doc.isObject() || doc.getString("format", "") != "dalnok-project") {
        err = "not a Dalnok project";
        return nullptr;
    }
    if (doc.getNumber("version", 0) > kFormatVersion) {
        err = "project was saved by a newer version of Dalnok";
        return nullptr;
    }
    const double fileRate = doc.getNumber("sampleRate", sampleRate);
    if (!(fileRate > 0)) {
        err = "invalid sampleRate";
        return nullptr;
    }
    const double ratio = sampleRate / fileRate;
    auto scale = [ratio](int64_t frames) { return static_cast<int64_t>(std::llround(static_cast<double>(frames) * ratio)); };

    // Build everything into temporaries; swap in only on success.
    std::map<DalnokMediaId, PoolEntry> pool;
    DalnokMediaId maxMedia = 0;
    if (const json::Value *media = doc.get("media"); media && media->isArray()) {
        for (const auto &m : media->array) {
            const auto id = static_cast<DalnokMediaId>(toInt(m, "id"));
            if (id <= 0 || pool.count(id)) {
                err = "invalid media id";
                return nullptr;
            }
            maxMedia = std::max(maxMedia, id);
            PoolEntry e;
            e.path = m.getString("path", "");
            e.frames = scale(toInt(m, "frames"));
            e.channels = static_cast<int32_t>(toInt(m, "channels", 1));
            std::vector<std::string> candidates;
            if (const auto rel = m.getString("relativePath", ""); !rel.empty())
                candidates.push_back((projectDir / rel).lexically_normal().string());
            if (!e.path.empty()) candidates.push_back(e.path);
            std::vector<std::vector<float>> ch;
            std::string decodeErr;
            for (const auto &cand : candidates) {
                if (fs::exists(cand) && decodeAudioFile(cand, sampleRate, ch, decodeErr)) {
                    auto decoded = std::make_shared<const Media>(std::move(ch), sampleRate);
                    e.path = cand;
                    e.frames = decoded->frames();
                    e.channels = decoded->channelCount();
                    e.handle = std::make_unique<DalnokMedia>(DalnokMedia{std::move(decoded)});
                    break;
                }
            }
            if (!e.handle) {
                e.handle = std::make_unique<DalnokMedia>(); // offline
                ++missing;
            }
            pool.emplace(id, std::move(e));
        }
    }

    Model model;
    std::map<int64_t, NoteList> noteSources;
    DalnokTrackId maxTrack = 0;
    DalnokClipId maxClip = 0;
    int32_t maxColor = -1;
    std::set<DalnokClipId> clipIds;
    if (const json::Value *tracks = doc.get("tracks"); tracks && tracks->isArray()) {
        for (const auto &tv : tracks->array) {
            TrackState t;
            t.id = static_cast<DalnokTrackId>(toInt(tv, "id"));
            if (t.id <= 0 || model.track(t.id)) {
                err = "invalid track id";
                return nullptr;
            }
            t.name = tv.getString("name", "Track");
            t.kind = tv.getString("kind", "audio") == "instrument" ? kTrackInstrument : kTrackAudio;
            t.armed = tv.getBool("armed", false);
            t.inputChannel = static_cast<int32_t>(std::clamp<int64_t>(toInt(tv, "input"), 0, 63));
            if (const json::Value *pl = tv.get("plugins"); pl && pl->isArray()) {
                std::set<int32_t> seen;
                for (const auto &pv : pl->array) {
                    PluginSlot slot;
                    slot.id = static_cast<int32_t>(toInt(pv, "id"));
                    slot.format = pv.getString("format", "vst3");
                    slot.path = pv.getString("path", "");
                    slot.classId = pv.getString("class", "");
                    slot.name = pv.getString("name", "Plug-in");
                    slot.vendor = pv.getString("vendor", "");
                    slot.instrument = pv.getBool("instrument", false);
                    if (const json::Value *ids = pv.get("controls"); ids && ids->isArray())
                        for (const auto &c : ids->array)
                            if (c.isNumber() && c.number >= 0 && c.number <= 4294967295.0) slot.controls.push_back(static_cast<uint32_t>(c.number));
                    if (slot.id <= 0 || !seen.insert(slot.id).second || (slot.format != "vst3" && slot.format != "au") ||
                        !base64Decode(pv.getString("state", ""), slot.state)) {
                        err = "invalid plug-in on track " + t.name;
                        return nullptr;
                    }
                    t.plugins.push_back(std::move(slot));
                }
            }
            t.color = static_cast<int32_t>(toInt(tv, "color"));
            if (const auto hex = tv.getString("customColor", ""); hex.size() == 7 && hex[0] == '#')
                t.customColor = static_cast<int32_t>(std::strtol(hex.c_str() + 1, nullptr, 16));
            const json::Value *g = tv.get("gainDb");
            t.gainDb = g && g->isNumber() ? std::min(static_cast<float>(g->number), 12.0f) : -INFINITY;
            if (t.gainDb <= -96.0f) t.gainDb = -INFINITY;
            t.pan = std::clamp(static_cast<float>(tv.getNumber("pan", 0)), -1.0f, 1.0f);
            t.muted = tv.getBool("mute", false);
            t.solo = tv.getBool("solo", false);
            t.runtime = std::make_shared<TrackRuntime>();
            maxTrack = std::max(maxTrack, t.id);
            maxColor = std::max(maxColor, t.color);
            if (const json::Value *clips = tv.get("clips"); clips && clips->isArray()) {
                for (const auto &cv : clips->array) {
                    ClipState c;
                    c.id = static_cast<DalnokClipId>(toInt(cv, "id"));
                    c.track = t.id;
                    c.media = static_cast<DalnokMediaId>(toInt(cv, "media"));
                    c.start = scale(toInt(cv, "start"));
                    c.offset = scale(toInt(cv, "offset"));
                    c.length = scale(toInt(cv, "length"));
                    c.name = cv.getString("name", "Audio");
                    if (cv.getString("kind", "audio") == "midi") {
                        std::vector<MidiNote> notes;
                        if (const json::Value *nv = cv.get("notes"); nv && nv->isArray())
                            for (const auto &n : nv->array) {
                                if (!n.isArray() || n.array.size() < 4 || !n.array[0].isNumber() || !n.array[1].isNumber() ||
                                    !n.array[2].isNumber() || !n.array[3].isNumber()) {
                                    err = "invalid MIDI note";
                                    return nullptr;
                                }
                                MidiNote note;
                                note.start = scale(static_cast<int64_t>(std::llround(n.array[0].number)));
                                note.length = std::max<int64_t>(1, scale(static_cast<int64_t>(std::llround(n.array[1].number))));
                                note.pitch = static_cast<uint8_t>(std::clamp(n.array[2].number, 0.0, 127.0));
                                note.velocity = static_cast<uint8_t>(std::clamp(n.array[3].number, 1.0, 127.0));
                                if (note.start < 0) { err = "invalid MIDI note"; return nullptr; }
                                notes.push_back(note);
                            }
                        std::stable_sort(notes.begin(), notes.end(), [](const MidiNote &a, const MidiNote &b) { return a.start < b.start; });
                        c.media = 0;
                        const int64_t source = toInt(cv, "noteSource", 0);
                        auto it = noteSources.find(source);
                        if (source > 0 && it != noteSources.end()) {
                            const auto &existing = *it->second;
                            if (existing.size() != notes.size() || !std::equal(existing.begin(), existing.end(), notes.begin(),
                                    [](const MidiNote &a, const MidiNote &b) {
                                        return a.start == b.start && a.length == b.length && a.pitch == b.pitch && a.velocity == b.velocity;
                                    })) {
                                err = "inconsistent shared MIDI source";
                                return nullptr;
                            }
                            c.notes = it->second;
                        } else {
                            c.notes = std::make_shared<const std::vector<MidiNote>>(std::move(notes));
                            if (source > 0) noteSources.emplace(source, c.notes);
                        }
                        if (c.id <= 0 || !clipIds.insert(c.id).second || t.kind != kTrackInstrument || c.start < 0 ||
                            c.offset < 0 || c.length <= 0) {
                            err = "invalid MIDI clip";
                            return nullptr;
                        }
                        maxClip = std::max(maxClip, c.id);
                        model.clips.push_back(std::move(c));
                        continue;
                    }
                    if (const json::Value *g = cv.get("gainDb"))
                        c.gainDb = g->isNumber() ? std::min(static_cast<float>(g->number), 24.0f) : -INFINITY;
                    if (c.gainDb <= -96.0f) c.gainDb = -INFINITY;
                    c.rate = std::clamp(cv.getNumber("rate", 1.0), 0.05, 20.0);
                    c.pitch = static_cast<float>(std::clamp(cv.getNumber("pitch", 0.0), -48.0, 48.0));
                    c.preservePitch = cv.getBool("preservePitch", true);
                    c.fadeIn = std::max<int64_t>(0, scale(toInt(cv, "fadeIn")));
                    c.fadeOut = std::max<int64_t>(0, scale(toInt(cv, "fadeOut")));
                    c.fadeCurve = cv.getString("fadeCurve", "linear") == "equalPower" ? kFadeEqualPower : kFadeLinear;
                    auto pe = pool.find(c.media);
                    if (c.id <= 0 || !clipIds.insert(c.id).second || pe == pool.end() || c.start < 0 ||
                        c.offset < 0 || c.length <= 0) {
                        err = "invalid clip";
                        return nullptr;
                    }
                    // Rounding from rate conversion can overshoot by a frame. Offline media has no
                    // trustworthy length, so its clips keep the lengths stored in the project.
                    if (pe->second.handle->impl)
                        c.length = std::min(c.length, std::max<int64_t>(1, static_cast<int64_t>(
                            static_cast<double>(pe->second.frames - c.offset) / c.rate)));
                    else
                        pe->second.frames = std::max(pe->second.frames, c.offset + c.length);
                    maxClip = std::max(maxClip, c.id);
                    model.clips.push_back(std::move(c));
                }
            }
            model.tracks.push_back(std::move(t));
        }
    }

    model.tempo.front().bpm = std::clamp(doc.getNumber("tempo", 120), 20.0, 400.0);
    if (const json::Value *meter = doc.get("meter"); meter && meter->isArray() && meter->array.size() == 2 &&
        meter->array[0].isNumber() && meter->array[1].isNumber()) {
        model.meters.front().num = static_cast<int32_t>(std::clamp(meter->array[0].number, 1.0, 32.0));
        const int den = static_cast<int>(meter->array[1].number);
        model.meters.front().den = (den == 1 || den == 2 || den == 4 || den == 8 || den == 16) ? den : 4;
    }
    // Maps are validated as a whole; a damaged map is an error rather than a silent timing change.
    if (const json::Value *map = doc.get("tempoMap")) {
        std::vector<TempoPoint> tempo;
        if (map->isArray())
            for (const auto &p : map->array)
                if (p.isArray() && p.array.size() == 2 && p.array[0].isNumber() && p.array[1].isNumber())
                    tempo.push_back({p.array[0].number, p.array[1].number});
        TempoMap check;
        std::string why;
        if (!map->isArray() || tempo.size() != map->array.size() || !TempoMap::build(sampleRate, tempo, check, why)) {
            err = "project has an invalid tempo map" + (why.empty() ? std::string() : ": " + why);
            return nullptr;
        }
        model.tempo = std::move(tempo);
    }
    if (const json::Value *map = doc.get("meterMap")) {
        std::vector<MeterChange> meters;
        if (map->isArray())
            for (const auto &p : map->array)
                if (p.isArray() && p.array.size() == 3 && p.array[0].isNumber() && p.array[1].isNumber() && p.array[2].isNumber())
                    meters.push_back({static_cast<int32_t>(p.array[0].number), static_cast<int32_t>(p.array[1].number),
                                      static_cast<int32_t>(p.array[2].number)});
        std::string why;
        if (!map->isArray() || meters.size() != map->array.size() || !validMeters(meters, why)) {
            err = "project has an invalid meter map" + (why.empty() ? std::string() : ": " + why);
            return nullptr;
        }
        model.meters = std::move(meters);
    }
    auto prepared = std::make_unique<PreparedProject>();
    if (const json::Value *cyc = doc.get("cycle"); cyc && cyc->isArray() && cyc->array.size() == 3 &&
        cyc->array[1].isNumber() && cyc->array[2].isNumber()) {
        prepared->cycleOn = cyc->array[0].isBool() && cyc->array[0].boolean;
        prepared->cycleStart = static_cast<int64_t>(std::llround(cyc->array[1].number * ratio));
        prepared->cycleEnd = static_cast<int64_t>(std::llround(cyc->array[2].number * ratio));
    }
    // Render stretched clips now (we're off the main thread) so playback is ready on apply.
    for (const auto &c : model.clips) {
        if (!c.stretched()) continue;
        const auto pe = pool.find(c.media);
        if (pe == pool.end() || !pe->second.handle->impl) continue;
        const StretchKey key{c.media, c.offset, c.sourceLength(), c.length, static_cast<int32_t>(std::lround(c.pitch * 100)), c.preservePitch};
        bool have = false;
        for (const auto &s : prepared->stretched) have |= !(s.first < key) && !(key < s.first);
        if (!have)
            if (auto m = renderStretch({key, pe->second.handle->impl, 0})) prepared->stretched.emplace_back(key, std::move(m));
    }
    prepared->model = std::move(model);
    prepared->pool = std::move(pool);
    prepared->maxTrack = maxTrack;
    prepared->maxClip = maxClip;
    prepared->maxMedia = maxMedia;
    prepared->maxColor = maxColor;
    prepared->sampleRate = sampleRate;
    return prepared;
}

void Engine::applyProject(std::unique_ptr<PreparedProject> p, bool recovered) {
    resetModel();
    for (auto &[k, m] : p->stretched) cache_.insert(k, std::move(m));
    model_ = std::move(p->model);
    pool_ = std::move(p->pool);
    instantiatePlugins(); // loads plugin code on this (control) thread; missing plugins keep their state
    nextTrack_ = std::max(nextTrack_, p->maxTrack + 1);
    nextClip_ = std::max(nextClip_, p->maxClip + 1);
    nextMedia_ = std::max(nextMedia_, p->maxMedia + 1);
    nextColor_ = p->maxColor + 1;
    std::string ignored;
    if (!setCycle(p->cycleOn, p->cycleStart, p->cycleEnd, ignored)) cycleOn_.store(false, std::memory_order_release);
    syncRuntimes();
    ++revision_;
    savedRevision_ = (p->imported || recovered) ? revision_ - 1 : revision_; // an import is unsaved work
    commit();
}

std::unique_ptr<Engine::PreparedProject> Engine::prepareImport(const std::string &path, double sampleRate,
                                                              int32_t &missing, std::string &reportJson, std::string &err) {
    import::Result r;
    if (!import::importProject(path, r, err)) return nullptr;
    reportJson = json::serialize(r.report.toJson(), true);
    auto p = prepareDocument(r.document, fs::absolute(fs::path(path)).parent_path(), sampleRate, missing, err);
    if (p) p->imported = true;
    return p;
}

bool Engine::loadProject(const std::string &path, int32_t &missing, std::string &err) {
    auto p = prepareProject(path, sampleRate_, missing, err);
    if (!p) return false;
    applyProject(std::move(p));
    return true;
}

} // namespace dalnok
