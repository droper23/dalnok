// Logic's AuCO channel mixer state, linked to arrangement tracks through Envi.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "import/logic_mixer.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <set>
#include <vector>

namespace dalnok::import {
namespace {
template <typename T> T read(const std::string &d, size_t offset) {
    T value{};
    if (offset <= d.size() && sizeof(T) <= d.size() - offset) std::memcpy(&value, d.data() + offset, sizeof value);
    return value;
}
struct Chunk { size_t offset, payload, length; };
}

std::map<uint32_t, LogicMix> logicMixer(const std::string &data) {
    std::vector<Chunk> strips, channels;
    size_t pos = 24;
    while (pos <= data.size() && data.size() - pos >= 36) {
        const uint64_t n = read<uint64_t>(data, pos + 28);
        if (n > data.size() - pos - 36) return {};
        const Chunk c{pos, pos + 36, static_cast<size_t>(n)};
        if (data.compare(pos, 4, "ivnE") == 0) strips.push_back(c);
        if (data.compare(pos, 4, "OCuA") == 0) channels.push_back(c);
        pos += 36 + static_cast<size_t>(n);
    }
    // A channel number may occur in multiple AuCn containers. Never guess which one is the track.
    std::map<uint32_t, std::set<uint32_t>> parents;
    std::map<std::pair<uint32_t, uint32_t>, LogicMix> byChannel;
    std::set<std::pair<uint32_t, uint32_t>> ambiguous;
    for (const auto &c : channels) {
        if (c.length < 120) continue;
        const uint32_t parent = read<uint32_t>(data, c.offset + 10), channel = read<uint32_t>(data, c.offset + 14);
        parents[channel].insert(parent);
        const uint32_t raw = read<uint32_t>(data, c.payload + 116);
        const auto value = static_cast<uint8_t>(data[c.payload + 85]);
        const auto pan = static_cast<uint8_t>(data[c.payload + 89]);
        const auto mute = static_cast<uint8_t>(data[c.payload + 90]);
        // The high byte duplicates the display fader value; reject records with inconsistent mixer fields.
        if (value != raw >> 24 || pan > 127 || mute > 1) continue;
        const double gainDb = raw == 0 ? -std::numeric_limits<double>::infinity() : 40.0 * std::log10(double(raw) / double(0x5a000000u));
        const LogicMix mix{static_cast<float>(std::min(gainDb, 12.0)),
                           float(int(pan) - 64) / (pan < 64 ? 64.0f : 63.0f), mute != 0,
                           (raw != 0 && gainDb <= -96.0) || gainDb > 12.0};
        const auto key = std::make_pair(parent, channel);
        if (!ambiguous.count(key) && !byChannel.emplace(key, mix).second) { byChannel.erase(key); ambiguous.insert(key); }
    }
    std::map<uint32_t, LogicMix> result;
    std::set<uint32_t> duplicateStrips;
    for (const auto &c : strips) {
        if (c.length < 162) continue;
        const size_t name = read<uint16_t>(data, c.payload + 158);
        const size_t index = 160 + name + (name & 1);
        if (index + 2 > c.length) continue;
        const uint16_t oneBased = read<uint16_t>(data, c.payload + index);
        if (!oneBased) continue;
        const uint32_t channel = oneBased - 1, strip = read<uint32_t>(data, c.offset + 10);
        const auto parent = parents.find(channel);
        if (parent == parents.end() || parent->second.size() != 1) continue;
        const auto mix = byChannel.find({*parent->second.begin(), channel});
        if (mix == byChannel.end() || duplicateStrips.count(strip)) continue;
        if (!result.emplace(strip, mix->second).second) { result.erase(strip); duplicateStrips.insert(strip); }
    }
    return result;
}
}
