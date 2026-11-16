// Project persistence: versioned JSON, atomic writes, offline media on load.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Format (version 1):
// {
//   "format": "atrium-project", "version": 1, "sampleRate": 48000,
//   "media":  [{"id", "path", "relativePath", "frames", "channels"}],
//   "tracks": [{"id", "name", "color", "gainDb" (null = -inf), "pan", "mute",
//               "clips": [{"id", "media", "start", "offset", "length", "name"}]}]
// }
// Positions are frames at "sampleRate"; loading into an engine at another
// rate rescales them.
#include "engine.hpp"

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <set>
#include <sstream>
#include <unistd.h>

namespace fs = std::filesystem;

namespace atrium {

namespace {
constexpr int kFormatVersion = 1;

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
    const std::string tmp = path + ".tmp-" + std::to_string(::getpid());
    FILE *f = std::fopen(tmp.c_str(), "wb");
    if (!f) {
        err = "cannot write " + tmp;
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

json::Value Engine::describe() const {
    using json::Value;
    Value root = Value::makeObject();
    root.set("sampleRate", sampleRate_);

    std::set<AtriumMediaId> used;
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
    for (const auto &t : model_.tracks) {
        Value tv = Value::makeObject();
        tv.set("id", t.id);
        tv.set("name", t.name);
        tv.set("color", t.color);
        tv.set("gainDb", std::isfinite(t.gainDb) ? Value(static_cast<double>(t.gainDb)) : Value());
        tv.set("pan", static_cast<double>(t.pan));
        tv.set("mute", t.muted);
        Value clips = Value::makeArray();
        for (const auto &c : model_.clips) {
            if (c.track != t.id) continue;
            Value cv = Value::makeObject();
            cv.set("id", c.id);
            cv.set("media", c.media);
            cv.set("start", c.start);
            cv.set("offset", c.offset);
            cv.set("length", c.length);
            cv.set("name", c.name);
            clips.push(std::move(cv));
        }
        tv.set("clips", std::move(clips));
        tracks.push(std::move(tv));
    }
    root.set("tracks", std::move(tracks));
    return root;
}

bool Engine::saveProject(const std::string &path, std::string &err) {
    json::Value doc = json::Value::makeObject();
    doc.set("format", "atrium-project");
    doc.set("version", kFormatVersion);
    json::Value body = describe();
    const fs::path projectDir = fs::absolute(fs::path(path)).parent_path();
    for (auto &[key, value] : body.object) {
        if (key != "media") continue;
        for (auto &m : value.array) {
            const std::string abs = m.getString("path", "");
            if (!abs.empty()) m.set("relativePath", fs::path(abs).lexically_relative(projectDir).generic_string());
        }
    }
    for (auto &kv : body.object) doc.set(kv.first, std::move(kv.second));
    if (!writeFileAtomically(path, json::serialize(doc, true), err)) return false;
    savedRevision_ = revision_;
    return true;
}

bool Engine::loadProject(const std::string &path, int32_t &missing, std::string &err) {
    missing = 0;
    std::string text;
    if (!readFile(path, text, err)) return false;
    json::Value doc;
    if (!json::parse(text, doc, err)) {
        err = "invalid project file: " + err;
        return false;
    }
    if (!doc.isObject() || doc.getString("format", "") != "atrium-project") {
        err = "not an Atrium project";
        return false;
    }
    if (doc.getNumber("version", 0) > kFormatVersion) {
        err = "project was saved by a newer version of Atrium";
        return false;
    }
    const double fileRate = doc.getNumber("sampleRate", sampleRate_);
    if (!(fileRate > 0)) {
        err = "invalid sampleRate";
        return false;
    }
    const double ratio = sampleRate_ / fileRate;
    auto scale = [ratio](int64_t frames) { return static_cast<int64_t>(std::llround(static_cast<double>(frames) * ratio)); };
    const fs::path projectDir = fs::absolute(fs::path(path)).parent_path();

    // Build everything into temporaries; swap in only on success.
    std::map<AtriumMediaId, PoolEntry> pool;
    AtriumMediaId maxMedia = 0;
    if (const json::Value *media = doc.get("media"); media && media->isArray()) {
        for (const auto &m : media->array) {
            const auto id = static_cast<AtriumMediaId>(toInt(m, "id"));
            if (id <= 0 || pool.count(id)) {
                err = "invalid media id";
                return false;
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
                if (fs::exists(cand) && decodeAudioFile(cand, sampleRate_, ch, decodeErr)) {
                    auto decoded = std::make_shared<const Media>(std::move(ch), sampleRate_);
                    e.path = cand;
                    e.frames = decoded->frames();
                    e.channels = decoded->channelCount();
                    e.handle = std::make_unique<AtriumMedia>(AtriumMedia{std::move(decoded)});
                    break;
                }
            }
            if (!e.handle) {
                e.handle = std::make_unique<AtriumMedia>(); // offline
                ++missing;
            }
            pool.emplace(id, std::move(e));
        }
    }

    Model model;
    AtriumTrackId maxTrack = 0;
    AtriumClipId maxClip = 0;
    int32_t maxColor = -1;
    std::set<AtriumClipId> clipIds;
    if (const json::Value *tracks = doc.get("tracks"); tracks && tracks->isArray()) {
        for (const auto &tv : tracks->array) {
            TrackState t;
            t.id = static_cast<AtriumTrackId>(toInt(tv, "id"));
            if (t.id <= 0 || model.track(t.id)) {
                err = "invalid track id";
                return false;
            }
            t.name = tv.getString("name", "Track");
            t.color = static_cast<int32_t>(toInt(tv, "color"));
            const json::Value *g = tv.get("gainDb");
            t.gainDb = g && g->isNumber() ? std::min(static_cast<float>(g->number), 12.0f) : -INFINITY;
            if (t.gainDb <= -96.0f) t.gainDb = -INFINITY;
            t.pan = std::clamp(static_cast<float>(tv.getNumber("pan", 0)), -1.0f, 1.0f);
            t.muted = tv.getBool("mute", false);
            t.runtime = std::make_shared<TrackRuntime>();
            maxTrack = std::max(maxTrack, t.id);
            maxColor = std::max(maxColor, t.color);
            if (const json::Value *clips = tv.get("clips"); clips && clips->isArray()) {
                for (const auto &cv : clips->array) {
                    ClipState c;
                    c.id = static_cast<AtriumClipId>(toInt(cv, "id"));
                    c.track = t.id;
                    c.media = static_cast<AtriumMediaId>(toInt(cv, "media"));
                    c.start = scale(toInt(cv, "start"));
                    c.offset = scale(toInt(cv, "offset"));
                    c.length = scale(toInt(cv, "length"));
                    c.name = cv.getString("name", "Audio");
                    auto pe = pool.find(c.media);
                    if (c.id <= 0 || !clipIds.insert(c.id).second || pe == pool.end() || c.start < 0 ||
                        c.offset < 0 || c.length <= 0) {
                        err = "invalid clip";
                        return false;
                    }
                    // Rounding from rate conversion can overshoot by a frame.
                    c.length = std::min(c.length, std::max<int64_t>(1, pe->second.frames - c.offset));
                    maxClip = std::max(maxClip, c.id);
                    model.clips.push_back(std::move(c));
                }
            }
            model.tracks.push_back(std::move(t));
        }
    }

    resetModel();
    model_ = std::move(model);
    pool_ = std::move(pool);
    nextTrack_ = std::max(nextTrack_, maxTrack + 1);
    nextClip_ = std::max(nextClip_, maxClip + 1);
    nextMedia_ = std::max(nextMedia_, maxMedia + 1);
    nextColor_ = maxColor + 1;
    syncRuntimes();
    ++revision_;
    savedRevision_ = revision_;
    commit();
    return true;
}

} // namespace atrium
