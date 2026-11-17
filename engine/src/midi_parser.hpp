// MIDI 1.0 channel-message parser. One producer feeds bytes; one consumer pops.
// System messages and SysEx are ignored; real-time bytes do not break running status.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "rt.hpp"
#include <atomic>
#include <cstdint>
namespace dalnok {
struct MidiMessage {
    uint64_t timestamp = 0; // host timestamp of the packet containing the final byte
    uint8_t status = 0, data1 = 0, data2 = 0, size = 0;
};
class MidiParser {
public:
    void feed(uint8_t byte, uint64_t timestamp) DALNOK_NONBLOCKING {
        if (byte >= 0xf8) return; // interleaved real-time messages do not interrupt channel messages
        if (byte & 0x80) {
            used_ = 0;
            if (byte < 0xf0) {
                inSysex_ = false; systemRemaining_ = 0; running_ = byte;
                const uint8_t type = byte & 0xf0;
                needed_ = (type == 0xc0 || type == 0xd0) ? 1 : 2;
            } else {
                running_ = 0; needed_ = 0; inSysex_ = byte == 0xf0;
                systemRemaining_ = (byte == 0xf2) ? 2 : ((byte == 0xf1 || byte == 0xf3) ? 1 : 0);
            }
            return;
        }
        if (inSysex_) return;
        if (systemRemaining_) { --systemRemaining_; return; }
        if (!running_) return;
        if (used_ == 0) data1_ = byte;
        else data2_ = byte;
        if (++used_ == needed_) {
            MidiMessage message{timestamp, running_, data1_, needed_ == 2 ? data2_ : uint8_t(0), static_cast<uint8_t>(needed_ + 1)};
            if (!queue_.push(message)) dropped_.fetch_add(1, std::memory_order_relaxed);
            used_ = 0;
        }
    }
    bool pop(MidiMessage &message) DALNOK_NONBLOCKING { return queue_.pop(message); }
    uint64_t dropped() const DALNOK_NONBLOCKING { return dropped_.load(std::memory_order_relaxed); }
private:
    SpscQueue<MidiMessage, 1024> queue_;
    std::atomic<uint64_t> dropped_{0};
    uint8_t running_ = 0, needed_ = 0, used_ = 0, data1_ = 0, data2_ = 0, systemRemaining_ = 0;
    bool inSysex_ = false;
};
}
