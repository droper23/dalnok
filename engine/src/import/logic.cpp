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
// Envi channel strip). Volume, pan, stacks and Logic-native plug-ins are not decoded.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "import/import.hpp"
#include "import/logic_plugins.hpp"
#include "import/logic_mixer.hpp"
#include "media.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <sstream>

namespace fs = std::filesystem;

namespace dalnok::import {

namespace {

constexpr uint8_t kMagic[4] = {0x23, 0x47, 0xc0, 0xab};
constexpr size_t kFileHeader = 24, kChunkHeader = 36;
constexpr uint32_t kTickOrigin = 34560; // arrangement placement origin
constexpr uint32_t kNoteTickOrigin = 38400; // region-relative MIDI note origin
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
        uint32_t c = rd<uint16_t>(d, off + 2 * i);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < chars) {
            const uint32_t low = rd<uint16_t>(d, off + 2 * (i + 1));
            if (low >= 0xDC00 && low <= 0xDFFF) { c = 0x10000 + ((c - 0xD800) << 10) + low - 0xDC00; ++i; }
            else c = 0xFFFD;
        } else if (c >= 0xD800 && c <= 0xDFFF) c = 0xFFFD;
        if (c < 0x80) out += static_cast<char>(c);
        else if (c < 0x800) { out += static_cast<char>(0xC0 | (c >> 6)); out += static_cast<char>(0x80 | (c & 0x3F)); }
        else if (c < 0x10000) { out += static_cast<char>(0xE0 | (c >> 12)); out += static_cast<char>(0x80 | ((c >> 6) & 0x3F)); out += static_cast<char>(0x80 | (c & 0x3F)); }
        else { out += static_cast<char>(0xF0 | (c >> 18)); out += static_cast<char>(0x80 | ((c >> 12) & 0x3F)); out += static_cast<char>(0x80 | ((c >> 6) & 0x3F)); out += static_cast<char>(0x80 | (c & 0x3F)); }
    }
    return out;
}

struct Region { std::string file; uint32_t offset, length; std::string name; uint32_t id; uint16_t sub; };
struct Placement { uint32_t pos; uint8_t track; uint32_t link; uint32_t sub; size_t section; bool midi = false; };

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
    int meterNum = 4, meterDen = 4;
    if (readPropertyList((alt / "MetaData.plist").string(), meta, e2)) {
        bpm = meta.getNumber("BeatsPerMinute", 120);
        rate = meta.getNumber("SampleRate", 48000);
        if (!(rate >= 8000 && rate <= 384000)) rate = 48000;
        if (!(bpm >= 20 && bpm <= 400)) bpm = 120;
        const double num = meta.getNumber("SongSignatureNumerator", 4), den = meta.getNumber("SongSignatureDenominator", 4);
        if (num >= 1 && num <= 32 && std::floor(num) == num) meterNum = static_cast<int>(num);
        if (den == 1 || den == 2 || den == 4 || den == 8 || den == 16) meterDen = static_cast<int>(den);
        const std::string key = meta.getString("SongKey", ""), mode = meta.getString("SongGenderKey", "");
        rep.notes.push_back("Tempo " + std::to_string(bpm).substr(0, 6) + " BPM, " +
                            std::to_string(meterNum) + "/" + std::to_string(meterDen) +
                            (key.empty() ? "" : ", key " + key + " " + mode) + ".");
    }
    if (readPropertyList((pkg / "Resources" / "ProjectInformation.plist").string(), info, e2))
        rep.version = info.getString("LastSavedFrom", "");
    if (!(rate >= 8000 && rate <= 384000)) rate = 48000;
    if (!(bpm >= 20 && bpm <= 400)) bpm = 120;

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
    // Event sequences by header id: a MIDI region (event 0x20) points at the sequence holding its notes (+0x20).
    std::map<uint32_t, const Chunk *> sequences;
    // A MIDI region's MSeq and its note EvSq share an id. The duration follows the variable-length,
    // even-padded region name: record +0x72 + padded name length (960-PPQ ticks).
    struct MidiRegion { uint32_t length; std::string name; bool muted, muteKnown; };
    std::map<uint32_t, MidiRegion> midiRegionInfo;
    std::set<uint32_t> ambiguousMidiIds;
    for (const auto &c : chunks) {
        const auto id = rd<uint32_t>(d, c.pos + 10);
        if (c.tag == "EvSq" && c.length > 16) sequences.emplace(id, &c);
        if (c.tag != "MSeq" || c.length < 18) continue;
        const size_t nameLength = rd<uint16_t>(d, c.payload + 16);
        const size_t durationOffset = 0x4e + ((nameLength + 1) & ~size_t(1));
        if (nameLength > c.length - 18 || durationOffset > c.length || c.length - durationOffset < 4) continue;
        const uint32_t length = rd<uint32_t>(d, c.payload + durationOffset);
        if (length == 0 || length >= 0x3fffffff) continue;
        if (ambiguousMidiIds.count(id)) continue;
        const bool muteKnown = c.length - durationOffset >= 19 && static_cast<uint8_t>(d[c.payload + durationOffset + 18]) <= 1;
        const bool muted = muteKnown && d[c.payload + durationOffset + 18] != 0;
        if (!midiRegionInfo.emplace(id, MidiRegion{length, d.substr(c.payload + 18, nameLength), muted, muteKnown}).second) {
            midiRegionInfo.erase(id);
            ambiguousMidiIds.insert(id);
        }
    }
    for (const auto &c : chunks) {
        if (c.tag == "MSeq") { sectionRows.emplace_back(); continue; }
        if (c.tag == "Trak" && c.length == 58 && !sectionRows.empty()) { sectionRows.back().push_back(rd<uint32_t>(d, c.payload + 8)); continue; }
        if (c.tag != "EvSq") continue;
        size_t i = 0;
        while (i + 16 <= c.length) {
            const auto t = rd<uint32_t>(d, c.payload + i);
            if ((t & 0xff) == 0xf1) break;
            size_t eventSize = (t == 0x20 || t == 0x22 || t == 0x24 || t == 0x26 || t == 0x28) ? 80 : (t == 0x60 ? 32 : 16);
            if (eventSize > c.length - i) { err = "truncated Logic event sequence; import aborted"; return false; }
            // A record can carry extra 16-byte lines (fades, flex and other per-placement data; a region placement
            // in a 2026 project ran to 40 KB). Continuation lines have the top bit of their second word set; a new
            // record's second word is a position and doesn't. Assuming fixed sizes lost every later placement.
            while (eventSize + 16 <= c.length - i && (rd<uint32_t>(d, c.payload + i + eventSize + 4) >> 31) == 1) eventSize += 16;
            if (t == 0x24) {
                // +0x2c: the region's header id; +0x28: which piece of it (a split region's pieces share the id).
                placements.push_back({rd<uint32_t>(d, c.payload + i + 4), static_cast<uint8_t>(d[c.payload + i + 0x14]),
                                      rd<uint32_t>(d, c.payload + i + 0x2c), rd<uint32_t>(d, c.payload + i + 0x28),
                                      sectionRows.empty() ? size_t(-1) : sectionRows.size() - 1});
                i += eventSize;
            } else if (t == 0x20 || t == 0x22 || t == 0x26 || t == 0x28) {
                if (t == 0x20) // a MIDI region if its sequence holds notes (track folders use the same record)
                    placements.push_back({rd<uint32_t>(d, c.payload + i + 4), static_cast<uint8_t>(d[c.payload + i + 0x14]),
                                          rd<uint32_t>(d, c.payload + i + 0x20), 0,
                                          sectionRows.empty() ? size_t(-1) : sectionRows.size() - 1, true});
                i += eventSize;
            } else {
                i += eventSize;
            }
        }
    }

    // Notes of a MIDI region's sequence (ticks relative to 38,400, Logic's 960 PPQ), from records
    // Compact (0x90) and extended (0x4090) note events share position, velocity, pitch and length fields.
    // The extended words can carry additional per-note data whose meaning is not yet decoded.
    struct Note { uint32_t pos, length; int pitch, velocity; };
    int extendedNotes = 0;
    auto notesOf = [&](uint32_t seq) {
        std::vector<Note> out;
        const auto it = sequences.find(seq);
        if (it == sequences.end()) return out;
        const Chunk &c = *it->second;
        size_t i = 0;
        while (i + 16 <= c.length) {
            const auto t = rd<uint32_t>(d, c.payload + i);
            if ((t & 0xff) == 0xf1) break;
            size_t size = 16;
            while (size + 16 <= c.length - i && (rd<uint32_t>(d, c.payload + i + size + 4) >> 31) == 1) size += 16;
            if ((t == 0x90 && size >= 32) || (t == 0x4090 && size >= 48)) {
                const auto len = rd<uint32_t>(d, c.payload + i + 28);
                if (t == 0x4090) ++extendedNotes;
                out.push_back({rd<uint32_t>(d, c.payload + i + 4), len, static_cast<uint8_t>(d[c.payload + i + 12]),
                               static_cast<uint8_t>(d[c.payload + i + 11])});
            }
            i += size;
        }
        return out;
    };
    Builder b(rep, rate);
    const fs::path audioDir = pkg / "Media" / "Audio Files";
    // Row numbers can be reused for different channel strips in different sequences.
    std::map<std::pair<uint8_t, uint64_t>, int32_t> tracks;
    std::set<size_t> placedRegions;
    int unresolved = 0;
    const double secPerTick = 60.0 / (bpm * kPpq);
    // Placements link to a region's header id, not document order: leftover split regions
    // can sit between real ones and shift later indices.
    // Regions by (header id, piece). Pieces of a split region share the id and differ in their sub-index.
    std::map<std::pair<uint32_t, uint32_t>, size_t> byId;
    std::set<std::pair<uint32_t, uint32_t>> ambiguousIds;
    for (size_t i = 0; i < regions.size(); ++i) {
        const auto key = std::make_pair(regions[i].id, uint32_t(regions[i].sub));
        if (ambiguousIds.count(key)) continue;
        if (!byId.emplace(key, i).second) {
            byId.erase(key);
            ambiguousIds.insert(key);
        }
    }
    rep.skip("ambiguousRegionIds", static_cast<int>(ambiguousIds.size()));
    int pieceFallbacks = 0, estimatedMidiLengths = 0, unknownMidiMute = 0, notesOutsideMidiRegions = 0, notesCrossingMidiRegions = 0;
    // Tracks in Logic's row order (placements are stored in time order).
    std::stable_sort(placements.begin(), placements.end(), [](const Placement &a, const Placement &b) { return a.track < b.track; });
    const double ticksPerBar = kPpq * 4.0 * meterNum / meterDen;
    for (const auto &p : placements) {
        if (p.midi) {
            const auto notes = notesOf(p.link);
            if (notes.empty() || p.pos < kTickOrigin) continue; // a track folder or an empty region
            const bool hasRow = p.section < sectionRows.size() && p.track >= 1 && p.track <= sectionRows[p.section].size();
            const uint32_t strip = hasRow ? sectionRows[p.section][p.track - 1] : 0;
            const auto key = std::make_pair(p.track, hasRow ? uint64_t(strip) : (uint64_t(1) << 32));
            if (!tracks.count(key)) {
                std::string name = "Instrument " + std::to_string(p.track);
                if (hasRow) if (const auto n = channelName.find(strip); n != channelName.end() && !n->second.empty()) name = n->second;
                tracks[key] = b.addInstrumentTrack(name);
            }
            std::vector<Builder::Note> out;
            double end = 0;
            const auto info = midiRegionInfo.find(p.link);
            for (const auto &n : notes) {
                if (n.pos < kNoteTickOrigin) { ++notesOutsideMidiRegions; continue; }
                const uint64_t relative = n.pos - kNoteTickOrigin;
                if (info != midiRegionInfo.end()) {
                    if (relative >= info->second.length) ++notesOutsideMidiRegions;
                    else if (relative + n.length > info->second.length) ++notesCrossingMidiRegions;
                }
                out.push_back({relative * secPerTick, n.length * secPerTick, n.pitch, n.velocity});
                end = std::max(end, double(relative) + n.length);
            }
            const bool knownLength = info != midiRegionInfo.end();
            if (!knownLength) ++estimatedMidiLengths;
            if (!knownLength || !info->second.muteKnown) ++unknownMidiMute;
            const double ticks = knownLength ? info->second.length : std::max(1.0, std::ceil(end / ticksPerBar - 1e-9)) * ticksPerBar;
            const std::string regionName = knownLength && !info->second.name.empty() ? info->second.name : "MIDI";
            b.addMidiClip(tracks[key], (p.pos - kTickOrigin) * secPerTick, ticks * secPerTick, out, regionName,
                          knownLength && info->second.muted);
            ++midiRegions;
            continue;
        }
        auto it = byId.find({p.link, p.sub});
        if (it == byId.end() && p.sub != 0) { // an unknown piece: the whole region is the best guess (reported)
            it = byId.find({p.link, 0u});
            if (it != byId.end()) ++pieceFallbacks;
        }
        if (it == byId.end() || p.pos < kTickOrigin) { ++unresolved; continue; }
        const Region &r = regions[it->second];
        const bool hasRow = p.section < sectionRows.size() && p.track >= 1 && p.track <= sectionRows[p.section].size();
        const uint32_t strip = hasRow ? sectionRows[p.section][p.track - 1] : 0;
        const auto trackKey = std::make_pair(p.track, hasRow ? uint64_t(strip) : (uint64_t(1) << 32));
        if (!tracks.count(trackKey)) {
            std::string name = "Audio " + std::to_string(p.track);
            if (hasRow) {
                const auto it = channelName.find(strip);
                if (it != channelName.end() && !it->second.empty()) name = it->second;
            }
            tracks[trackKey] = b.addTrack(name, 0, 0, false, false);
        }
        const std::string file = (audioDir / r.file).string();
        const int32_t media = b.addMedia(fs::exists(file) ? file : locateMedia(r.file, pkg.parent_path().string()));
        b.addClip(tracks[trackKey], media, (p.pos - kTickOrigin) * secPerTick, r.offset / rate, r.length / rate,
                  r.name.empty() ? r.file : r.name);
        placedRegions.insert(it->second);
    }
    std::vector<LogicTrackBinding> pluginBindings;
    for (const auto &[key, track] : tracks)
        if (key.second <= UINT32_MAX) pluginBindings.push_back({static_cast<uint32_t>(key.second), track, b.isInstrumentTrack(track)});
    importLogicPlugins(d, pluginBindings, b, rep);
    const auto mixer = logicMixer(d);
    int missingMix = 0, clampedMix = 0;
    for (const auto &[key, track] : tracks) {
        if (key.second > UINT32_MAX) { ++missingMix; continue; }
        const auto found = mixer.find(static_cast<uint32_t>(key.second));
        if (found == mixer.end()) { ++missingMix; continue; }
        const auto &mix = found->second;
        b.setTrackMix(track, mix.gainDb, mix.pan, mix.muted);
        if (mix.gainClamped) ++clampedMix;
    }
    rep.skip("logicUnmappedTrackMix", missingMix);
    rep.skip("logicClampedTrackGain", clampedMix);
    // Unused pieces (Logic keeps every piece a region was ever split into) aren't missing material.
    int unplaced = 0, unusedPieces = 0;
    for (size_t i = 0; i < regions.size(); ++i)
        if (!placedRegions.count(i)) ++(regions[i].sub == 0 ? unplaced : unusedPieces);
    rep.skip("unplacedRegions", unplaced);
    rep.skip("unusedRegionPieces", unusedPieces);
    rep.skip("regionPiecesNotFound", pieceFallbacks);
    rep.skip("unresolvedPlacements", unresolved);
    rep.skip("midiNotesOutsideRegion", notesOutsideMidiRegions);
    rep.skip("midiNotesCrossingRegionEnd", notesCrossingMidiRegions);
    rep.skip("midiRegionMuteUnknown", unknownMidiMute);
    if (estimatedMidiLengths > 0)
        rep.notes.push_back(std::to_string(estimatedMidiLengths) + " MIDI region(s) lack a uniquely identified duration; their lengths were estimated from notes.");
    if (unknownMidiMute > 0)
        rep.notes.push_back("Some MIDI regions have an unrecognized mute state and were imported unmuted; check them against Logic.");
    if (notesOutsideMidiRegions || notesCrossingMidiRegions)
        rep.notes.push_back("Some MIDI notes begin outside their region or extend past its end; Dalnok's playback is limited to the region boundary.");
    if (midiRegions > 0)
        rep.notes.push_back(std::to_string(midiRegions) + " MIDI region(s) imported onto instrument tracks. Tracks without an imported instrument use Dalnok Poly.");
    rep.skip("midiNoteExtensions", extendedNotes);
    if (extendedNotes > 0)
        rep.notes.push_back("Some MIDI notes carry additional Logic-specific data that is not decoded; note timing, pitch, velocity and length were imported.");
    rep.notes.push_back("EXPERIMENTAL: Logic's project format is undocumented. Audio files and region trims are verified; "
                        "region positions, track assignment and track names match Logic's own per-track renders on a test "
                        "project. Only a constant tempo and meter are imported; changes are not imported. Track stacks, "
                        "Logic-native plug-ins, automation and take folders are not imported, so "
                        "levels differ from Logic. Logic's File ▸ Export ▸ Project to Final Cut Pro XML "
                        "is an alternative, but may render audio and change clip boundaries; compare the result with the original.");
    out.document = b.document();
    out.document.set("tempo", bpm);
    json::Value meter = json::Value::makeArray();
    meter.push(meterNum); meter.push(meterDen);
    out.document.set("meter", std::move(meter));
    return true;
}

} // namespace dalnok::import
