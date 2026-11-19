// Final Cut Pro XML import (Apple's documented interchange format; Logic Pro
// exports it via File ▸ Export ▸ Project to Final Cut Pro XML). Imports audio
// asset-clips/clips from the primary spine and connected lanes. Each distinct
// lane/role becomes a track. Rational times ("1001/48000s") are honored.
// SPDX-License-Identifier: GPL-3.0-or-later
#include <algorithm>
#include <cstdlib>
#include <cctype>
#include "import/import.hpp"

#include <pugixml.hpp>

#include <cmath>
#include <filesystem>
#include <map>

namespace fs = std::filesystem;

namespace dalnok::import {

namespace {

// "N/Ds", "Ns", or "" -> seconds.
double rt(const char *s) {
    if (!s || !*s) return 0;
    std::string v(s);
    if (!v.empty() && v.back() == 's') v.pop_back();
    const auto slash = v.find('/');
    try {
        if (slash == std::string::npos) return std::stod(v);
        const double d = std::stod(v.substr(slash + 1));
        return d != 0 ? std::stod(v.substr(0, slash)) / d : 0;
    } catch (...) { return 0; }
}

std::string urlToPath(std::string u) {
    if (u.rfind("file://", 0) == 0) u = u.substr(7);
    if (u.rfind("localhost", 0) == 0) u = u.substr(9);
    std::string out;
    for (size_t i = 0; i < u.size(); ++i) {
        if (u[i] == '%' && i + 2 < u.size() && std::isxdigit(static_cast<unsigned char>(u[i + 1])) &&
            std::isxdigit(static_cast<unsigned char>(u[i + 2]))) { // a malformed escape stays literal (found by fuzzing)
            out += static_cast<char>(std::strtol(u.substr(i + 1, 2).c_str(), nullptr, 16));
            i += 2;
        } else {
            out += u[i];
        }
    }
    return out;
}

struct Ctx {
    Builder &b;
    Report &rep;
    std::map<std::string, std::string> assets; // id -> file path
    std::map<std::string, int32_t> tracks;     // lane/role key -> track
    fs::path dir;
};

int32_t trackFor(Ctx &c, const pugi::xml_node &clip, int lane) {
    std::string role = clip.attribute("audioRole").as_string();
    if (role.empty()) role = clip.attribute("role").as_string();
    std::string key = std::to_string(lane) + "|" + role;
    if (auto it = c.tracks.find(key); it != c.tracks.end()) return it->second;
    std::string name = role.empty() ? (lane == 0 ? std::string("Main") : "Lane " + std::to_string(lane)) : role;
    if (const auto dot = name.find('.'); dot != std::string::npos) name = name.substr(dot + 1); // "dialogue.Vox" -> "Vox"
    const int32_t t = c.b.addTrack(name, 0, 0, false, false);
    c.tracks[key] = t;
    return t;
}

// Walks a container's children. `parentTimelineStart` = where the container's
// own time `parentStart` sits on the project timeline.
void walk(Ctx &c, const pugi::xml_node &container, double parentTimelineStart, double parentStart, int depth) {
    if (depth > 16) return;
    for (const auto &n : container.children()) {
        const std::string tag = n.name();
        const double offset = rt(n.attribute("offset").as_string());
        const double start = rt(n.attribute("start").as_string());
        const double duration = rt(n.attribute("duration").as_string());
        const int lane = n.attribute("lane").as_int(0);
        const double timelineStart = parentTimelineStart + (offset - parentStart);
        if (tag == "asset-clip" || tag == "audio") {
            const auto it = c.assets.find(n.attribute("ref").as_string());
            if (it == c.assets.end() || it->second.empty()) { c.rep.skip("unresolvedAssets"); continue; }
            const int32_t media = c.b.addMedia(it->second);
            float gain = 0;
            if (const auto av = n.child("adjust-volume")) {
                std::string amt = av.attribute("amount").as_string();
                if (amt.size() > 2 && amt.substr(amt.size() - 2) == "dB") {
                    char *end = nullptr;
                    const std::string number = amt.substr(0, amt.size() - 2);
                    const double db = std::strtod(number.c_str(), &end);
                    if (end != number.c_str() && std::isfinite(db)) gain = static_cast<float>(std::clamp(db, -144.0, 24.0));
                }
            }
            c.b.addClip(trackFor(c, n, lane), media, timelineStart, start, duration, n.attribute("name").as_string(), gain);
            walk(c, n, timelineStart, start, depth + 1); // connected clips on this clip
        } else if (tag == "gap" || tag == "spine" || tag == "clip" || tag == "ref-clip" || tag == "mc-clip" || tag == "sync-clip") {
            if (tag == "ref-clip" || tag == "mc-clip") c.rep.skip("compoundClipsFlattened");
            walk(c, n, tag == "spine" ? parentTimelineStart : timelineStart, tag == "spine" ? parentStart : start, depth + 1);
        } else if (tag == "video" || tag == "title") {
            c.rep.skip("videoOrTitles");
        }
    }
}

} // namespace

bool importFcpxml(const std::string &path, Result &out, std::string &err) {
    fs::path file(path);
    if (fs::is_directory(file)) file /= "Info.fcpxml"; // .fcpxmld bundle
    pugi::xml_document doc;
    if (const auto r = doc.load_file(file.c_str()); !r) {
        err = std::string("not a valid FCPXML file: ") + r.description();
        return false;
    }
    const auto root = doc.child("fcpxml");
    if (!root) {
        err = "not an FCPXML document";
        return false;
    }
    Report &rep = out.report;
    rep.app = "Final Cut Pro XML";
    rep.version = root.attribute("version").as_string();
    Builder b(rep, 48000);
    Ctx c{b, rep, {}, {}, fs::absolute(file).parent_path()};
    for (const auto &a : root.child("resources").children("asset")) {
        std::string src = a.attribute("src").as_string();
        if (src.empty()) src = a.child("media-rep").attribute("src").as_string();
        std::string p = urlToPath(src);
        if (!p.empty() && !fs::exists(p)) p = locateMedia(p, c.dir.string());
        c.assets[a.attribute("id").as_string()] = p;
    }
    int sequences = 0;
    for (const auto &x : root.select_nodes("//sequence")) {
        if (sequences++) { rep.skip("additionalSequences"); continue; }
        const auto spine = x.node().child("spine");
        walk(c, spine, 0, rt(x.node().attribute("tcStart").as_string()) * 0, 0);
    }
    if (!sequences) {
        err = "no sequence/project found in FCPXML";
        return false;
    }
    out.document = b.document();
    if (rep.missingMedia) rep.notes.push_back(std::to_string(rep.missingMedia) + " audio file(s) not found; clips are offline until relinked.");
    return true;
}

} // namespace dalnok::import
