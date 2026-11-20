// Offline time-stretch / pitch-shift / varispeed.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "dalnok_dsp.h"

#include <signalsmith-stretch.h>

#include <algorithm>
#include <cmath>
#include <vector>

namespace {

// Cubic (Catmull-Rom) resampling: pitch and speed change together.
void varispeed(const float *in, int64_t n, float *out, int64_t m) {
    const double step = m > 1 ? static_cast<double>(n - 1) / static_cast<double>(m - 1) : 0;
    auto at = [&](int64_t i) { return in[std::clamp<int64_t>(i, 0, n - 1)]; };
    for (int64_t j = 0; j < m; ++j) {
        const double x = j * step;
        const auto i = static_cast<int64_t>(x);
        const float t = static_cast<float>(x - static_cast<double>(i));
        const float p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
        out[j] = p1 + 0.5f * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)));
    }
}

} // namespace

extern "C" int dalnok_dsp_render_stretch(const float *const *in, int32_t channels, int64_t inFrames, float *const *out,
                                         int64_t outFrames, double sampleRate, double semitones, int32_t preservePitch) {
    if (!in || !out || channels < 1 || inFrames < 1 || outFrames < 1 || !(sampleRate > 0)) return 1;
    if (!preservePitch) {
        for (int c = 0; c < channels; ++c) varispeed(in[c], inFrames, out[c], outFrames);
        return 0;
    }
    // A fixed seed: by default the stretcher seeds its phase randomisation from std::random_device, which made two
    // renders of the same stretched clip differ in their last output-latency frames.
    signalsmith::stretch::SignalsmithStretch<float> st(0x44616C6E);
    st.presetDefault(channels, static_cast<float>(sampleRate));
    st.setTransposeSemitones(static_cast<float>(semitones));
    const int64_t inLat = st.inputLatency(), outLat = st.outputLatency();

    // Input padded with inLat zeros at the end (and to at least inLat at the start for seek).
    const int64_t padded = std::max(inFrames, inLat) + inLat;
    std::vector<std::vector<float>> src(static_cast<size_t>(channels), std::vector<float>(static_cast<size_t>(padded), 0.0f));
    for (int c = 0; c < channels; ++c) std::copy(in[c], in[c] + inFrames, src[static_cast<size_t>(c)].begin());
    std::vector<std::vector<float>> dst(static_cast<size_t>(channels), std::vector<float>(static_cast<size_t>(outFrames + outLat), 0.0f));

    std::vector<float *> ip(static_cast<size_t>(channels)), op(static_cast<size_t>(channels));
    auto point = [&](int64_t inPos, int64_t outPos) {
        for (int c = 0; c < channels; ++c) {
            ip[static_cast<size_t>(c)] = src[static_cast<size_t>(c)].data() + inPos;
            op[static_cast<size_t>(c)] = dst[static_cast<size_t>(c)].data() + outPos;
        }
    };
    const double ratio = static_cast<double>(inFrames) / static_cast<double>(outFrames); // input per output
    point(0, 0);
    st.seek(ip.data(), static_cast<int>(inLat), ratio);
    // Main pass: remaining input (incl. trailing silence) -> exactly outFrames outputs (after pre-roll).
    const int64_t mainIn = padded - inLat;
    constexpr int64_t kChunk = 8192;
    int64_t consumed = 0, produced = 0;
    while (consumed < mainIn) {
        const int64_t inN = std::min(kChunk, mainIn - consumed);
        const int64_t target = std::llround(static_cast<double>(consumed + inN) / static_cast<double>(mainIn) * static_cast<double>(outFrames));
        const int64_t outN = std::max<int64_t>(0, target - produced);
        point(inLat + consumed, produced);
        st.process(ip.data(), static_cast<int>(inN), op.data(), static_cast<int>(outN));
        consumed += inN;
        produced += outN;
    }
    point(0, produced);
    st.flush(op.data(), static_cast<int>(outLat));
    // Drop the pre-roll.
    for (int c = 0; c < channels; ++c) {
        const auto &d = dst[static_cast<size_t>(c)];
        std::copy(d.begin() + outLat, d.begin() + outLat + outFrames, out[c]);
    }
    return 0;
}
