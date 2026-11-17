// Core MIDI source discovery and input ports. Enumeration opens nothing.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "midi.hpp"
#include "midi_parser.hpp"
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

namespace {
struct Client {
    MIDIClientRef client = 0;
    std::vector<MIDIPortRef> ports;
    ~Client() {
        for (auto port : ports) MIDIPortDispose(port);
        if (client) MIDIClientDispose(client);
    }
};
// Universal MIDI Packet sizes in 32-bit words, by message type.
constexpr uint32_t kWords[16] = {1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4};
}

bool connectMidiSource(std::shared_ptr<void> &handle, int32_t uniqueId, std::atomic<MidiParser *> *slot, std::string &err) {
    MIDIObjectRef object = 0;
    MIDIObjectType type{};
    if (!slot || MIDIObjectFindByUniqueID(uniqueId, &object, &type) != noErr || type != kMIDIObjectType_Source) {
        err = "MIDI source not found";
        return false;
    }
    if (!handle) {
        auto client = std::make_shared<Client>();
        if (MIDIClientCreate(CFSTR("Dalnok"), nullptr, nullptr, &client->client) != noErr) {
            err = "cannot create MIDI client";
            return false;
        }
        handle = client;
    }
    auto *client = static_cast<Client *>(handle.get());
    MIDIPortRef port = 0;
    // Blocks cannot be declared noexcept; the body calls nothing that throws.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wperf-constraint-implies-noexcept"
    // Runs on Core MIDI's receive thread: only the nonblocking parser is touched.
    const OSStatus s = MIDIInputPortCreateWithProtocol(
        client->client, CFSTR("Dalnok Input"), kMIDIProtocol_1_0, &port, ^(const MIDIEventList *list, void *) __attribute__((nonblocking)) {
            // Acquire pairs with the engine's release store, so the parser is fully constructed here.
            MidiParser *parser = slot->load(std::memory_order_acquire);
            if (!parser) return;
            const MIDIEventPacket *packet = &list->packet[0];
            for (UInt32 p = 0; p < list->numPackets; ++p) {
                for (UInt32 w = 0; w < packet->wordCount;) {
                    const UInt32 word = packet->words[w];
                    const UInt32 messageType = word >> 28;
                    if (messageType == 2) { // MIDI 1.0 channel voice message
                        parser->feed(static_cast<uint8_t>(word >> 16), packet->timeStamp);
                        parser->feed(static_cast<uint8_t>((word >> 8) & 0x7f), packet->timeStamp);
                        const uint8_t type = (word >> 16) & 0xf0;
                        if (type != 0xc0 && type != 0xd0) parser->feed(static_cast<uint8_t>(word & 0x7f), packet->timeStamp);
                    }
                    w += kWords[messageType];
                }
                packet = MIDIEventPacketNext(packet);
            }
        });
#pragma clang diagnostic pop
    if (s != noErr) { err = "cannot create MIDI input port"; return false; }
    if (MIDIPortConnectSource(port, static_cast<MIDIEndpointRef>(object), nullptr) != noErr) {
        MIDIPortDispose(port);
        err = "cannot connect MIDI source";
        return false;
    }
    client->ports.push_back(port);
    return true;
}
}
