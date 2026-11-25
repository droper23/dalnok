// Real-time pitch shifting (see dalnok_dsp.h): Signalsmith Stretch (MIT) at speed 1 with a transposition.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "dalnok_dsp.h"

#include <signalsmith-stretch.h>

struct DalnokShifter {
    signalsmith::stretch::SignalsmithStretch<float> st{0x44616C6E}; // fixed seed: renders repeat
    int channels = 1;
    double factor = 1;
};

extern "C" DalnokShifter *dalnok_dsp_shifter_create(int32_t channels, double sampleRate) {
    if (channels < 1 || channels > 8 || !(sampleRate > 0)) return nullptr;
    auto *s = new DalnokShifter;
    s->channels = channels;
    // An 80 ms block (20 ms hop): shorter than the default preset for less latency, long enough to shift exactly
    // (40 ms put corrections about 15 cents short). Delay compensation hides the latency on playback.
    s->st.configure(channels, static_cast<int>(sampleRate * 0.08), static_cast<int>(sampleRate * 0.02));
    return s;
}

extern "C" void dalnok_dsp_shifter_process(DalnokShifter *s, const float *const *in, float *const *out, int32_t frames, double factor) {
    if (!s || frames <= 0) return;
    if (factor != s->factor) { s->st.setTransposeFactor(static_cast<float>(factor)); s->factor = factor; }
    s->st.process(in, frames, out, frames);
}

extern "C" int32_t dalnok_dsp_shifter_latency(const DalnokShifter *s) {
    return s ? static_cast<int32_t>(s->st.inputLatency() + s->st.outputLatency()) : 0;
}

extern "C" void dalnok_dsp_shifter_destroy(DalnokShifter *s) { delete s; }
