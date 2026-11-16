/*
 * Dalnok DSP — offline audio processing (compiled optimized in every build).
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef DALNOK_DSP_H
#define DALNOK_DSP_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Renders `in_frames` of planar input into exactly `out_frames` of planar output.
 * preserve_pitch != 0: time-stretch (Signalsmith Stretch) with an additional
 * transposition of `semitones`. preserve_pitch == 0: varispeed resampling (pitch
 * follows speed; `semitones` is ignored). Returns 0 on success. Thread-safe. */
int dalnok_dsp_render_stretch(const float *const *in, int32_t channels, int64_t in_frames, float *const *out,
                              int64_t out_frames, double sample_rate, double semitones, int32_t preserve_pitch);

#ifdef __cplusplus
}
#endif
#endif
