// DAWproject import (.dawproject: a ZIP with project.xml and audio). Audio clips, fades and warp-marker
// time-stretch come over; the audio is extracted next to the file ("<name> Audio Files/", reused when already
// there). MIDI notes, plug-ins, automation, sends and submix routing are counted in the report.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "import/import.hpp"
#include "zip.hpp"

#include <pugixml.hpp>

#include <cmath>
#include <filesystem>
#include <functional>
#include <map>

namespace fs = std::filesystem;

namespace dalnok::import {
namespace {
double attr(pugi::xml_node n, const char *name, double fallback) {
    const auto a = n.attribute(name);
    return a ? a.as_double(fallback) : fallback;
}
// A Clip's media: Audio directly inside, or inside Warps (two warp markers give a constant rate).
struct Source { pugi::xml_node audio; double rate = 1; double contentStart = 0; bool warped = false; };
Source source(pugi::xml_node clip) {
    Source s;
    if (auto a = clip.child("Audio")) { s.audio = a; return s; }
    if (auto w = clip.child("Warps")) {
        s.audio = w.child("Audio");
        std::vector<std::pair<double, double>> marks;
        for (auto m : w.children("Warp")) marks.emplace_back(attr(m, "time", 0), attr(m, "contentTime", 0));
        if (marks.size() >= 2 && marks.back().first > marks.front().first) {
            s.rate = (marks.back().second - marks.front().second) / (marks.back().first - marks.front().first);
            s.contentStart = marks.front().second - marks.front().first * s.rate;
            s.warped = true;
        }
    }
    return s;
}
} // namespace

bool importDawproject(const std::string &path, Result &out, std::string &err) {
    zip::Reader z;
    if (!z.open(path, err)) return false;
    const zip::Entry *entry = z.find("project.xml");
    if (!entry) { err = "not a DAWproject (no project.xml)"; return false; }
    std::string xml;
    if (!z.read(*entry, xml, err)) return false;
    pugi::xml_document doc;
    if (const auto r = doc.load_buffer(xml.data(), xml.size()); !r) { err = std::string("not a valid DAWproject: ") + r.description(); return false; }
    const auto project = doc.child("Project");
    if (!project) { err = "not a DAWproject (no Project element)"; return false; }

    Report &rep = out.report;
    rep.app = std::string("DAWproject") + (project.child("Application") ? std::string(" from ") + project.child("Application").attribute("name").as_string() : "");
    rep.version = project.attribute("version").as_string();
    const double rawTempo = attr(project.child("Transport").child("Tempo"), "value", 120);
    const double tempo = rawTempo >= 20 && rawTempo <= 999 ? rawTempo : 120;
    const double spb = 60.0 / tempo;
    const fs::path projectPath = fs::absolute(fs::path(path));
    const fs::path audioDir = projectPath.parent_path() / (projectPath.stem().string() + " Audio Files");

    Builder b(rep, 48000);
    // Tracks (nested in folder tracks too); the master channel's track is skipped.
    std::map<std::string, int32_t> trackByXmlId;
    int submixes = 0, sends = 0, devices = 0;
    std::function<void(pugi::xml_node)> walk = [&](pugi::xml_node parent) {
        for (auto t : parent.children("Track")) {
            const auto ch = t.child("Channel");
            if (std::string(ch.attribute("role").as_string()) == "master") continue;
            if (std::string(ch.attribute("role").as_string()) == "submix") ++submixes;
            sends += static_cast<int>(std::distance(ch.child("Sends").children("Send").begin(), ch.child("Sends").children("Send").end()));
            devices += static_cast<int>(std::distance(ch.child("Devices").children().begin(), ch.child("Devices").children().end()));
            const double vol = attr(ch.child("Volume"), "value", 1);
            const double pan = attr(ch.child("Pan"), "value", 0.5);
            trackByXmlId[t.attribute("id").as_string()] =
                b.addTrack(t.attribute("name").as_string("Track"), linearToDb(vol), static_cast<float>(pan * 2 - 1),
                           ch.child("Mute").attribute("value").as_bool(), ch.attribute("solo").as_bool());
            walk(t); // folder tracks hold their children
        }
    };
    walk(project.child("Structure"));
    rep.skip("plugins", devices);
    rep.skip("sends", sends);
    rep.skip("groupTracks", submixes);

    std::map<std::string, int32_t> mediaByPath;
    auto media = [&](pugi::xml_node audio) -> int32_t {
        const auto file = audio.child("File");
        const std::string ref = file.attribute("path").as_string();
        if (ref.empty()) return 0;
        if (auto it = mediaByPath.find(ref); it != mediaByPath.end()) return it->second;
        std::string target;
        if (file.attribute("external").as_bool()) {
            target = locateMedia(ref, projectPath.parent_path().string());
        } else if (const zip::Entry *e = z.find(ref)) {
            std::error_code ec;
            fs::create_directories(audioDir, ec);
            const fs::path to = audioDir / fs::path(ref).filename();
            if (!fs::exists(to, ec) || fs::file_size(to, ec) != e->size) {
                std::string xerr;
                if (!z.extract(*e, to.string(), xerr)) rep.notes.push_back("could not extract " + ref + ": " + xerr);
            }
            target = to.string();
        } else {
            target = ref;
        }
        return mediaByPath[ref] = b.addMedia(target);
    };

    int midiClips = 0, automation = 0, nested = 0;
    // Lanes carry the time unit (inherited by nested lanes); lanes with a track attribute hold that track's clips.
    std::function<void(pugi::xml_node, bool, int32_t)> lanes = [&](pugi::xml_node node, bool beats, int32_t track) {
        if (auto u = node.attribute("timeUnit")) beats = std::string(u.as_string()) != "seconds";
        if (auto t = node.attribute("track"); t && trackByXmlId.count(t.as_string())) track = trackByXmlId[t.as_string()];
        for (auto child : node.children()) {
            const std::string name = child.name();
            if (name == "Lanes") lanes(child, beats, track);
            else if (name == "Points") ++automation;
            else if (name == "Notes") ++midiClips;
            else if (name != "Clips") continue;
            if (name != "Clips" || track < 0) continue;
            for (auto clip : child.children("Clip")) {
                const double unit = beats ? spb : 1;
                const std::string cu = clip.attribute("contentTimeUnit").as_string();
                const double contentUnit = cu.empty() ? unit : (cu == "seconds" ? 1 : spb);
                const std::string fu = clip.attribute("fadeTimeUnit").as_string();
                const double fadeUnit = fu.empty() ? unit : (fu == "seconds" ? 1 : spb);
                const double start = attr(clip, "time", 0) * unit, length = attr(clip, "duration", 0) * unit;
                if (clip.child("Notes") || clip.child("Lanes").child("Notes")) { ++midiClips; continue; }
                if (clip.child("Clips")) { ++nested; continue; }
                const Source s = source(clip);
                if (!s.audio || length <= 0) continue;
                const int32_t m = media(s.audio);
                ClipStretch st;
                double offset = attr(clip, "playStart", 0) * contentUnit;
                if (s.warped) { st.rate = s.rate; offset += s.contentStart * contentUnit; }
                b.addClip(track, m, start, offset, length, clip.attribute("name").as_string(), 0,
                          attr(clip, "fadeInTime", 0) * fadeUnit, attr(clip, "fadeOutTime", 0) * fadeUnit, false, st);
            }
        }
    };
    lanes(project.child("Arrangement").child("Lanes"), true, -1); // -1 = no track yet (Builder tracks start at 0)
    rep.skip("midiClips", midiClips);
    rep.skip("automationLanes", automation);
    rep.skip("compoundClipsFlattened", nested);
    if (project.child("Transport").child("Tempo").child("Points") || project.child("Arrangement").child("TempoAutomation")) rep.skip("tempoChanges");
    rep.notes.push_back("Tempo " + std::to_string(tempo).substr(0, 6) + " BPM used to convert beats to time.");
    if (!mediaByPath.empty()) rep.notes.push_back("Audio extracted to " + audioDir.filename().string() + "/ next to the file.");
    out.document = b.document();
    out.document.set("tempo", tempo);
    return true;
}

} // namespace dalnok::import
