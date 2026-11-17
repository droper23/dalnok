// Logic Pro .logicx import — EXPERIMENTAL, from our own interoperability
// research on projects saved by Logic Pro 12.2 (see
// "04 - Research/Logic ProjectData Format.md"). No Apple code or assets are
// used; only the user's own project files are read.
//
// Verified on 30 real projects: chunk framing (walk ends exactly at EOF),
// audio-file records (names), audio-region records (source offset/length in
// samples — 2,667/2,667 regions fit inside their files), region-to-file
// ownership (document order), project metadata (MetaData.plist).
// Arrangement (event 0x24: position, row, region link = AuRg header id) and track names (row -> Trak ->
// Envi channel strip). Volume, pan, stacks and plug-ins are not decoded.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "import/import.hpp"
#include "media.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>

namespace fs = std::filesystem;

namespace dalnok::import {

namespace {

constexpr uint8_t kMagic[4] = {0x23, 0x47, 0xc0, 0xab};
constexpr size_t kFileHeader = 24, kChunkHeader = 36;
constexpr uint32_t kTickOrigin = 34560; // bar 1 in Logic's 960-PPQ tick space
constexpr double kPpq = 960;

struct Chunk {
    std::string tag; // un-reversed, e.g. "AuRg"
    size_t pos, payload, length;
};

template <typename T> T rd(const std::string &d, size_t off) {
    T v{};
    if (off + sizeof(T) <= d.size()) std::memcpy(&v, d.data() + off, sizeof(T));
    return v; // little-endian host (arm64/x86-64)
}

bool walk(const std::string &d, std::vector<Chunk> &out) {
    size_t pos = kFileHeader;
    while (pos + kChunkHeader <= d.size()) {
        std::string tag = d.substr(pos, 4);
        for (char ch : tag)
            if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z'))) return false;
        const auto len = rd<uint64_t>(d, pos + 28);
        if (len > d.size() - pos - kChunkHeader) return false;
        out.push_back({std::string(tag.rbegin(), tag.rend()), pos, pos + kChunkHeader, static_cast<size_t>(len)});
        pos += kChunkHeader + static_cast<size_t>(len);
    }
    return pos == d.size();
}

std::string utf16le(const std::string &d, size_t off, size_t chars) {
    std::string out;
    for (size_t i = 0; i < chars; ++i) {
        const auto c = rd<uint16_t>(d, off + 2 * i);
        if (c < 0x80) out += static_cast<char>(c);
        else if (c < 0x800) { out += static_cast<char>(0xC0 | (c >> 6)); out += static_cast<char>(0x80 | (c & 0x3F)); }
        else { out += static_cast<char>(0xE0 | (c >> 12)); out += static_cast<char>(0x80 | ((c >> 6) & 0x3F)); out += static_cast<char>(0x80 | (c & 0x3F)); }
    }
    return out;
}

struct Region { std::string file; uint32_t offset, length; std::string name; uint32_t id; uint16_t sub; };
struct Placement { uint32_t pos; uint8_t track; uint32_t link; size_t section; };

} // namespace

bool importLogic(const std::string &path, Result &out, std::string &err) {
    const fs::path pkg(path);
    const fs::path alt = pkg / "Alternatives" / "000";
    std::ifstream in(alt / "ProjectData", std::ios::binary);
    if (!in) {
        err = "not a Logic project package (no Alternatives/000/ProjectData)";
        return false;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    const std::string d = ss.str();
    if (d.size() < kFileHeader || std::memcmp(d.data(), kMagic, 4) != 0) {
        err = "unrecognized Logic ProjectData header";
        return false;
    }
    std::vector<Chunk> chunks;
    if (!walk(d, chunks)) {
        err = "this Logic project's format isn't understood yet (chunk walk failed); use File ▸ Export ▸ Project to Final Cut Pro XML in Logic and import that";
        return false;
    }

    Report &rep = out.report;
    rep.app = "Logic Pro";
    json::Value meta, info;
    std::string e2;
    double bpm = 120, rate = 48000;
    if (readPropertyList((alt / "MetaData.plist").string(), meta, e2)) {
        bpm = meta.getNumber("BeatsPerMinute", 120);
        rate = meta.getNumber("SampleRate", 48000);
        const std::string key = meta.getString("SongKey", ""), mode = meta.getString("SongGenderKey", "");
        rep.notes.push_back("Tempo " + std::to_string(bpm).substr(0, 6) + " BPM, " +
                            std::to_string(static_cast<int>(meta.getNumber("SongSignatureNumerator", 4))) + "/" +
                            std::to_string(static_cast<int>(meta.getNumber("SongSignatureDenominator", 4))) +
                            (key.empty() ? "" : ", key " + key + " " + mode) + ", " + std::to_string(static_cast<int>(rate)) + " Hz.");
    }
    if (readPropertyList((pkg / "Resources" / "ProjectInformation.plist").string(), info, e2))
        rep.version = info.getString("LastSavedFrom", "");
    if (!(rate >= 8000)) rate = 48000;
    if (!(bpm > 0)) bpm = 120;

    // Audio files and their regions (regions follow their file in document order).
    std::vector<Region> regions;
    std::string currentFile;
    int midiRegions = 0;
    std::map<std::string, std::string> channelNames;
    for (const auto &c : chunks) {
        if (c.tag == "AuFl" && c.length > 10) {
            const auto n = rd<uint16_t>(d, c.payload + 8);
            if (n > (c.length - 10) / 2) { err = "invalid Logic audio file name length"; return false; }
            currentFile = utf16le(d, c.payload + 10, n);
        } else if (c.tag == "AuRg" && c.length > 76) {
            const auto nl = rd<uint16_t>(d, c.payload + 74);
            if (nl > c.length - 76) { err = "invalid Logic audio region name length"; return false; }
            // Chunk header: +10 is the region's id (what arrangement events link to), +14 a sub-index
            // (0 = the region itself; splits that Logic keeps as leftovers share the id with sub > 0).
            regions.push_back({currentFile, rd<uint32_t>(d, c.payload + 6), rd<uint32_t>(d, c.payload + 22),
                               d.substr(c.payload + 76, nl), rd<uint32_t>(d, c.pos + 10), rd<uint16_t>(d, c.pos + 14)});
        }
    }
    // Channel strips (Envi): header id at +10, name as u16 length at +158 and bytes at +160.
    std::map<uint32_t, std::string> channelName;
    for (const auto &c : chunks) {
        if (c.tag != "Envi" || c.length < 160) continue;
        const auto n = rd<uint16_t>(d, c.payload + 158);
        if (160 + size_t(n) <= c.length) channelName[rd<uint32_t>(d, c.pos + 10)] = d.substr(c.payload + 160, n);
    }
    // Each MSeq starts a section; its non-empty Trak chunks (58 bytes) are the arrange rows in order
    // (row 1 first), each pointing at its channel strip at +8. Placements carry the row number.
    std::vector<std::vector<uint32_t>> sectionRows;
    // Arrangement placements (event type 0x24, 80 bytes) inside event sequences.
    std::vector<Placement> placements;
    for (const auto &c : chunks) {
        if (c.tag == "MSeq") { sectionRows.emplace_back(); continue; }
        if (c.tag == "Trak" && c.length == 58 && !sectionRows.empty()) { sectionRows.back().push_back(rd<uint32_t>(d, c.payload + 8)); continue; }
        if (c.tag != "EvSq") continue;
        size_t i = 0;
        while (i + 16 <= c.length) {
            const auto t = rd<uint32_t>(d, c.payload + i);
            if ((t & 0xff) == 0xf1) break;
            if (t == 0x24 && i + 80 <= c.length) {
                placements.push_back({rd<uint32_t>(d, c.payload + i + 4), static_cast<uint8_t>(d[c.payload + i + 0x14]),
                                      rd<uint32_t>(d, c.payload + i + 0x2c), sectionRows.empty() ? 0 : sectionRows.size() - 1});
                i += 80;
            } else if (t == 0x20 || t == 0x22 || t == 0x26 || t == 0x28) {
                if (t == 0x20) ++midiRegions;
                i += 80;
            } else {
                i += t == 0x60 ? 32 : 16;
            }
        }
    }

    Builder b(rep, rate);
    const fs::path audioDir = pkg / "Media" / "Audio Files";
    std::map<int, int32_t> tracks;
    int placed = 0, unresolved = 0;
    const double secPerTick = 60.0 / (bpm * kPpq);
    // Placements link to a region's header id, not document order: leftover split regions
    // can sit between real ones and shift later indices.
    std::map<uint32_t, size_t> byId;
    for (size_t i = 0; i < regions.size(); ++i)
        if (regions[i].sub == 0) byId.emplace(regions[i].id, i);
    // Tracks in Logic's row order (placements are stored in time order).
    std::stable_sort(placements.begin(), placements.end(), [](const Placement &a, const Placement &b) { return a.track < b.track; });
    for (const auto &p : placements) {
        const auto it = byId.find(p.link);
        if (it == byId.end() || p.pos < kTickOrigin) { ++unresolved; continue; }
        const Region &r = regions[it->second];
        if (!tracks.count(p.track)) {
            std::string name = "Audio " + std::to_string(p.track);
            if (p.section < sectionRows.size() && p.track >= 1 && p.track <= sectionRows[p.section].size()) {
                const auto it = channelName.find(sectionRows[p.section][p.track - 1]);
                if (it != channelName.end() && !it->second.empty()) name = it->second;
            }
            tracks[p.track] = b.addTrack(name, 0, 0, false, false);
        }
        const std::string file = (audioDir / r.file).string();
        const int32_t media = b.addMedia(fs::exists(file) ? file : locateMedia(r.file, pkg.parent_path().string()));
        b.addClip(tracks[p.track], media, (p.pos - kTickOrigin) * secPerTick, r.offset / rate, r.length / rate,
                  r.name.empty() ? r.file : r.name);
        ++placed;
    }
    rep.skip("unplacedRegions", static_cast<int>(regions.size()) - placed);
    rep.skip("unresolvedPlacements", unresolved);
    if (midiRegions > 0)
        rep.notes.push_back("Some event records may represent MIDI; MIDI regions are not imported and their count is not verified.");
    rep.notes.push_back("EXPERIMENTAL: Logic's project format is undocumented. Audio files and region trims are verified; "
                        "region positions, track assignment and track names match Logic's own per-track renders on a test "
                        "project. Track volume, pan, track stacks, plug-ins, automation and take folders are not imported, so "
                        "levels differ from Logic. Logic's File ▸ Export ▸ Project to Final Cut Pro XML "
                        "is an alternative, but may render audio and change clip boundaries; compare the result with the original.");
    out.document = b.document();
    return true;
}

} // namespace dalnok::import
