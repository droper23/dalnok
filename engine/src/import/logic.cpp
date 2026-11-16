// Logic Pro .logicx import — EXPERIMENTAL, from our own interoperability
// research on projects saved by Logic Pro 12.2 (see
// "04 - Research/Logic ProjectData Format.md"). No Apple code or assets are
// used; only the user's own project files are read.
//
// Verified on 30 real projects: chunk framing (walk ends exactly at EOF),
// audio-file records (names), audio-region records (source offset/length in
// samples — 2,667/2,667 regions fit inside their files), region-to-file
// ownership (document order), project metadata (MetaData.plist).
// NOT yet verified against ground truth: arrangement placement (event 0x24:
// position/track/region link) and track naming. The report says so.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "import/import.hpp"
#include "media.hpp"

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
        if (pos + kChunkHeader + len > d.size()) return false;
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

struct Region { std::string file; uint32_t offset, length; std::string name; };
struct Placement { uint32_t pos; uint8_t track; uint32_t link; };

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
            currentFile = utf16le(d, c.payload + 10, n);
        } else if (c.tag == "AuRg" && c.length > 76) {
            const auto nl = rd<uint16_t>(d, c.payload + 74);
            regions.push_back({currentFile, rd<uint32_t>(d, c.payload + 6), rd<uint32_t>(d, c.payload + 22),
                               d.substr(c.payload + 76, nl)});
        }
    }
    // Arrangement placements (event type 0x24, 80 bytes) inside event sequences.
    std::vector<Placement> placements;
    for (const auto &c : chunks) {
        if (c.tag != "EvSq") continue;
        size_t i = 0;
        while (i + 16 <= c.length) {
            const auto t = rd<uint32_t>(d, c.payload + i);
            if ((t & 0xff) == 0xf1) break;
            if (t == 0x24 && i + 80 <= c.length) {
                placements.push_back({rd<uint32_t>(d, c.payload + i + 4), static_cast<uint8_t>(d[c.payload + i + 0x14]),
                                      rd<uint32_t>(d, c.payload + i + 0x2c)});
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
    for (const auto &p : placements) {
        const uint32_t idx = p.link / 4;
        if (p.link % 4 != 0 || idx >= regions.size() || p.pos < kTickOrigin) { ++unresolved; continue; }
        const Region &r = regions[idx];
        if (!tracks.count(p.track)) tracks[p.track] = b.addTrack("Audio " + std::to_string(p.track), 0, 0, false, false);
        const std::string file = (audioDir / r.file).string();
        const int32_t media = b.addMedia(fs::exists(file) ? file : locateMedia(r.file, pkg.parent_path().string()));
        b.addClip(tracks[p.track], media, (p.pos - kTickOrigin) * secPerTick, r.offset / rate, r.length / rate,
                  r.name.empty() ? r.file : r.name);
        ++placed;
    }
    rep.skip("unplacedRegions", static_cast<int>(regions.size()) - placed);
    rep.skip("unresolvedPlacements", unresolved);
    rep.skip("midiRegions", midiRegions);
    rep.notes.push_back("EXPERIMENTAL: Logic's project format is undocumented. Audio files and region trims are verified; "
                        "region positions and track assignment are decoded but not yet verified, and track names, "
                        "plug-ins, automation and take folders are not imported. For an exact arrangement, use Logic's "
                        "File ▸ Export ▸ Project to Final Cut Pro XML and import that file.");
    out.document = b.document();
    return true;
}

} // namespace dalnok::import
