// Portable vector kernels (see vec.hpp); macOS uses platform/macos/vec_accelerate.cpp.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "vec.hpp"

#include <atomic>

namespace dalnok::vec {
namespace {
std::atomic<bool> gScalar{false};
}
void setScalar(bool s) { gScalar.store(s, std::memory_order_relaxed); }
bool scalar() DALNOK_NONBLOCKING { return gScalar.load(std::memory_order_relaxed); }

#if !defined(__APPLE__)
void scale(const float *src, float g, float *dst, int n) DALNOK_NONBLOCKING { plain::scale(src, g, dst, n); }
void addScaled(const float *src, float g, float *dst, int n) DALNOK_NONBLOCKING { plain::addScaled(src, g, dst, n); }
void rampMul(const float *src, float start, float step, float *dst, int n) DALNOK_NONBLOCKING { plain::rampMul(src, start, step, dst, n); }
void minMax(const float *src, int n, float &lo, float &hi) DALNOK_NONBLOCKING { plain::minMax(src, n, lo, hi); }
float dot(const float *src, const float *w, int n) DALNOK_NONBLOCKING { return plain::dot(src, w, n); }
#endif
} // namespace dalnok::vec
