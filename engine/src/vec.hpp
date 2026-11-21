// Vector kernels for the mix (A-13): the loops every track runs every block. Declared here, implemented with
// Accelerate (vDSP) on macOS (platform/macos/vec_accelerate.cpp) and with plain loops elsewhere
// (vec_portable.cpp). setScalar(true) makes every kernel use the plain loops on any platform, so tests can render
// the same project both ways and compare (control thread only, while nothing renders).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "rt.hpp"

namespace dalnok::vec {
// dst[i] = src[i] * g
void scale(const float *src, float g, float *dst, int n) DALNOK_NONBLOCKING;
// dst[i] += src[i] * g
void addScaled(const float *src, float g, float *dst, int n) DALNOK_NONBLOCKING;
// dst[i] = src[i] * (start + step * (i + 1)): a gain ramp that reaches start + step * n on the last sample.
void rampMul(const float *src, float start, float step, float *dst, int n) DALNOK_NONBLOCKING;
// The smallest and largest sample.
void minMax(const float *src, int n, float &lo, float &hi) DALNOK_NONBLOCKING;
// sum(src[i] * w[i]).
float dot(const float *src, const float *w, int n) DALNOK_NONBLOCKING;

void setScalar(bool scalar);
bool scalar() DALNOK_NONBLOCKING;

// Plain loops: the portable implementation and the reference the Accelerate one is compared with.
namespace plain {
inline void scale(const float *src, float g, float *dst, int n) DALNOK_NONBLOCKING { for (int i = 0; i < n; ++i) dst[i] = src[i] * g; }
inline void addScaled(const float *src, float g, float *dst, int n) DALNOK_NONBLOCKING { for (int i = 0; i < n; ++i) dst[i] += src[i] * g; }
inline void rampMul(const float *src, float start, float step, float *dst, int n) DALNOK_NONBLOCKING {
    for (int i = 0; i < n; ++i) dst[i] = src[i] * (start + step * static_cast<float>(i + 1));
}
inline void minMax(const float *src, int n, float &lo, float &hi) DALNOK_NONBLOCKING {
    lo = hi = n > 0 ? src[0] : 0.0f;
    for (int i = 1; i < n; ++i) { lo = src[i] < lo ? src[i] : lo; hi = src[i] > hi ? src[i] : hi; }
}
inline float dot(const float *src, const float *w, int n) DALNOK_NONBLOCKING {
    float s = 0;
    for (int i = 0; i < n; ++i) s += src[i] * w[i];
    return s;
}
} // namespace plain
} // namespace dalnok::vec
