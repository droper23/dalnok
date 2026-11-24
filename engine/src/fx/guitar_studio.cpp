// Gate -> linked compression -> 4x drive -> tone -> cabinet -> chorus -> tremolo -> echo -> room.
// The cabinet is an original filter model, not an IR or a model of commercial equipment.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/guitar_studio.hpp"
#include <algorithm>
#include <cmath>

namespace dalnok::fx {
namespace {
using P = BuiltinProcessor::Param;
constexpr double pi = 3.14159265358979323846;
const char *const voices[] = {"Clean", "Crunch", "Lead"};
const char *const cabinets[] = {"Open 1x12", "Closed 2x12", "Stack 4x12"};
const std::vector<P> params = {
    {0, "Input Gain", "dB", -24, 24, 0},
    {1, "Input Gate", "dB", -90, -20, -70},
    {2, "Input Compression", "%", 0, 100, 20},
    {3, "Amp Voice", "", 0, 2, 0, P::Choice, voices},
    {4, "Amp Drive", "%", 0, 100, 30},
    {5, "Amp Bass", "dB", -12, 12, 0},
    {6, "Amp Middle", "dB", -12, 12, 0},
    {7, "Amp Treble", "dB", -12, 12, 0},
    {8, "Cabinet Model", "", 0, 2, 0, P::Choice, cabinets},
    {9, "Cabinet Mix", "%", 0, 100, 100},
    {10, "Chorus Rate", "Hz", 0.05, 8, 0.7, P::Log},
    {11, "Chorus Depth", "ms", 0, 6, 2},
    {12, "Chorus Mix", "%", 0, 50, 0},
    {13, "Tremolo Rate", "Hz", 0.1, 15, 4, P::Log},
    {14, "Tremolo Depth", "%", 0, 100, 0},
    {15, "Echo Time", "ms", 25, 1500, 375, P::Log},
    {16, "Echo Feedback", "%", 0, 85, 30},
    {17, "Echo Mix", "%", 0, 60, 0},
    {18, "Room Decay", "s", 0.15, 8, 1.8, P::Log},
    {19, "Room Tone", "Hz", 800, 12000, 5000, P::Log},
    {20, "Room Mix", "%", 0, 60, 12},
    {21, "Output Gain", "dB", -36, 12, -6},
    {22, "Output Mix", "%", 0, 100, 100},
};
// libm coefficient/nonlinear operations are allocation- and lock-free, as in the stock effects.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
double pole(double hz, double rate) { return 1 - std::exp(-2 * pi * std::min(hz, rate * 0.45) / rate); }
double db(double v) { return std::pow(10.0, v / 20); }
#pragma clang diagnostic pop
}

GuitarStudio::GuitarStudio(double rate) : BuiltinProcessor("guitar-studio", "Dalnok Guitar Studio", params), rate_(rate) {
    smoothing_ = 1 - std::exp(-1 / (0.02 * rate));
    attack_ = 1 - std::exp(-1 / (0.001 * rate));
    release_ = 1 - std::exp(-1 / (0.08 * rate));
    bassCoef_ = pole(250, rate); midCoef_ = pole(2200, rate); dcCoef_ = pole(45, rate);
    for (auto &ch : channel_) {
        ch.chorus.resize(static_cast<size_t>(rate * 0.05) + 4);
        ch.echo.resize(static_cast<size_t>(rate * 1.51) + 4);
    }
    constexpr double seconds[] = {0.0297, 0.0371, 0.0411, 0.0437};
    for (size_t j = 0; j < 4; ++j) room_[j].resize(static_cast<size_t>(rate * seconds[j]) | 1);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects" // libm only; all buffers are allocated in the constructor.
void GuitarStudio::changed() DALNOK_NONBLOCKING {
    for (uint32_t i = 0; i < kCount; ++i) target_[i] = rt(i);
    for (auto i : {kInput, kBass, kMiddle, kTreble, kOutput, kGate}) target_[i] = db(rt(i));
    for (auto i : {kCompression, kCabinetMix, kChorusMix, kTremoloDepth, kDelayFeedback, kDelayMix, kReverbMix, kMix}) target_[i] *= 0.01;
    // Separate voice gain ranges; interpolation on changes avoids steps.
    const int voice = std::clamp(static_cast<int>(std::round(rt(kVoice))), 0, 2);
    target_[kDrive] = db(rt(kDrive) * (voice == 0 ? 0.12 : voice == 1 ? 0.3 : 0.48));
    const int cabinet = std::clamp(static_cast<int>(std::round(rt(kCabinet))), 0, 2);
    target_[kCabinet] = pole(cabinet == 0 ? 6500 : cabinet == 1 ? 5000 : 3800, rate_);
    target_[kDelayTime] = rt(kDelayTime) * rate_ * 0.001;
    target_[kChorusDepth] = rt(kChorusDepth) * rate_ * 0.001;
    target_[kReverbTone] = pole(rt(kReverbTone), rate_);
    for (size_t j = 0; j < 4; ++j)
        roomGainTarget_[j] = std::pow(10.0, -3 * static_cast<double>(room_[j].size()) / (rate_ * rt(kReverbDecay)));
    if (!primed_) { current_ = target_; roomGain_ = roomGainTarget_; primed_ = true; }
}
#pragma clang diagnostic pop

double GuitarStudio::read(const std::vector<float> &line, double delay) const DALNOK_NONBLOCKING {
    const size_t size = line.size();
    const auto whole = static_cast<uint64_t>(delay);
    const double fraction = delay - static_cast<double>(whole);
    const size_t a = static_cast<size_t>((write_ + size - whole) % size);
    const size_t b = (a + size - 1) % size;
    return line[a] + fraction * (line[b] - line[a]);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects" // sin, tanh, pow are allocation- and lock-free.
void GuitarStudio::process(float *left, float *right, int frames, const PluginNote *, int) DALNOK_NONBLOCKING {
    applyPending();
    for (int frame = 0; frame < frames; ++frame) {
        for (uint32_t i = 0; i < kCount; ++i) current_[i] += smoothing_ * (target_[i] - current_[i]);
        const auto &p = current_;
        double dry[2] = {std::isfinite(left[frame]) ? left[frame] : 0, std::isfinite(right[frame]) ? right[frame] : 0};
        const double peak = std::max(std::abs(dry[0]), std::abs(dry[1])) * p[kInput];
        envelope_ += (peak > envelope_ ? attack_ : release_) * (peak - envelope_);
        const double gateTarget = envelope_ > p[kGate] || p[kGate] < 0.000032 ? 1 : 0;
        gate_ += (gateTarget > gate_ ? attack_ : release_) * (gateTarget - gate_);
        // 4:1 above -18 dB; amount blends in linked compression and modest makeup.
        const double comp = std::pow(std::max(1.0, envelope_ / 0.126), -0.75);
        const double gain = p[kInput] * gate_ * (1 + p[kCompression] * (comp * 1.5 - 1));
        double out[2];
        for (int c = 0; c < 2; ++c) {
            auto &ch = channel_[c];
            double x = dry[c] * gain;
            ch.dc += dcCoef_ * (x - ch.dc); x -= ch.dc;
            // Four substeps interpolate the input; four low-pass sections precede decimation.
            // This suppresses folded drive harmonics; it is not a zero-alias or circuit-model claim.
            double amp = 0;
            for (int sub = 1; sub <= 4; ++sub) {
                const double up = ch.previous + (x - ch.previous) * (sub * 0.25);
                amp = std::tanh(up * p[kDrive]) / std::sqrt(p[kDrive]);
                for (double &stage : ch.down) { stage += 0.48 * (amp - stage); amp = stage; }
            }
            ch.previous = x;
            ch.bass += bassCoef_ * (amp - ch.bass);
            ch.middle += midCoef_ * (amp - ch.middle);
            x = ch.bass * p[kBass] + (ch.middle - ch.bass) * p[kMiddle] + (amp - ch.middle) * p[kTreble];
            double cab = x;
            for (double &stage : ch.cab) { stage += p[kCabinet] * (cab - stage); cab = stage; }
            x += p[kCabinetMix] * (cab - x);
            ch.chorus[write_ % ch.chorus.size()] = static_cast<float>(x);
            const double delay = 0.012 * rate_ + p[kChorusDepth] * std::sin(chorusPhase_ + c * pi * 0.5);
            x += p[kChorusMix] * (read(ch.chorus, delay) - x);
            x *= 1 - p[kTremoloDepth] * (0.5 + 0.5 * std::sin(tremoloPhase_));
            const double echo = read(ch.echo, p[kDelayTime]);
            ch.echoTone += 0.35 * (echo - ch.echoTone);
            ch.echo[write_ % ch.echo.size()] = static_cast<float>(x + p[kDelayFeedback] * ch.echoTone);
            out[c] = x + p[kDelayMix] * echo;
        }
        double roomRead[4], sum = 0;
        for (size_t j = 0; j < 4; ++j) {
            roomGain_[j] += smoothing_ * (roomGainTarget_[j] - roomGain_[j]);
            roomDamp_[j] += p[kReverbTone] * (room_[j][roomPos_[j]] - roomDamp_[j]);
            roomRead[j] = roomDamp_[j]; sum += roomRead[j];
        }
        const double feed = (out[0] + out[1]) * 0.25;
        for (size_t j = 0; j < 4; ++j) {
            room_[j][roomPos_[j]] = static_cast<float>(feed + (roomRead[j] - 0.5 * sum) * roomGain_[j]);
            roomPos_[j] = (roomPos_[j] + 1) % room_[j].size();
        }
        out[0] += p[kReverbMix] * (roomRead[0] - roomRead[1]);
        out[1] += p[kReverbMix] * (roomRead[2] - roomRead[3]);
        left[frame] = static_cast<float>(dry[0] + p[kMix] * (out[0] * p[kOutput] - dry[0]));
        right[frame] = static_cast<float>(dry[1] + p[kMix] * (out[1] * p[kOutput] - dry[1]));
        ++write_;
        chorusPhase_ += 2 * pi * p[kChorusRate] / rate_;
        tremoloPhase_ += 2 * pi * p[kTremoloRate] / rate_;
        if (chorusPhase_ >= 2 * pi) chorusPhase_ -= 2 * pi;
        if (tremoloPhase_ >= 2 * pi) tremoloPhase_ -= 2 * pi;
    }
}
#pragma clang diagnostic pop
} // namespace dalnok::fx
