// SPDX-License-Identifier: GPL-3.0-or-later
#include "midi_parser.hpp"
#include <cassert>
#include <thread>
int main() {
    dalnok::MidiParser parser;
    dalnok::MidiMessage m;
    for (auto b : {0x90, 60, 100, 61, 0, 0xf8, 0xc2, 12, 13}) parser.feed(b, 42);
    assert(parser.pop(m) && m.status == 0x90 && m.data1 == 60 && m.data2 == 100 && m.size == 3 && m.timestamp == 42);
    assert(parser.pop(m) && m.status == 0x90 && m.data1 == 61 && m.data2 == 0);
    assert(parser.pop(m) && m.status == 0xc2 && m.data1 == 12 && m.data2 == 0 && m.size == 2);
    assert(parser.pop(m) && m.status == 0xc2 && m.data1 == 13 && m.size == 2);
    for (auto b : {0xf0, 1, 0xf8, 2, 0xf7, 60, 100, 0xf2, 1, 2, 61, 100, 0x80, 60, 4}) parser.feed(b, 7);
    assert(parser.pop(m) && m.status == 0x80 && m.data1 == 60 && m.data2 == 4);
    assert(!parser.pop(m));
    for (int i = 0; i < 1025; ++i) { parser.feed(0x90, i); parser.feed(60, i); parser.feed(1, i); }
    assert(parser.dropped() == 1);
    for (int i = 0; i < 1024; ++i) assert(parser.pop(m) && m.timestamp == static_cast<uint64_t>(i));
    assert(!parser.pop(m));

    dalnok::MidiParser concurrent;
    std::thread producer([&] { for (int i = 0; i < 1000; ++i) { concurrent.feed(0x90, i); concurrent.feed(60, i); concurrent.feed(1, i); } });
    for (int i = 0; i < 1000;) {
        if (concurrent.pop(m)) { assert(m.timestamp == static_cast<uint64_t>(i)); ++i; }
        else std::this_thread::yield();
    }
    producer.join();
    assert(concurrent.dropped() == 0);
}
