// Loudness metering (see loudness.hpp).
//
// K-weighting: the BS.1770 pre-filter (a high shelf, +4 dB above ~1.7 kHz) and RLB high-pass (~38 Hz), designed for
// any sample rate by the bilinear transform from their analog prototypes. Each 100 ms sub-block stores the mean of
// L^2 + R^2; momentary loudness is the mean over 4 sub-blocks, short-term over 30, L = -0.691 + 10 log10(mean).
// Integrated loudness gates the 400 ms blocks (one every 100 ms, 75 % overlap): absolute gate -70 LUFS, then a
// relative gate 10 LU under the mean of what passed. The blocks go into a histogram of 0.1 LU bins that keeps each
// bin's summed energy, so the gated mean is exact and the memory fixed. True peak: a 4x windowed-sinc interpolator.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "loudness.hpp"

#include <algorithm>
#include <cmath>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects" // libm (log10, sqrt) neither allocates nor locks

namespace dalnok {
namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr float kNone = -INFINITY;
double lufs(double meanSquare) { return meanSquare > 0 ? -0.691 + 10 * std::log10(meanSquare) : -INFINITY; }
} // namespace

LoudnessMeter::LoudnessMeter(double sampleRate)
    : sampleRate_(sampleRate), subLength_(std::max<int64_t>(1, static_cast<int64_t>(std::llround(sampleRate * 0.1)))),
      momentary_(kNone), shortTerm_(kNone), integrated_(kNone), truePeak_(kNone), maxMomentary_(kNone), maxShortTerm_(kNone) {
    // Pre-filter (high shelf): f0 = 1681.974 Hz, gain 3.999843 dB, Q = 0.7071753.
    {
        const double f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196;
        const double k = std::tan(kPi * f0 / sampleRate), vh = std::pow(10.0, g / 20), vb = std::pow(vh, 0.4996667741545416);
        const double a0 = 1 + k / q + k * k;
        for (auto &b : shelf_) {
            b.b0 = (vh + vb * k / q + k * k) / a0;
            b.b1 = 2 * (k * k - vh) / a0;
            b.b2 = (vh - vb * k / q + k * k) / a0;
            b.a1 = 2 * (k * k - 1) / a0;
            b.a2 = (1 - k / q + k * k) / a0;
        }
    }
    // RLB weighting (high-pass): f0 = 38.135 Hz, Q = 0.5003270.
    {
        const double f0 = 38.13547087602444, q = 0.5003270373238773;
        const double k = std::tan(kPi * f0 / sampleRate), a0 = 1 + k / q + k * k;
        for (auto &b : highPass_) {
            b.b0 = 1; b.b1 = -2; b.b2 = 1;
            b.a1 = 2 * (k * k - 1) / a0;
            b.a2 = (1 - k / q + k * k) / a0;
        }
    }
    // True-peak interpolator: a Kaiser-windowed sinc (beta 6) at the original Nyquist, 48 taps split into 4 phases.
    const int n = kPhases * kTaps;
    auto bessel = [](double x) { double s = 1, t = 1; for (int k = 1; k < 30; ++k) { t *= (x / 2) / k; s += t * t; } return s; };
    for (int i = 0; i < n; ++i) {
        const double m = i - (n - 1) / 2.0, x = m / kPhases;
        const double sinc = std::fabs(x) < 1e-12 ? 1.0 : std::sin(kPi * x) / (kPi * x);
        const double r = 2.0 * i / (n - 1) - 1.0, w = bessel(6 * std::sqrt(std::max(0.0, 1 - r * r))) / bessel(6);
        fir_[static_cast<size_t>((i % kPhases) * kTaps + i / kPhases)] = static_cast<float>(sinc * w);
    }
}

void LoudnessMeter::reset() { resetPending_.store(true, std::memory_order_release); }

void LoudnessMeter::clear() DALNOK_NONBLOCKING {
    for (auto *bank : {shelf_, highPass_})
        for (int c = 0; c < 2; ++c) bank[c].x1 = bank[c].x2 = bank[c].y1 = bank[c].y2 = 0;
    subSum_ = 0; subCount_ = 0; subWrite_ = 0; subFilled_ = 0;
    subs_.fill(0); binEnergy_.fill(0); binCount_.fill(0);
    histL_.fill(0); histR_.fill(0); histPos_ = 0;
    peak_ = 0; maxM_ = 0; maxS_ = 0;
    for (auto *a : {&momentary_, &shortTerm_, &integrated_, &truePeak_, &maxMomentary_, &maxShortTerm_})
        a->store(kNone, std::memory_order_relaxed);
}

void LoudnessMeter::subBlockDone() DALNOK_NONBLOCKING {
    subs_[static_cast<size_t>(subWrite_)] = subSum_ / static_cast<double>(subLength_);
    subWrite_ = (subWrite_ + 1) % kSub;
    subFilled_ = std::min(subFilled_ + 1, kSub);
    subSum_ = 0;
    subCount_ = 0;
    auto mean = [&](int count) {
        double s = 0;
        for (int i = 1; i <= count; ++i) s += subs_[static_cast<size_t>((subWrite_ - i + kSub) % kSub)];
        return s / count;
    };
    if (subFilled_ >= 4) {
        const double m = mean(4);
        maxM_ = std::max(maxM_, m);
        momentary_.store(static_cast<float>(lufs(m)), std::memory_order_relaxed);
        maxMomentary_.store(static_cast<float>(lufs(maxM_)), std::memory_order_relaxed);
        const double l = lufs(m);
        if (l > -70) { // absolute gate
            const int bin = std::clamp(static_cast<int>((l + 70) * 10), 0, kBins - 1);
            binEnergy_[static_cast<size_t>(bin)] += m;
            ++binCount_[static_cast<size_t>(bin)];
            double e = 0; int64_t c = 0;
            for (int b = 0; b < kBins; ++b) { e += binEnergy_[static_cast<size_t>(b)]; c += binCount_[static_cast<size_t>(b)]; }
            const double gate = lufs(e / static_cast<double>(c)) - 10; // relative gate
            e = 0; c = 0;
            for (int b = 0; b < kBins; ++b) {
                if (-70 + (b + 1) * 0.1 <= gate) continue; // bins wholly below the gate
                e += binEnergy_[static_cast<size_t>(b)]; c += binCount_[static_cast<size_t>(b)];
            }
            if (c > 0) integrated_.store(static_cast<float>(lufs(e / static_cast<double>(c))), std::memory_order_relaxed);
        }
    }
    if (subFilled_ >= kSub) {
        const double s = mean(kSub);
        maxS_ = std::max(maxS_, s);
        shortTerm_.store(static_cast<float>(lufs(s)), std::memory_order_relaxed);
        maxShortTerm_.store(static_cast<float>(lufs(maxS_)), std::memory_order_relaxed);
    }
}

void LoudnessMeter::process(const float *left, const float *right, int frames) DALNOK_NONBLOCKING {
    if (resetPending_.exchange(false, std::memory_order_acq_rel)) clear();
    auto run = [](Biquad &b, double x) {
        const double y = b.b0 * x + b.b1 * b.x1 + b.b2 * b.x2 - b.a1 * b.y1 - b.a2 * b.y2;
        b.x2 = b.x1; b.x1 = x; b.y2 = b.y1; b.y1 = y;
        return y;
    };
    for (int i = 0; i < frames; ++i) {
        const double l = run(highPass_[0], run(shelf_[0], left[i])), r = run(highPass_[1], run(shelf_[1], right[i]));
        subSum_ += l * l + r * r;
        if (++subCount_ == subLength_) subBlockDone();
        // True peak: the sample itself and three interpolated points before it.
        histL_[static_cast<size_t>(histPos_)] = left[i];
        histR_[static_cast<size_t>(histPos_)] = right[i];
        histPos_ = (histPos_ + 1) % kTaps;
        for (int p = 0; p < kPhases; ++p) {
            const float *h = fir_.data() + p * kTaps;
            double sl = 0, sr = 0;
            for (int t = 0; t < kTaps; ++t) {
                const auto k = static_cast<size_t>((histPos_ - 1 - t + 2 * kTaps) % kTaps);
                sl += h[t] * histL_[k];
                sr += h[t] * histR_[k];
            }
            peak_ = std::max({peak_, std::fabs(sl), std::fabs(sr)});
        }
        peak_ = std::max({peak_, static_cast<double>(std::fabs(left[i])), static_cast<double>(std::fabs(right[i]))});
    }
    truePeak_.store(peak_ > 0 ? static_cast<float>(20 * std::log10(peak_)) : kNone, std::memory_order_relaxed);
}

LoudnessReading LoudnessMeter::reading() const {
    return {momentary_.load(std::memory_order_relaxed), shortTerm_.load(std::memory_order_relaxed),
            integrated_.load(std::memory_order_relaxed), truePeak_.load(std::memory_order_relaxed),
            maxMomentary_.load(std::memory_order_relaxed), maxShortTerm_.load(std::memory_order_relaxed)};
}

} // namespace dalnok

#pragma clang diagnostic pop
