// Audio Units in Logic's AuCU records. Only validated AU class-info plists are passed to the AU host.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "import/logic_plugins.hpp"
#include "import/import.hpp"
#include "pugixml.hpp"

#include <algorithm>
#include <cstring>
#include <map>
#include <set>

namespace dalnok::import {
namespace {
template <typename T> T read(const std::string &d, size_t off) {
    T v{};
    if (off <= d.size() && sizeof(T) <= d.size() - off) std::memcpy(&v, d.data() + off, sizeof(T));
    return v;
}
struct Chunk { std::string tag; size_t offset, payload, length; };
struct Plugin { unsigned order; std::string id, name, state; bool instrument = false, supported = false; };
std::string fourcc(const std::string &d, size_t off) {
    if (off > d.size() || 4 > d.size() - off) return {};
    std::string s(d.rbegin() + static_cast<std::ptrdiff_t>(d.size() - off - 4),
                  d.rbegin() + static_cast<std::ptrdiff_t>(d.size() - off));
    for (unsigned char c : s) if (c < 32 || c > 126 || c == ':') return {};
    return s;
}
bool plistMatches(const std::string &state, const std::string &type, const std::string &subtype, const std::string &manufacturer) {
    pugi::xml_document doc;
    if (!doc.load_buffer(state.data(), state.size())) return false;
    auto dict = doc.child("plist").child("dict");
    if (!dict) return false;
    std::map<std::string, uint32_t> ids;
    for (auto key = dict.first_child(); key; key = key.next_sibling()) {
        if (std::strcmp(key.name(), "key")) continue;
        auto value = key.next_sibling();
        if (value && !std::strcmp(value.name(), "integer")) {
            const std::string k = key.child_value();
            if (k == "type" || k == "subtype" || k == "manufacturer") ids[k] = value.text().as_uint();
        }
    }
    const auto code = [](const std::string &s) -> uint32_t {
        return (uint32_t(uint8_t(s[0])) << 24) | (uint32_t(uint8_t(s[1])) << 16) |
               (uint32_t(uint8_t(s[2])) << 8) | uint32_t(uint8_t(s[3]));
    };
    return ids.size() == 3 && ids["type"] == code(type) && ids["subtype"] == code(subtype) && ids["manufacturer"] == code(manufacturer);
}
}

void importLogicPlugins(const std::string &data, const std::vector<LogicTrackBinding> &tracks, Builder &builder, Report &report) {
    std::vector<Chunk> chunks;
    size_t pos = 24;
    while (pos <= data.size() && data.size() - pos >= 36) {
        const uint64_t n = read<uint64_t>(data, pos + 28);
        if (n > data.size() - pos - 36) return; // the main importer already validates framing
        const std::string tag(data.rbegin() + static_cast<std::ptrdiff_t>(data.size() - pos - 4),
                              data.rbegin() + static_cast<std::ptrdiff_t>(data.size() - pos));
        chunks.push_back({tag, pos, pos + 36, static_cast<size_t>(n)});
        pos += 36 + static_cast<size_t>(n);
    }
    // Envi's aligned word following the name is a one-based AuCO channel number.
    std::map<uint32_t, uint32_t> strips;
    std::map<uint32_t, std::set<uint32_t>> channelParents;
    for (const auto &c : chunks) {
        if (c.tag == "Envi" && c.length >= 162) {
            const size_t n = read<uint16_t>(data, c.payload + 158), index = 160 + n + (n & 1);
            if (index + 2 <= c.length) {
                const auto ch = read<uint16_t>(data, c.payload + index);
                if (ch > 0) strips[read<uint32_t>(data, c.offset + 10)] = ch - 1;
            }
        } else if (c.tag == "AuCO" && c.length >= 200) {
            channelParents[read<uint32_t>(data, c.offset + 14)].insert(read<uint32_t>(data, c.offset + 10));
        }
    }
    using Channel = std::pair<uint32_t, uint32_t>; // AuCn id and AuCO sub-index
    std::map<Channel, std::vector<Plugin>> plugins;
    for (const auto &c : chunks) {
        if (c.tag != "AuCU" || c.length < 177 || read<uint32_t>(data, c.payload) != 0x1a8) continue;
        const Channel channel{read<uint32_t>(data, c.offset + 10), read<uint32_t>(data, c.offset + 14)};
        const std::string rawName = data.substr(c.payload + 120, 12);
        const auto endName = rawName.find('\0');
        const std::string name = rawName.substr(0, endName);
        if (name.empty()) continue;
        Plugin p; p.order = read<uint32_t>(data, c.offset + 18); p.name = name;
        const auto manufacturer = fourcc(data, c.payload + 132), type = fourcc(data, c.payload + 136), subtype = fourcc(data, c.payload + 140);
        p.instrument = type == "aumu";
        if ((type == "aumu" || type == "aufx") && !manufacturer.empty() && !subtype.empty() &&
            data.compare(c.payload + 172, 5, "<?xml") == 0) {
            const auto end = data.find("</plist>", c.payload + 172);
            if (end != std::string::npos && end + 8 <= c.payload + c.length) {
                p.state = data.substr(c.payload + 172, end + 8 - c.payload - 172);
                if (plistMatches(p.state, type, subtype, manufacturer)) {
                    p.id = type + ":" + subtype + ":" + manufacturer;
                    p.supported = true;
                }
            }
        }
        plugins[channel].push_back(std::move(p));
    }
    int imported = 0, unsupported = 0, ambiguous = 0;
    std::set<std::string> unsupportedNames;
    for (const auto &binding : tracks) {
        const auto strip = strips.find(binding.strip);
        if (strip == strips.end()) continue;
        const auto parent = channelParents.find(strip->second);
        if (parent == channelParents.end()) continue;
        if (parent->second.size() != 1) { ++ambiguous; continue; }
        auto found = plugins.find({*parent->second.begin(), strip->second});
        if (found == plugins.end()) continue;
        auto chain = found->second;
        std::stable_sort(chain.begin(), chain.end(), [](const Plugin &a, const Plugin &b) { return a.order < b.order; });
        bool hadInstrument = false;
        for (const auto &p : chain) {
            if (!p.supported || (p.instrument && (!binding.instrument || hadInstrument))) {
                ++unsupported; unsupportedNames.insert(p.name); continue;
            }
            if (p.instrument) hadInstrument = true;
            builder.addAudioUnit(binding.track, p.id, p.name, p.instrument, p.state);
            ++imported;
        }
    }
    if (imported) report.notes.push_back(std::to_string(imported) + " Audio Unit plug-in(s) retained with Logic's class-info state. Availability and state acceptance must be checked in the device panel; Logic-specific processors are not converted.");
    report.skip("unsupportedLogicPlugins", unsupported);
    report.skip("ambiguousLogicPluginChannels", ambiguous);
    if (unsupported) {
        std::string names;
        for (const auto &n : unsupportedNames) { if (!names.empty()) names += ", "; names += n; }
        report.notes.push_back("Logic plug-ins without a supported Audio Unit state were not imported: " + names + ". Bounce or replace these in Logic before comparing the mix.");
    }
    if (ambiguous) report.notes.push_back("Some Logic channel-to-plug-in mappings are ambiguous; those chains were not imported.");
}
}
