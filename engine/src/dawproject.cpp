// DAWproject export (the open interchange format: a ZIP with project.xml, metadata.xml and the audio).
// Times are written in seconds (the arrangement's Lanes use timeUnit="seconds"), so audio placement is exact
// without converting through the tempo map. What the format can't carry from Dalnok is listed in `notes`.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"
#include "zip.hpp"

#include <pugixml.hpp>

#include <cmath>
#include <filesystem>
#include <map>
#include <set>
#include <sstream>

namespace fs = std::filesystem;

namespace dalnok {
namespace {
std::string num(double v) {
    std::ostringstream s;
    s.precision(12);
    s << v;
    return s.str();
}
double linear(float db) { return std::isfinite(db) ? std::pow(10.0, db / 20.0) : 0.0; }
std::string hexColor(int32_t rgb) {
    char b[8];
    std::snprintf(b, sizeof b, "#%06x", static_cast<unsigned>(rgb) & 0xffffffu);
    return b;
}
} // namespace

bool Engine::exportDawproject(const std::string &path, std::vector<std::string> &notes, std::string &err) {
    const Model &m = model_;
    const double rate = sampleRate_;
    auto sec = [&](int64_t frames) { return static_cast<double>(frames) / rate; };
    int nextId = 0;
    auto id = [&] { return "id" + std::to_string(nextId++); };

    pugi::xml_document doc;
    auto decl = doc.append_child(pugi::node_declaration);
    decl.append_attribute("version") = "1.0";
    decl.append_attribute("encoding") = "UTF-8";
    auto project = doc.append_child("Project");
    project.append_attribute("version") = "1.0";
    auto app = project.append_child("Application");
    app.append_attribute("name") = "Dalnok";
    app.append_attribute("version") = std::to_string(DALNOK_API_VERSION).c_str();

    auto transport = project.append_child("Transport");
    auto tempo = transport.append_child("Tempo");
    tempo.append_attribute("unit") = "bpm";
    tempo.append_attribute("value") = num(m.tempo.front().bpm).c_str();
    tempo.append_attribute("id") = id().c_str();
    auto sig = transport.append_child("TimeSignature");
    sig.append_attribute("numerator") = m.meters.front().num;
    sig.append_attribute("denominator") = m.meters.front().den;
    sig.append_attribute("id") = id().c_str();
    if (m.tempo.size() > 1) notes.push_back("tempo changes: only the first tempo is written (audio positions stay exact)");
    if (m.meters.size() > 1) notes.push_back("meter changes: only the first time signature is written");

    // Channels: each track's channel id, then the master's.
    auto structure = project.append_child("Structure");
    std::map<DalnokTrackId, std::string> trackIds, channelIds;
    for (const auto &t : m.tracks) { trackIds[t.id] = id(); channelIds[t.id] = id(); }
    const std::string masterTrack = id(), masterChannel = id();
    auto param = [&](pugi::xml_node parent, const char *name, const char *unit, double value, double lo, double hi) {
        auto p = parent.append_child(name);
        p.append_attribute("unit") = unit;
        p.append_attribute("value") = num(value).c_str();
        p.append_attribute("min") = num(lo).c_str();
        p.append_attribute("max") = num(hi).c_str();
        p.append_attribute("id") = id().c_str();
        return p;
    };
    int plugins = 0, automated = 0;
    for (const auto &t : m.tracks) {
        auto track = structure.append_child("Track");
        track.append_attribute("contentType") = t.kind == kTrackInstrument ? "notes" : "audio";
        track.append_attribute("loaded") = "true";
        track.append_attribute("id") = trackIds[t.id].c_str();
        track.append_attribute("name") = t.name.c_str();
        if (t.customColor >= 0) track.append_attribute("color") = hexColor(t.customColor).c_str();
        auto ch = track.append_child("Channel");
        ch.append_attribute("audioChannels") = 2;
        ch.append_attribute("destination") = (t.output && channelIds.count(t.output) ? channelIds[t.output] : masterChannel).c_str();
        ch.append_attribute("role") = t.kind == kTrackBus ? "submix" : "regular";
        ch.append_attribute("solo") = t.solo;
        ch.append_attribute("id") = channelIds[t.id].c_str();
        auto mute = ch.append_child("Mute");
        mute.append_attribute("value") = t.muted;
        mute.append_attribute("id") = id().c_str();
        param(ch, "Pan", "normalized", (t.pan + 1) / 2, 0, 1);
        param(ch, "Volume", "linear", linear(t.gainDb), 0, 2);
        if (!t.sends.empty()) {
            auto sends = ch.append_child("Sends");
            for (const auto &s : t.sends) {
                if (!channelIds.count(s.bus)) continue;
                auto send = sends.append_child("Send");
                send.append_attribute("destination") = channelIds[s.bus].c_str();
                send.append_attribute("type") = s.pre ? "pre" : "post";
                send.append_attribute("id") = id().c_str();
                param(send, "Volume", "linear", linear(s.db), 0, 2);
            }
        }
        plugins += static_cast<int>(t.plugins.size());
        automated += !t.volumeAuto.empty() + !t.panAuto.empty() + static_cast<int>(t.pluginAuto.size());
    }
    {
        auto track = structure.append_child("Track");
        track.append_attribute("contentType") = "audio";
        track.append_attribute("loaded") = "true";
        track.append_attribute("id") = masterTrack.c_str();
        track.append_attribute("name") = "Master";
        auto ch = track.append_child("Channel");
        ch.append_attribute("audioChannels") = 2;
        ch.append_attribute("role") = "master";
        ch.append_attribute("id") = masterChannel.c_str();
        param(ch, "Volume", "linear", linear(m.masterGainDb), 0, 2);
    }
    if (plugins) notes.push_back(std::to_string(plugins) + " plug-in(s) not written (their states stay in the Dalnok project)");
    if (automated) notes.push_back(std::to_string(automated) + " automation lane(s) not written");

    // Audio files: one archive entry per pool item used by an arrangement clip.
    std::map<DalnokMediaId, std::string> files;
    std::set<std::string> taken;
    int slots = 0, offline = 0;
    auto arrangement = project.append_child("Arrangement");
    arrangement.append_attribute("id") = id().c_str();
    auto lanes = arrangement.append_child("Lanes");
    lanes.append_attribute("timeUnit") = "seconds";
    lanes.append_attribute("id") = id().c_str();
    for (const auto &t : m.tracks) {
        auto lane = lanes.append_child("Lanes");
        lane.append_attribute("track") = trackIds[t.id].c_str();
        lane.append_attribute("id") = id().c_str();
        auto clips = lane.append_child("Clips");
        clips.append_attribute("id") = id().c_str();
        for (const auto &c : m.clips) {
            if (c.track != t.id) continue;
            if (c.slot >= 0) { ++slots; continue; }
            if (c.alt) continue; // takes that don't play; the comp's pieces are ordinary clips
            auto clip = clips.append_child("Clip");
            clip.append_attribute("time") = num(sec(c.start)).c_str();
            clip.append_attribute("duration") = num(sec(c.length)).c_str();
            clip.append_attribute("contentTimeUnit") = "seconds";
            clip.append_attribute("playStart") = num(sec(c.offset)).c_str();
            clip.append_attribute("name") = c.name.c_str();
            if (c.fadeIn || c.fadeOut) {
                clip.append_attribute("fadeTimeUnit") = "seconds";
                clip.append_attribute("fadeInTime") = num(sec(c.fadeIn)).c_str();
                clip.append_attribute("fadeOutTime") = num(sec(c.fadeOut)).c_str();
            }
            if (c.midi()) {
                auto ns = clip.append_child("Notes");
                ns.append_attribute("id") = id().c_str();
                for (const auto &n : *c.notes) {
                    auto note = ns.append_child("Note");
                    note.append_attribute("time") = num(sec(n.start)).c_str();
                    note.append_attribute("duration") = num(sec(n.length)).c_str();
                    note.append_attribute("channel") = 0;
                    note.append_attribute("key") = n.pitch;
                    note.append_attribute("vel") = num(n.velocity / 127.0).c_str();
                    note.append_attribute("rel") = "0.5";
                }
                continue;
            }
            const PoolEntry *e = poolEntry(c.media);
            if (!e || e->path.empty() || !fs::exists(e->path)) { ++offline; clips.remove_child(clip); continue; }
            if (!files.count(c.media)) {
                const fs::path src(e->path);
                std::string name = "audio/" + src.filename().string();
                for (int k = 2; taken.count(name); ++k) name = "audio/" + src.stem().string() + "-" + std::to_string(k) + src.extension().string();
                taken.insert(name);
                files[c.media] = name;
            }
            auto audio = [&](pugi::xml_node parent) {
                auto a = parent.append_child("Audio");
                a.append_attribute("channels") = e->channels;
                a.append_attribute("duration") = num(sec(e->frames)).c_str();
                a.append_attribute("sampleRate") = num(rate).c_str();
                a.append_attribute("id") = id().c_str();
                a.append_child("File").append_attribute("path") = files[c.media].c_str();
            };
            if (std::fabs(c.gainDb) > 1e-6) notes.push_back("clip gain on '" + c.name + "' not written");
            if (c.stretched()) { // warp markers map timeline seconds to source seconds
                clip.attribute("playStart").set_value("0");
                auto warps = clip.append_child("Warps");
                warps.append_attribute("contentTimeUnit") = "seconds";
                warps.append_attribute("timeUnit") = "seconds";
                warps.append_attribute("id") = id().c_str();
                audio(warps);
                for (const auto &[at, content] : {std::pair{0.0, sec(c.offset)}, std::pair{sec(c.length), sec(c.offset) + sec(c.sourceLength())}}) {
                    auto w = warps.append_child("Warp");
                    w.append_attribute("time") = num(at).c_str();
                    w.append_attribute("contentTime") = num(content).c_str();
                }
                if (c.pitch != 0 || !c.preservePitch) notes.push_back("pitch settings on '" + c.name + "' not written");
            } else {
                audio(clip);
            }
        }
    }
    if (slots) notes.push_back(std::to_string(slots) + " launcher slot clip(s) not written (only the arrangement)");
    if (offline) notes.push_back(std::to_string(offline) + " clip(s) with offline or generated audio left out");

    std::ostringstream xml;
    doc.save(xml, "  ");
    pugi::xml_document meta;
    auto md = meta.append_child("MetaData");
    md.append_child("Title").text() = fs::path(path).stem().string().c_str();
    md.append_child("Comment").text() = "Exported from Dalnok";
    std::ostringstream metaXml;
    meta.save(metaXml, "  ");

    const std::string tmp = path + ".partial";
    zip::Writer z;
    bool ok = z.open(tmp, err) && z.add("project.xml", xml.str(), err) && z.add("metadata.xml", metaXml.str(), err);
    for (const auto &[media, name] : files) if (ok) ok = z.addFile(name, poolEntry(media)->path, err);
    ok = z.close(err) && ok;
    std::error_code ec;
    if (ok) fs::rename(tmp, path, ec);
    if (!ok || ec) {
        fs::remove(tmp, ec);
        if (err.empty()) err = "cannot write " + path;
        return false;
    }
    return true;
}

} // namespace dalnok
