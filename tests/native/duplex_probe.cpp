// Standalone hardware probe for the internal AUHAL duplex path.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "device.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>

struct Probe {
    std::atomic<uint64_t> callbacks{0};
    std::atomic<float> peak{0};
    int channel = 0;
    static void render(void *context, float *left, float *right, const float *const *inputs, int count, int frames) DALNOK_NONBLOCKING {
        auto *p = static_cast<Probe *>(context);
        const float *input = inputs && p->channel < count ? inputs[p->channel] : nullptr;
        float max = 0;
        for (int i = 0; i < frames; ++i) {
            left[i] = right[i] = 0;
            if (input) { const float v = input[i] < 0 ? -input[i] : input[i]; if (v > max) max = v; }
        }
        auto old = p->peak.load(std::memory_order_relaxed);
        while (max > old && !p->peak.compare_exchange_weak(old, max, std::memory_order_relaxed)) {}
        p->callbacks.fetch_add(1, std::memory_order_relaxed);
    }
};
int main(int argc, char **argv) {
    std::string error;
    if (dalnok::createDuplexDevice("", 48000, 0, error)) return 1;
    if (dalnok::createDuplexDevice("missing-device", 48000, 0, error)) return 2;
    if (argc != 2) { std::puts("duplex validation: PASS"); return 0; }
    for (const auto &device : dalnok::listInputDevices()) {
        if (device.name != argv[1]) continue;
        if (dalnok::createDuplexDevice(device.uid, device.sampleRate, device.inputChannels, error)) return 3;
        if (dalnok::createDuplexDevice(device.uid, device.sampleRate + 100, 0, error)) return 4;
        for (int channel = 0; channel < std::min(device.inputChannels, 2); ++channel) {
            auto duplex = dalnok::createDuplexDevice(device.uid, device.sampleRate, channel, error);
            if (!duplex) { std::fprintf(stderr, "%s\n", error.c_str()); return 5; }
            Probe p;
            p.channel = channel;
            if (!duplex->start(&Probe::render, &p, error)) { std::fprintf(stderr, "%s\n", error.c_str()); return 6; }
            std::this_thread::sleep_for(std::chrono::seconds(3));
            duplex->stop();
            std::printf("input %d: %llu callbacks, peak %.8f, capture error %s\n", channel + 1,
                        static_cast<unsigned long long>(p.callbacks.load()), p.peak.load(), duplex->captureFailed() ? "yes" : "no");
            if (!p.callbacks.load() || duplex->captureFailed()) return 7;
        }
        return 0;
    }
    std::fprintf(stderr, "input device not found\n");
    return 8;
}
