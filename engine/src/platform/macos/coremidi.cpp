// Core MIDI source discovery. No input ports are opened by enumeration.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "midi.hpp"
#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>

namespace dalnok {
std::vector<MidiSourceInfo> listMidiSources() {
    std::vector<MidiSourceInfo> sources;
    const ItemCount count = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < count; ++i) {
        MIDIEndpointRef endpoint = MIDIGetSource(i);
        if (!endpoint) continue;
        SInt32 uid = 0;
        if (MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid) != noErr || uid == 0) continue;
        CFStringRef name = nullptr;
        if (MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) != noErr || !name) continue;
        char text[1024]{};
        const bool converted = CFStringGetCString(name, text, sizeof(text), kCFStringEncodingUTF8);
        CFRelease(name);
        if (converted && text[0]) sources.push_back({uid, text});
    }
    return sources;
}
}
