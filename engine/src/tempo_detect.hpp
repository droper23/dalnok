// Tempo detection for audio (Logic's Smart Tempo analysis, Ableton's tempo detection on warp): an onset envelope
// (positive amplitude changes in three bands, 200 frames a second), its autocorrelation with harmonics weighted
// toward 120 BPM to choose the beat period among 60-200 BPM, then a fine search of period and phase over the whole
// file that lines a pulse train up with the onsets. Dalnok's own design.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <vector>

namespace dalnok {

struct TempoEstimate {
    double bpm = 0;          // 0: none found (too short or no pulse)
    int64_t firstBeat = 0;   // frames from the start: the earliest beat of the pulse train
    double confidence = 0;   // 0-1: how much the pulse train stands out from the onsets between beats
};

// `mono` at `sampleRate`; needs at least four seconds.
TempoEstimate detectTempo(const std::vector<float> &mono, double sampleRate);

} // namespace dalnok
