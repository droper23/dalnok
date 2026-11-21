// Vector kernels with Accelerate's vDSP (see vec.hpp). vDSP's vector routines work in place on caller buffers:
// no allocation, locks or I/O, so they are safe on the audio thread; Clang cannot see that through the SDK's
// declarations, hence the suppressed function-effects warning around the calls.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "vec.hpp"

#include <Accelerate/Accelerate.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
namespace dalnok::vec {
void scale(const float *src, float g, float *dst, int n) DALNOK_NONBLOCKING {
    if (scalar()) return plain::scale(src, g, dst, n);
    vDSP_vsmul(src, 1, &g, dst, 1, static_cast<vDSP_Length>(n));
}
void addScaled(const float *src, float g, float *dst, int n) DALNOK_NONBLOCKING {
    if (scalar()) return plain::addScaled(src, g, dst, n);
    vDSP_vsma(src, 1, &g, dst, 1, dst, 1, static_cast<vDSP_Length>(n));
}
void rampMul(const float *src, float start, float step, float *dst, int n) DALNOK_NONBLOCKING {
    if (scalar()) return plain::rampMul(src, start, step, dst, n);
    float first = start + step; // vDSP's ramp starts at its first value; ours reaches `start + step` on sample 0
    vDSP_vrampmul(src, 1, &first, &step, dst, 1, static_cast<vDSP_Length>(n));
}
void minMax(const float *src, int n, float &lo, float &hi) DALNOK_NONBLOCKING {
    if (scalar() || n <= 0) return plain::minMax(src, n, lo, hi);
    vDSP_minv(src, 1, &lo, static_cast<vDSP_Length>(n));
    vDSP_maxv(src, 1, &hi, static_cast<vDSP_Length>(n));
}
float dot(const float *src, const float *w, int n) DALNOK_NONBLOCKING {
    if (scalar()) return plain::dot(src, w, n);
    float s = 0;
    vDSP_dotpr(src, 1, w, 1, &s, static_cast<vDSP_Length>(n));
    return s;
}
} // namespace dalnok::vec
#pragma clang diagnostic pop
