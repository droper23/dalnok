// Deterministic tempo-map checks; no project files or audio devices.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "tempo_map.hpp"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>
#include <string>
#include <utility>
#include <vector>

#define CHECK(x) do { if (!(x)) { std::cerr << "FAIL line " << __LINE__ << ": " #x "\n"; std::exit(1); } } while (false)

int main() {
    using dalnok::TempoMap;
    using dalnok::TempoPoint;
    TempoMap map;
    std::string err;
    int64_t frame = -1;
    double beat = -1;
    CHECK(!map.beatToFrame(0, frame) && frame == -1);
    CHECK(!map.frameToBeat(0, beat) && beat == -1);
    CHECK(TempoMap::build(48000, {{0, 120}, {4, 60}, {8, 240}}, map, err));
    CHECK(map.beatToFrame(-0.5 / 24000, frame) && frame == -1);
    CHECK(map.beatToFrame(0.5 / 24000, frame) && frame == 1);
    for (const auto &[b, f] : std::vector<std::pair<double, int64_t>>{{-2, -48000}, {-1, -24000}, {0, 0}, {1, 24000}, {4, 96000},
                                                                      {5, 144000}, {8, 288000}, {12, 336000}}) {
        CHECK(map.beatToFrame(b, frame) && frame == f);
        CHECK(map.frameToBeat(f, beat) && std::abs(beat - b) < 1e-12);
    }
    // Segment boundaries may be between samples; inverse conversion is
    // accurate within the half-sample quantization of beatToFrame.
    CHECK(TempoMap::build(44100, {{0, 137}, {3.1, 99}, {9.3, 231}}, map, err));
    std::mt19937_64 rng(0xDAD1u);
    std::uniform_real_distribution<double> beats(-1'000'000, 1'000'000);
    for (int i = 0; i < 10000; ++i) {
        const double original = beats(rng);
        CHECK(map.beatToFrame(original, frame) && map.frameToBeat(frame, beat));
        CHECK(std::abs(original - beat) < 0.5 / (44100.0 * 60 / 400) + 1e-9);
    }
    for (const double point : {3.1, 9.3}) {
        CHECK(map.beatToFrame(point, frame));
        int64_t before, after;
        CHECK(map.beatToFrame(point - 1e-5, before));
        CHECK(map.beatToFrame(point + 1e-5, after));
        CHECK(before <= frame && frame <= after);
        CHECK(map.frameToBeat(frame, beat) && std::abs(beat - point) < 0.0001);
    }
    for (const int64_t position : {-(int64_t{1} << 40), int64_t{1} << 40,
                                   -((int64_t{1} << 48) - 8192), (int64_t{1} << 48) - 8192}) {
        CHECK(map.frameToBeat(position, beat) && map.beatToFrame(beat, frame));
        CHECK(std::llabs(frame - position) <= 1);
    }
    // A failed build must leave the last valid map unchanged.
    CHECK(map.beatToFrame(10, frame));
    const auto originalFrame = frame;
    const auto nan = std::numeric_limits<double>::quiet_NaN();
    const auto inf = std::numeric_limits<double>::infinity();
    for (const auto &bad : std::vector<std::vector<TempoPoint>>{
             {}, {{1, 120}}, {{0, 120}, {0, 60}}, {{0, 120}, {2, 60}, {1, 80}},
             {{0, 120}, {nan, 90}}, {{0, nan}}, {{0, 19}}, {{0, 401}},
             {{0, 120}, {1e-12, 60}}, {{0, 120}, {1e300, 60}}}) {
        CHECK(!TempoMap::build(48000, bad, map, err) && !err.empty());
        CHECK(map.beatToFrame(10, frame) && frame == originalFrame);
    }
    CHECK(!TempoMap::build(nan, {{0, 120}}, map, err));
    CHECK(!TempoMap::build(7999, {{0, 120}}, map, err));
    CHECK(!TempoMap::build(768001, {{0, 120}}, map, err));
    frame = 123; beat = 456;
    CHECK(map.beatToFrame(-1, frame) && frame < 0);
    frame = 123;
    CHECK(!map.beatToFrame(inf, frame) && frame == 123);
    CHECK(!map.beatToFrame(1e300, frame) && frame == 123);
    CHECK(map.frameToBeat(-1, beat) && beat < 0);
    beat = 456;
    CHECK(!map.frameToBeat(std::numeric_limits<int64_t>::max(), beat) && beat == 456);
    std::cout << "tempo map: PASS\n";
}
