// YIN-style periodicity detection (de Cheveigne/Kawahara, JASA 2002):
// https://www.ee.columbia.edu/~dpwe/e6820/papers/deChevK02-yin.pdf
// Own implementation; fixed memory, bounded analysis, shared stereo pitch trajectory.
// Two complementary Hann-window delay heads shift small intervals. This is intended
// for clean single-note DI, before distortion; not polyphonic or formant correction.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/guitar_tune.hpp"
#include <algorithm>
#include <cmath>

namespace dalnok::fx {
namespace {
using P = BuiltinProcessor::Param;
constexpr double pi = 3.14159265358979323846;
const char *const roots[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
const char *const scales[] = {"Chromatic", "Major", "Minor"};
}
GuitarTune::GuitarTune(double rate) : BuiltinProcessor("guitar-tune", "Dalnok Guitar Tune", {
    {0, "Correction Amount", "%", 0, 100, 80},
    {1, "Correction Retune", "ms", 5, 500, 80, P::Log},
    {2, "Bend Tolerance", "cents", 0, 200, 45},
    {3, "Tuning Reference", "Hz", 430, 450, 440},
    {4, "Tuning Root", "", 0, 11, 0, P::Choice, roots},
    {5, "Tuning Scale", "", 0, 2, 0, P::Choice, scales},
    {6, "Output Mix", "%", 0, 100, 100},
    {7, "Detected Pitch", "Hz", 0, 1500, 0, P::Linear, nullptr, true},
    {8, "Pitch Error", "cents", -100, 100, 0, P::Linear, nullptr, true},
    {9, "Confidence", "%", 0, 100, 0, P::Linear, nullptr, true}
}), rate_(rate), analysisRate_(rate / std::max(1, int(rate / 12000))),
    span_(std::round(rate * .05)), filterCoef_(1 - std::exp(-2 * pi * 1800 / rate)),
    decimation_(std::max(1, int(rate / 12000))), latency_(uint32_t(span_ / 2 + 8)) {
    for (auto &d : delay_) d.assign(size_t(span_) + 32, 0);
}
// libm here is allocation/lock-free; all buffers are allocated by the constructor.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
void GuitarTune::changed() DALNOK_NONBLOCKING {
    smoothing_ = 1 - std::exp(-1 / (rate_ * rt(1) * .001));
}
double GuitarTune::meter(uint32_t id) const {
    if (id == 7) return pitch_.load(std::memory_order_relaxed);
    if (id == 8) return cents_.load(std::memory_order_relaxed);
    if (id == 9) return confidence_.load(std::memory_order_relaxed);
    return 0;
}
void GuitarTune::detect() DALNOK_NONBLOCKING {
    constexpr int window = 384;
    const int maxLag = std::min(254, int(analysisRate_ / 65));
    const int minLag = std::max(2, int(analysisRate_ / 1400));
    auto sample = [&](int back) { return double(history_[size_t((count_ - 1 - back) & 1023)]); };
    double energy = 0;
    for (int i = 0; i < window; ++i) energy += sample(i) * sample(i);
    target_ = 1;
    pitch_.store(0, std::memory_order_relaxed);
    confidence_.store(0, std::memory_order_relaxed);
    cents_.store(0, std::memory_order_relaxed);
    if (energy / window < 1e-8) return;
    double sum = 0;
    normalized_[0] = 1;
    for (int lag = 1; lag <= maxLag; ++lag) {
        double d = 0;
        for (int i = 0; i < window; ++i) {
            const double delta = sample(i) - sample(i + lag);
            d += delta * delta;
        }
        difference_[lag] = d;
        sum += d;
        normalized_[lag] = sum > 1e-20 ? d * lag / sum : 1;
    }
    int best = 0;
    for (int lag = minLag; lag < maxLag; ++lag) {
        if (normalized_[lag] < .12) {
            while (lag + 1 < maxLag && normalized_[lag + 1] < normalized_[lag]) ++lag;
            best = lag; break;
        }
    }
    if (!best || best >= maxLag) return;
    const double a = difference_[best - 1], b = difference_[best], c = difference_[best + 1];
    const double denom = a - 2 * b + c;
    const double offset = std::abs(denom) > 1e-20 ? std::clamp(.5 * (a - c) / denom, -.5, .5) : 0;
    const double hz = analysisRate_ / (best + offset);
    if (hz < 65 || hz > 1400) return;
    const double note = 69 + 12 * std::log2(hz / rt(3));
    double nearest = std::round(note), distance = 100;
    const int scale = int(rt(5)), root = int(rt(4));
    constexpr int major = 0b101010110101, minor = 0b010110101101;
    for (int n = int(std::floor(note)) - 2; n <= int(std::ceil(note)) + 2; ++n) {
        const int pc = ((n - root) % 12 + 12) % 12;
        if (scale && !((scale == 1 ? major : minor) & (1 << pc))) continue;
        if (std::abs(n - note) < distance) { nearest = n; distance = std::abs(n - note); }
    }
    const double error = (note - nearest) * 100;
    pitch_.store(float(hz), std::memory_order_relaxed);
    cents_.store(float(std::clamp(error, -100.0, 100.0)), std::memory_order_relaxed);
    confidence_.store(float(100 * (1 - normalized_[best])), std::memory_order_relaxed);
    if (rt(2) > 0 && std::abs(error) > rt(2)) return;
    target_ = std::pow(2.0, -error * rt(0) / 120000);
}
double GuitarTune::read(int channel, double delay) const DALNOK_NONBLOCKING {
    const int size = int(delay_[channel].size());
    double pos = write_ - delay;
    if (pos < 0) pos += size;
    const int at = int(pos);
    const double fraction = pos - at;
    return delay_[channel][at] + fraction * (delay_[channel][(at + 1) % size] - delay_[channel][at]);
}
void GuitarTune::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    for (int i = 0; i < frames; ++i) {
        if (!std::isfinite(left[i])) left[i] = 0;
        if (!std::isfinite(right[i])) right[i] = 0;
        // Detect on the louder channel so polarity-inverted stereo does not cancel.
        const double input = std::abs(left[i]) >= std::abs(right[i]) ? left[i] : right[i];
        filter_[0] += filterCoef_ * (input - filter_[0]);
        filter_[1] += filterCoef_ * (filter_[0] - filter_[1]);
        if (++decimated_ == decimation_) {
            decimated_ = 0;
            history_[size_t(count_ & 1023)] = float(filter_[1]);
            count_ = (count_ + 1) & 2047;
            if (++hop_ >= 128) { hop_ = 0; detect(); }
        }
        ratio_ += smoothing_ * (target_ - ratio_);
        mix_ += .002 * (rt(6) * .01 - mix_);
        phase_ += (1 - ratio_) / span_;
        if (phase_ >= 1) phase_ -= 1;
        if (phase_ < 0) phase_ += 1;
        const double other = phase_ < .5 ? phase_ + .5 : phase_ - .5;
        const double weight = .5 - .5 * std::cos(2 * pi * phase_);
        for (int ch = 0; ch < 2; ++ch) {
            float &out = ch ? right[i] : left[i];
            delay_[ch][write_] = out;
            const double wet = weight * read(ch, 8 + phase_ * span_) + (1 - weight) * read(ch, 8 + other * span_);
            out = float(read(ch, latency_) * (1 - mix_) + wet * mix_);
        }
        if (++write_ == int(delay_[0].size())) write_ = 0;
    }
}
#pragma clang diagnostic pop
}
