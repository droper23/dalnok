// SPDX-License-Identifier: GPL-3.0-or-later
#include "import/import.hpp"
#include "media.hpp"

#include <algorithm>
#include <cmath>
#include <filesystem>

namespace fs = std::filesystem;

namespace dalnok::import {

float linearToDb(double v) { return v <= 0.0000158 ? -INFINITY : static_cast<float>(20.0 * std::log10(v)); }

std::string locateMedia(const std::string &reference, const std::string &projectDir) {
    if (reference.empty()) return reference;
    std::string ref = reference;
    std::replace(ref.begin(), ref.end(), '\\', '/');
    const bool windowsAbsolute = ref.size() > 2 && ref[1] == ':' && ref[2] == '/';
    if (windowsAbsolute) ref = ref.substr(2);
    const fs::path p(ref), dir(projectDir);
    std::error_code ec;
    if (!windowsAbsolute) {
        const fs::path candidate = p.is_absolute() ? p : (dir / p).lexically_normal();
        if (fs::exists(candidate, ec)) return candidate.string();
    }
    // Moved archives keep their inner layout: try the longest tail of the original
    // path under each ancestor of the project folder ("…/Zene/ABLETON/X Project/Samples/a.wav").
    std::vector<fs::path> parts(p.begin(), p.end());
    std::vector<fs::path> ancestors;
    for (fs::path d = dir; !d.empty() && ancestors.size() < 5; d = d.parent_path()) {
        ancestors.push_back(d);
        if (d == d.parent_path()) break;
    }
    for (size_t skip = 0; skip + 1 < parts.size(); ++skip) {
        fs::path tail;
        for (size_t i = skip; i < parts.size(); ++i)
            if (parts[i] != "/") tail /= parts[i];
        if (tail.empty()) continue;
        for (const auto &anc : ancestors)
            if (fs::exists(anc / tail, ec)) return (anc / tail).lexically_normal().string();
    }
    // Last resort: search by file name under the project folder (and its parent for Backup/ sets).
    const auto name = p.filename();
    const fs::path searchRoot = dir.filename() == "Backup" ? dir.parent_path() : dir;
    int visited = 0;
    for (auto it = fs::recursive_directory_iterator(searchRoot, fs::directory_options::skip_permission_denied, ec);
         it != fs::recursive_directory_iterator() && visited < 20000; it.increment(ec), ++visited) {
        if (ec) break;
        if (it.depth() > 4) { it.disable_recursion_pending(); continue; }
        if (it->path().filename() == name && it->is_regular_file(ec)) return it->path().string();
    }
    return windowsAbsolute ? reference : (p.is_absolute() ? p : (dir / p).lexically_normal()).string();
}

json::Value Report::toJson() const {
    json::Value r = json::Value::makeObject();
    r.set("app", app);
    r.set("version", version);
    json::Value imported = json::Value::makeObject();
    imported.set("tracks", tracks);
    imported.set("clips", clips);
    imported.set("media", media);
    imported.set("missingMedia", missingMedia);
    r.set("imported", std::move(imported));
    json::Value sk = json::Value::makeObject();
    for (const auto &[k, n] : skipped) sk.set(k, n);
    r.set("skipped", std::move(sk));
    json::Value notesV = json::Value::makeArray();
    for (const auto &n : notes) notesV.push(n);
    r.set("notes", std::move(notesV));
    return r;
}

int64_t Builder::frames(double seconds) const { return static_cast<int64_t>(std::llround(seconds * rate_)); }

int32_t Builder::addMedia(const std::string &path) {
    if (path.empty()) return 0;
    if (auto it = mediaByPath_.find(path); it != mediaByPath_.end()) return it->second;
    Media m;
    m.path = path;
    std::string err;
    double sr = 0;
    int64_t n = 0;
    if (fs::exists(path) && probeAudioFile(path, sr, n, m.channels, err)) {
        m.exists = true;
        m.seconds = static_cast<double>(n) / sr;
        m.frames = frames(m.seconds);
    } else {
        ++report_.missingMedia;
    }
    media_.push_back(m);
    const auto id = static_cast<int32_t>(media_.size());
    mediaByPath_[path] = id;
    ++report_.media;
    return id;
}

double Builder::mediaSeconds(int32_t media) const {
    return media > 0 && media <= static_cast<int32_t>(media_.size()) ? media_[static_cast<size_t>(media - 1)].seconds : 0;
}

int32_t Builder::addTrack(const std::string &name, float gainDb, float pan, bool mute, bool solo) {
    tracks_.push_back({name.empty() ? "Track " + std::to_string(tracks_.size() + 1) : name, gainDb,
                       std::clamp(pan, -1.0f, 1.0f), mute, solo, {}});
    ++report_.tracks;
    return static_cast<int32_t>(tracks_.size() - 1);
}

int32_t Builder::addInstrumentTrack(const std::string &name) {
    const int32_t t = addTrack(name, 0, 0, false, false);
    tracks_[static_cast<size_t>(t)].instrument = true;
    return t;
}

void Builder::addMidiClip(int32_t track, double start, double length, const std::vector<Note> &notes, const std::string &name) {
    if (track < 0 || track >= static_cast<int32_t>(tracks_.size()) || length <= 0) return;
    Clip c{0, frames(std::max(0.0, start)), 0, std::max<int64_t>(1, frames(length)), 0, 0, false, 0, name, {}};
    c.midi = true;
    for (const auto &n : notes) {
        if (!(n.start >= 0) || !(n.length > 0) || n.pitch < 0 || n.pitch > 127) { report_.skip("invalidNotes"); continue; }
        c.notes.push_back({frames(n.start), std::max<int64_t>(1, frames(n.length)), n.pitch, std::clamp(n.velocity, 1, 127)});
    }
    tracks_[static_cast<size_t>(track)].clips.push_back(std::move(c));
    ++report_.clips;
}

void Builder::addClip(int32_t track, int32_t media, double start, double offset, double length, const std::string &name,
                      float gainDb, double fadeIn, double fadeOut, bool equalPower, Stretch st) {
    if (track < 0 || track >= static_cast<int32_t>(tracks_.size()) || media <= 0) return;
    start = std::max(0.0, start);
    offset = std::max(0.0, offset);
    if (!(st.rate > 0.05 && st.rate < 20)) st.rate = 1;
    if (std::fabs(st.rate - 1) < 1e-4) st.rate = 1;
    const double avail = mediaSeconds(media);
    if (avail > 0) length = std::min(length, (avail - offset) / st.rate);
    if (length <= 0) {
        report_.skip("clipOutsideSource");
        return;
    }
    tracks_[static_cast<size_t>(track)].clips.push_back(
        {media, frames(start), frames(offset), std::max<int64_t>(1, frames(length)), frames(std::max(0.0, fadeIn)),
         frames(std::max(0.0, fadeOut)), equalPower, gainDb, name, st});
    ++report_.clips;
}

void Builder::addLoopedClip(int32_t track, int32_t media, double start, double length, double firstOffset,
                            double loopStart, double loopEnd, const std::string &name, float gainDb, Stretch st) {
    const double loopLen = loopEnd - loopStart, r = st.rate > 0 ? st.rate : 1;
    if (loopLen <= 1e-6) {
        addClip(track, media, start, firstOffset, length, name, gainDb, 0, 0, false, st);
        return;
    }
    double t = 0, offset = firstOffset;
    int guard = 0;
    while (t < length - 1e-9 && guard++ < 100000) {
        const double seg = std::min((loopEnd - offset) / r, length - t); // timeline seconds
        if (seg <= 1e-9) { offset = loopStart; continue; }
        addClip(track, media, start + t, offset, seg, name, gainDb, 0, 0, false, st);
        t += seg;
        offset = loopStart;
    }
}

json::Value Builder::document() const {
    using json::Value;
    Value doc = Value::makeObject();
    doc.set("format", "dalnok-project");
    doc.set("version", 1);
    doc.set("sampleRate", rate_);
    Value media = Value::makeArray();
    for (size_t i = 0; i < media_.size(); ++i) {
        Value m = Value::makeObject();
        m.set("id", static_cast<int64_t>(i + 1));
        m.set("path", media_[i].path);
        m.set("frames", media_[i].frames);
        m.set("channels", media_[i].channels);
        media.push(std::move(m));
    }
    doc.set("media", std::move(media));
    Value tracks = Value::makeArray();
    int64_t clipId = 1;
    for (size_t i = 0; i < tracks_.size(); ++i) {
        const Track &t = tracks_[i];
        Value tv = Value::makeObject();
        tv.set("id", static_cast<int64_t>(i + 1));
        tv.set("name", t.name);
        tv.set("color", static_cast<int64_t>(i));
        if (t.instrument) { tv.set("kind", "instrument"); tv.set("instrument", "dalnok.poly"); }
        tv.set("gainDb", std::isfinite(t.gainDb) ? Value(static_cast<double>(t.gainDb)) : Value());
        tv.set("pan", static_cast<double>(t.pan));
        tv.set("mute", t.mute);
        if (t.solo) tv.set("solo", true);
        Value clips = Value::makeArray();
        for (const Clip &c : t.clips) {
            Value cv = Value::makeObject();
            cv.set("id", clipId++);
            if (c.midi) {
                cv.set("kind", "midi");
                Value notes = Value::makeArray();
                for (const auto &n : c.notes) {
                    Value nv = Value::makeArray();
                    for (auto x : n) nv.push(x);
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
            if (c.gainDb != 0) cv.set("gainDb", std::isfinite(c.gainDb) ? Value(static_cast<double>(c.gainDb)) : Value());
            if (c.fadeIn > 0) cv.set("fadeIn", c.fadeIn);
            if (c.fadeOut > 0) cv.set("fadeOut", c.fadeOut);
            if (c.equalPower) cv.set("fadeCurve", "equalPower");
            if (c.st.rate != 1 || c.st.pitch != 0) {
                cv.set("rate", c.st.rate);
                if (c.st.pitch != 0) cv.set("pitch", static_cast<double>(c.st.pitch));
                if (!c.st.preservePitch) cv.set("preservePitch", false);
            }
            clips.push(std::move(cv));
        }
        tv.set("clips", std::move(clips));
        tracks.push(std::move(tv));
    }
    doc.set("tracks", std::move(tracks));
    // MIDI and instrument tracks need project version 2.
    if (std::any_of(tracks_.begin(), tracks_.end(), [](const Track &t) { return t.instrument; })) doc.set("version", 2);
    return doc;
}

bool importProject(const std::string &path, Result &out, std::string &err) {
    const fs::path p(path);
    std::error_code ec;
    if (!fs::exists(p, ec)) {
        err = "cannot open " + path;
        return false;
    }
    auto ext = p.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    if (ext == ".rpp") return importReaper(path, out, err);
    if (ext == ".als") return importAbleton(path, out, err);
    if (ext == ".logicx") return importLogic(path, out, err);
    if (ext == ".fcpxml" || ext == ".fcpxmld") return importFcpxml(path, out, err);
    if (ext == ".dawproject") return importDawproject(path, out, err);
    if (fs::is_directory(p, ec)) return importStems(path, out, err);
    err = "unsupported project type '" + ext + "' (supported: .rpp, .als, .logicx, .fcpxml, .dawproject, or a folder of stems)";
    return false;
}

} // namespace dalnok::import
