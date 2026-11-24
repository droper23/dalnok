// Original guitar channel strip; no third-party models or cabinet recordings.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "fx/builtin.hpp"
#include <array>
#include <vector>

namespace dalnok::fx {
class GuitarStudio final : public BuiltinProcessor {
public:
    explicit GuitarStudio(double sampleRate);
    void process(float *, float *, int, const PluginNote *, int) DALNOK_NONBLOCKING override;
    enum : uint32_t {
        kInput, kGate, kCompression, kVoice, kDrive, kBass, kMiddle, kTreble,
        kCabinet, kCabinetMix, kChorusRate, kChorusDepth, kChorusMix,
        kTremoloRate, kTremoloDepth, kDelayTime, kDelayFeedback, kDelayMix,
        kReverbDecay, kReverbTone, kReverbMix, kOutput, kMix, kCount
    };
private:
    void changed() DALNOK_NONBLOCKING override;
    double read(const std::vector<float> &, double delay) const DALNOK_NONBLOCKING;
    double rate_, smoothing_, envelope_ = 0, gate_ = 0, chorusPhase_ = 0, tremoloPhase_ = 0;
    double bassCoef_, midCoef_, dcCoef_, attack_, release_;
    std::array<double, kCount> target_{}, current_{};
    bool primed_ = false;
    uint64_t write_ = 0;
    struct Channel {
        double previous = 0, dc = 0, bass = 0, middle = 0, cab[3]{}, down[4]{}, echoTone = 0;
        std::vector<float> chorus, echo;
    } channel_[2];
    std::array<std::vector<float>, 4> room_;
    std::array<size_t, 4> roomPos_{};
    std::array<double, 4> roomDamp_{}, roomGain_{}, roomGainTarget_{};
};
} // namespace dalnok::fx
