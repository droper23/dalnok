// Decoded, immutable audio held in memory, plus a min/max peak pyramid.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace atrium {

class Media {
public:
    Media(std::vector<std::vector<float>> channels, double sampleRate);

    int32_t channelCount() const { return static_cast<int32_t>(channels_.size()); }
    int64_t frames() const { return frames_; }
    double sampleRate() const { return sampleRate_; }
    const float *channel(int32_t c) const { return channels_[static_cast<size_t>(c)].data(); }

    int64_t peaks(int32_t channel, int64_t startFrame, double framesPerColumn, float *minOut,
                  float *maxOut, int64_t count) const;

private:
    struct Level {
        int64_t blockSize;
        std::vector<std::vector<float>> mins, maxs; // [channel][block]
    };
    void buildPeaks();

    std::vector<std::vector<float>> channels_;
    int64_t frames_ = 0;
    double sampleRate_ = 0;
    std::vector<Level> levels_; // increasing block size
};

// Platform services (implemented per OS under platform/).
bool decodeAudioFile(const std::string &path, double sampleRate,
                     std::vector<std::vector<float>> &channels, std::string &err);

class WavWriter {
public:
    virtual ~WavWriter() = default;
    virtual bool write(const float *left, const float *right, int64_t frames, std::string &err) = 0;
    virtual bool close(std::string &err) = 0;
};
WavWriter *openWavWriter(const std::string &path, double sampleRate, int32_t bits, std::string &err);

} // namespace atrium
