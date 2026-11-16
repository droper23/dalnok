// Ableton Live .als import (gzip-compressed XML, Live 9–12). Arrangement audio
// clips are positioned in beats; with a constant song tempo they map to
// seconds. Warped clips are mapped through their warp markers; when that
// implies time-stretching (not yet supported) the clip plays at original speed
// and the report says so. Session-view clips, MIDI, devices, groups, returns
// and automation are reported.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "import/import.hpp"

#include <pugixml.hpp>
#include <zlib.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>

namespace fs = std::filesystem;

namespace dalnok::import {

namespace {

bool gunzipFile(const std::string &path, std::string &out, std::string &err) {
    gzFile f = gzopen(path.c_str(), "rb");
    if (!f) {
        err = "cannot open " + path;
        return false;
    }
    char buf[1 << 16];
    int n;
    while ((n = gzread(f, buf, sizeof buf)) > 0) out.append(buf, static_cast<size_t>(n));
    const bool ok = n == 0;
    gzclose(f);
    if (!ok || out.empty()) err = "could not decompress " + path;
    return ok && !out.empty();
}

double val(const pugi::xml_node &n, const char *path, double fallback = 0) {
    const auto v = n.first_element_by_path(path).attribute("Value");
    return v ? v.as_double(fallback) : fallback;
}
std::string sval(const pugi::xml_node &n, const char *path) {
    return n.first_element_by_path(path).attribute("Value").as_string();
}
bool bval(const pugi::xml_node &n, const char *path, bool fallback = false) {
    const auto v = n.first_element_by_path(path).attribute("Value");
    return v ? v.as_bool(fallback) : fallback;
}

std::string trackName(const pugi::xml_node &t) {
    std::string name = sval(t, "Name/EffectiveName");
    if (name.empty()) name = sval(t, "Name/UserName");
    return name;
}

// Live's project root is the nearest folder holding "Ableton Project Info"
// (sets saved in "Backup/" still resolve relative to the project root).
fs::path projectRoot(const fs::path &setDir) {
    std::error_code ec;
    fs::path d = setDir;
    for (int i = 0; i < 4 && !d.empty(); ++i, d = d.parent_path())
        if (fs::exists(d / "Ableton Project Info", ec)) return d;
    return setDir.filename() == "Backup" ? setDir.parent_path() : setDir;
}

// Candidate roots for Live's RelativePathType values (observed in Live 11/12 sets):
// 1/3 = project, 5 = installed pack (Core Library or Factory Packs), 6 = User Library, 7 = Live built-ins.
std::vector<fs::path> rootsFor(int type, const std::string &pack, const fs::path &setDir) {
    const char *home = std::getenv("HOME");
    const fs::path music = fs::path(home ? home : "") / "Music" / "Ableton";
    std::vector<fs::path> roots;
    std::error_code ec;
    std::vector<fs::path> apps;
    for (const auto &e : fs::directory_iterator("/Applications", ec)) {
        const auto n = e.path().filename().string();
        if (n.rfind("Ableton Live", 0) == 0 && e.path().extension() == ".app") apps.push_back(e.path() / "Contents" / "App-Resources");
    }
    switch (type) {
    case 5:
        if (pack == "Core Library") for (const auto &a : apps) roots.push_back(a / "Core Library");
        roots.push_back(music / "Factory Packs" / pack);
        roots.push_back(music / "Packs" / pack);
        break;
    case 6: roots.push_back(music / "User Library"); break;
    case 7: for (const auto &a : apps) roots.push_back(a / "Builtin"); break;
    default: roots.push_back(projectRoot(setDir)); roots.push_back(setDir); break;
    }
    return roots;
}

// Resolves a FileRef: absolute Path first, then RelativePath against the roots its
// type implies, then a by-name search under the project root.
std::string resolveFileRef(const pugi::xml_node &fileRef, const fs::path &setDir) {
    const std::string abs = sval(fileRef, "Path");
    std::error_code ec;
    if (!abs.empty() && fs::exists(abs, ec)) return abs;
    const std::string rel = sval(fileRef, "RelativePath");
    const int type = static_cast<int>(val(fileRef, "RelativePathType", 3));
    if (!rel.empty())
        for (const auto &root : rootsFor(type, sval(fileRef, "LivePackName"), setDir)) {
            const auto p = (root / rel).lexically_normal();
            if (fs::exists(p, ec)) return p.string();
        }
    // Relocate the original absolute path first (keeps the most structure), then the relative one.
    const std::string root = projectRoot(setDir).string();
    for (const auto &ref : {abs, rel}) {
        if (ref.empty()) continue;
        const auto found = locateMedia(ref, root);
        if (fs::exists(found, ec)) return found;
    }
    return !abs.empty() ? abs : rel.empty() ? std::string() : (fs::path(root) / rel).lexically_normal().string();
}

struct WarpMarker { double sec, beat; };

// Source seconds at a clip-internal beat position (linear between markers, extrapolated at ends).
double secAtBeat(const std::vector<WarpMarker> &m, double beat) {
    if (m.size() < 2) return m.empty() ? 0 : m[0].sec;
    size_t i = 1;
    while (i + 1 < m.size() && m[i].beat < beat) ++i;
    const auto &a = m[i - 1], &b = m[i];
    const double slope = (b.beat - a.beat) > 1e-12 ? (b.sec - a.sec) / (b.beat - a.beat) : 0;
    return a.sec + (beat - a.beat) * slope;
}

int countChildren(const pugi::xml_node &n) { return static_cast<int>(std::distance(n.begin(), n.end())); }

} // namespace

bool importAbleton(const std::string &path, Result &out, std::string &err) {
    std::string xml;
    if (!gunzipFile(path, xml, err)) return false;
    pugi::xml_document doc;
    if (const auto r = doc.load_buffer(xml.data(), xml.size()); !r) {
        err = std::string("not a valid Live set: ") + r.description();
        return false;
    }
    const auto root = doc.child("Ableton");
    const auto set = root.child("LiveSet");
    if (!root || !set) {
        err = "not an Ableton Live set";
        return false;
    }
    Report &rep = out.report;
    rep.app = "Ableton Live";
    rep.version = root.attribute("Creator").as_string();
    const fs::path setDir = fs::absolute(fs::path(path)).parent_path();

    // Live 12 calls it MainTrack; earlier versions MasterTrack.
    auto main = set.child("MainTrack");
    if (!main) main = set.child("MasterTrack");
    const auto tempoNode = main.first_element_by_path("DeviceChain/Mixer/Tempo");
    const double tempo = val(tempoNode, "Manual", 120);
    const double spb = 60.0 / (tempo > 0 ? tempo : 120);
    if (const auto ev = tempoNode.first_element_by_path("ArrangerAutomation/Events");
        ev && countChildren(ev) > 1)
        rep.skip("tempoChanges");
    rep.notes.push_back("Song tempo " + std::to_string(tempo).substr(0, 6) + " BPM used to convert beats to time.");
    if (const double mv = val(main, "DeviceChain/Mixer/Volume/Manual", 1); std::fabs(mv - 1) > 1e-6)
        rep.skip("masterVolume");
    rep.skip("masterDevices", countChildren(main.first_element_by_path("DeviceChain/DeviceChain/Devices")));

    Builder b(rep, 48000);
    int warpedNeedsStretch = 0;
    for (const auto &t : set.child("Tracks").children()) {
        const std::string kind = t.name();
        if (kind == "ReturnTrack") {
            rep.skip("returnTracks");
            continue;
        }
        if (kind == "GroupTrack") {
            rep.skip("groupTracks");
            continue;
        }
        const auto mixer = t.first_element_by_path("DeviceChain/Mixer");
        const float gain = linearToDb(val(mixer, "Volume/Manual", 1));
        const float pan = static_cast<float>(val(mixer, "Pan/Manual", 0));
        const bool mute = !bval(mixer, "Speaker/Manual", true);
        const bool solo = bval(mixer, "SoloSink", false);
        const auto seq = t.first_element_by_path("DeviceChain/MainSequencer");
        rep.skip("devicesAndPlugins", countChildren(t.first_element_by_path("DeviceChain/DeviceChain/Devices")));
        rep.skip("automationLanes", countChildren(t.first_element_by_path("AutomationEnvelopes/Envelopes")));
        if (const auto sends = mixer.child("Sends"); sends && countChildren(sends) > 0) rep.skip("sends");

        // Session-view clips (clip slots) — the unified launcher arrives later.
        int sessionClips = 0;
        for (const auto &slot : seq.child("ClipSlotList").children())
            if (slot.first_element_by_path("ClipSlot/Value").first_child()) ++sessionClips;
        rep.skip("sessionClips", sessionClips);

        if (kind == "MidiTrack") {
            int midi = 0;
            for (const auto &ev : seq.first_element_by_path("ClipTimeable/ArrangerAutomation/Events").children()) midi += std::string(ev.name()) == "MidiClip";
            rep.skip("midiClips", midi);
            rep.skip("midiTracks");
            continue;
        }
        if (kind != "AudioTrack") continue;
        const int track = b.addTrack(trackName(t), gain, pan, mute, solo);

        int takeClips = 0;
        for (const auto &lane : t.first_element_by_path("TakeLanes/TakeLanes").children("TakeLane"))
            for (const auto &ev : lane.first_element_by_path("ClipAutomation/Events").children()) takeClips += std::string(ev.name()) == "AudioClip";
        rep.skip("takeLaneClips", takeClips);
        auto events = seq.first_element_by_path("Sample/ArrangerAutomation/Events");
        for (const auto &clip : events.children("AudioClip")) {
            if (bval(clip, "Disabled")) {
                rep.skip("disabledClips");
                continue;
            }
            const std::string file = resolveFileRef(clip.first_element_by_path("SampleRef/FileRef"), setDir);
            if (file.empty()) continue;
            const int media = b.addMedia(file);
            const std::string name = sval(clip, "Name");
            const double beatStart = val(clip, "CurrentStart", clip.attribute("Time").as_double());
            const double beatEnd = val(clip, "CurrentEnd", beatStart);
            const double start = beatStart * spb, length = (beatEnd - beatStart) * spb;
            const float clipGain = linearToDb(val(clip, "SampleVolume", 1));
            if (val(clip, "PitchCoarse") != 0 || val(clip, "PitchFine") != 0) rep.skip("transposedClips");
            const auto loop = clip.child("Loop");
            const double loopStart = val(loop, "LoopStart"), loopEnd = val(loop, "LoopEnd");
            const double startRel = val(loop, "StartRelative");
            const bool loopOn = bval(loop, "LoopOn");
            const bool warped = bval(clip, "IsWarped");

            double offsetSec, srcLoopStart, srcLoopEnd, fadeScale = 1;
            if (!warped) {
                // Unwarped: loop/start markers are already in source seconds.
                offsetSec = loopStart + startRel;
                srcLoopStart = loopStart;
                srcLoopEnd = loopEnd;
            } else {
                std::vector<WarpMarker> markers;
                for (const auto &m : clip.child("WarpMarkers").children("WarpMarker"))
                    markers.push_back({m.attribute("SecTime").as_double(), m.attribute("BeatTime").as_double()});
                std::sort(markers.begin(), markers.end(), [](auto &x, auto &y) { return x.beat < y.beat; });
                offsetSec = secAtBeat(markers, loopStart + startRel);
                srcLoopStart = secAtBeat(markers, loopStart);
                srcLoopEnd = secAtBeat(markers, loopEnd);
                // Stretch ratio over the played region: source seconds per timeline second.
                const double played = secAtBeat(markers, loopStart + startRel + (beatEnd - beatStart)) - offsetSec;
                if (length > 0 && std::fabs(played / length - 1) > 0.002) ++warpedNeedsStretch;
                fadeScale = spb; // fades on warped clips are in beats
            }
            const auto fades = clip.child("Fades");
            const bool fadesOn = bval(clip, "Fade", true);
            const double fin = fadesOn ? val(fades, "FadeInLength") * fadeScale : 0;
            const double fout = fadesOn ? val(fades, "FadeOutLength") * fadeScale : 0;
            if (loopOn) {
                b.addLoopedClip(track, media, start, length, offsetSec, srcLoopStart, srcLoopEnd, name, clipGain);
            } else {
                b.addClip(track, media, start, offsetSec, length, name, clipGain, fin, fout, false);
            }
        }
    }
    if (warpedNeedsStretch) {
        rep.skip("warpedClipsNeedingStretch", warpedNeedsStretch);
        rep.notes.push_back(std::to_string(warpedNeedsStretch) +
                            " warped clip(s) need time-stretching to match the song tempo; they play at original speed until time-stretch support arrives.");
    }
    out.document = b.document();
    if (rep.missingMedia) rep.notes.push_back(std::to_string(rep.missingMedia) + " audio file(s) not found; clips are offline until relinked.");
    return true;
}

} // namespace dalnok::import
