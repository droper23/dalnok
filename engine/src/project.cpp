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
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace dalnok {

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

json::Value Engine::describe() const {
    using json::Value;
    Value root = Value::makeObject();
    root.set("sampleRate", sampleRate_);

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
    for (const auto &t : model_.tracks) {
        Value tv = Value::makeObject();
        tv.set("id", t.id);
        tv.set("name", t.name);
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
            cv.set("media", c.media);
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
    doc.set("version", kFormatVersion);
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

    auto prepared = std::make_unique<PreparedProject>();
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
    nextTrack_ = std::max(nextTrack_, p->maxTrack + 1);
    nextClip_ = std::max(nextClip_, p->maxClip + 1);
    nextMedia_ = std::max(nextMedia_, p->maxMedia + 1);
    nextColor_ = p->maxColor + 1;
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
