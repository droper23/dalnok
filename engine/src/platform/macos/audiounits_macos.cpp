// Audio Unit discovery through the component registry. Components are not instantiated.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "plugins.hpp"
#include <AudioToolbox/AudioToolbox.h>

namespace dalnok {
namespace {
std::string fourCC(OSType v) {
    std::string s;
    for (int shift = 24; shift >= 0; shift -= 8) {
        const char c = static_cast<char>((v >> shift) & 0xff);
        s += (c >= 32 && c < 127) ? c : '?';
    }
    return s;
}
}

std::vector<PluginInfo> listAudioUnits() {
    std::vector<PluginInfo> out;
    AudioComponentDescription any{};
    for (AudioComponent c = AudioComponentFindNext(nullptr, &any); c; c = AudioComponentFindNext(c, &any)) {
        AudioComponentDescription d{};
        if (AudioComponentGetDescription(c, &d) != noErr) continue;
        const char *kind = d.componentType == kAudioUnitType_MusicDevice ? "instrument"
                           : d.componentType == kAudioUnitType_Effect || d.componentType == kAudioUnitType_MusicEffect ? "effect"
                           : d.componentType == kAudioUnitType_MIDIProcessor ? "midi"
                           : nullptr;
        if (!kind) continue; // converters, outputs, generators, etc.
        PluginInfo info;
        info.format = "au";
        info.kind = kind;
        info.path = fourCC(d.componentType) + ":" + fourCC(d.componentSubType) + ":" + fourCC(d.componentManufacturer);
        CFStringRef name = nullptr;
        if (AudioComponentCopyName(c, &name) == noErr && name) {
            char buf[512]{};
            CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
            CFRelease(name);
            const std::string full = buf; // "Vendor: Name"
            const auto colon = full.find(": ");
            info.vendor = colon == std::string::npos ? "" : full.substr(0, colon);
            info.name = colon == std::string::npos ? full : full.substr(colon + 2);
        }
        UInt32 version = 0;
        if (AudioComponentGetVersion(c, &version) == noErr)
            info.version = std::to_string(version >> 16) + "." + std::to_string((version >> 8) & 0xff) + "." + std::to_string(version & 0xff);
        out.push_back(std::move(info));
    }
    return out;
}
}
