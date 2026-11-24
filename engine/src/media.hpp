// Decoded, immutable audio held in memory, plus a min/max peak pyramid.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "rt.hpp"

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace dalnok {

class StreamSource;

class Media {
public:
    struct Level {
        int64_t blockSize;
        std::vector<std::vector<float>> mins, maxs; // [channel][block]
    };

    Media(std::vector<std::vector<float>> channels, double sampleRate);
    // Streamed from a cache file (A-09); `base` is its finest peak level, coarser ones are built from it.
    Media(std::shared_ptr<StreamSource> source, double sampleRate, Level base);
    ~Media();

    // Decodes `path` at `sampleRate`: into memory, or (longer than StreamCache's threshold) into a cache file it
    // streams from. Reuses an existing cache file for the same file and rate.
    static std::shared_ptr<const Media> loadFile(const std::string &path, double sampleRate, std::string &err);

    int32_t channelCount() const DALNOK_NONBLOCKING { return channels_count_; }
    int64_t frames() const { return frames_; }
    double sampleRate() const { return sampleRate_; }
    bool streamed() const DALNOK_NONBLOCKING { return source_ != nullptr; }
    StreamSource *source() const { return source_.get(); }
    // In-memory samples; null for streamed media (use read, or readResident on the audio thread).
    const float *channel(int32_t c) const { return streamed() ? nullptr : channels_[static_cast<size_t>(c)].data(); }
    // Copies frames [start, start + n) (r may equal l for mono). May block on disk for streamed media.
    void read(int64_t start, int64_t n, float *l, float *r) const;
    // Audio thread: streamed media from resident blocks only (missing frames are zero). Returns frames missed.
    int readResident(int64_t start, int n, float *l, float *r) const DALNOK_NONBLOCKING;

    int64_t peaks(int32_t channel, int64_t startFrame, double framesPerColumn, float *minOut,
                  float *maxOut, int64_t count) const;

private:
    void buildPeaks();
    void buildCoarserLevels();

    std::vector<std::vector<float>> channels_;
    std::shared_ptr<StreamSource> source_;
    int64_t frames_ = 0;
    int32_t channels_count_ = 0;
    double sampleRate_ = 0;
    std::vector<Level> levels_; // increasing block size
};

// Platform services (implemented per OS under platform/).
bool decodeAudioFile(const std::string &path, double sampleRate,
                     std::vector<std::vector<float>> &channels, std::string &err);
// Decodes in chunks: `sink(channels, channelCount, frames)` receives planar float (at most two channels); return false
// from it to stop. `channelCount` reports the channels delivered.
bool decodeAudioFileChunked(const std::string &path, double sampleRate,
                            const std::function<bool(const float *const *, int32_t, int64_t)> &sink,
                            int32_t &channelCount, std::string &err);

// Reads a property list (XML or binary) into JSON-like values (macOS: CoreFoundation).
namespace json { struct Value; }
bool readPropertyList(const std::string &path, json::Value &out, std::string &err);

// Reads only the header: native sample rate, length in frames, channel count.
bool probeAudioFile(const std::string &path, double &sampleRate, int64_t &frames, int32_t &channels, std::string &err);

class WavWriter {
public:
    virtual ~WavWriter() = default;
    virtual bool write(const float *left, const float *right, int64_t frames, std::string &err) = 0;
    virtual bool close(std::string &err) = 0;
};
WavWriter *openWavWriter(const std::string &path, double sampleRate, int32_t bits, std::string &err);
// Any export format (DalnokFileFormat): WAV 16/24/32-bit float, AIFF 24-bit, AAC 256 kbit/s (.m4a), Apple Lossless
// (.m4a, 24-bit) or FLAC (24-bit). 16-bit WAV is dithered.
WavWriter *openAudioWriter(const std::string &path, double sampleRate, int32_t format, std::string &err);

} // namespace dalnok

// The C API's opaque media handle: one reference to shared, immutable media.
struct DalnokMedia {
    std::shared_ptr<const dalnok::Media> impl;
};
