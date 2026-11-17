// SPDX-License-Identifier: GPL-3.0-or-later
#include "capture_ring.hpp"
#include <array>
#include <cassert>
#include <thread>

int main() {
    using dalnok::CaptureRing;
    CaptureRing ring(4, 2);
    const float in[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    float out[10]{};
    assert(ring.pop(out, 4) == 0);
    assert(!ring.push(in, 5));
    assert(ring.droppedFrames() == 5);
    assert(ring.push(in, 4));
    assert(!ring.push(in + 8, 1));
    assert(ring.droppedFrames() == 6);
    assert(ring.pop(out, 2) == 2);
    for (int i = 0; i < 4; ++i) assert(out[i] == in[i]);
    assert(ring.push(in + 8, 1)); // crosses ring boundary
    assert(ring.pop(out, 4) == 3);
    for (int i = 0; i < 6; ++i) assert(out[i] == in[i + 4]);
    bool invalid = false;
    try { CaptureRing bad(3, 2); } catch (const std::invalid_argument &) { invalid = true; }
    assert(invalid);

    CaptureRing concurrent(1024, 2);
    constexpr int total = 200000;
    std::thread producer([&] {
        for (int i = 0; i < total; ++i) {
            float frame[] = {static_cast<float>(i), static_cast<float>(-i)};
            while (!concurrent.push(frame, 1)) std::this_thread::yield();
        }
    });
    for (int i = 0; i < total;) {
        std::array<float, 128> data{};
        const auto n = concurrent.pop(data.data(), 64);
        for (uint32_t j = 0; j < n; ++j, ++i) {
            assert(data[j * 2] == static_cast<float>(i));
            assert(data[j * 2 + 1] == static_cast<float>(-i));
        }
        if (!n) std::this_thread::yield();
    }
    producer.join();
}
