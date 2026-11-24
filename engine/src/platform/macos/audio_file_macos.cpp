// Audio file decode/encode via ExtAudioFile (WAV, AIFF, CAF, MP3, AAC, ALAC, FLAC).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "media.hpp"
#include "dalnok/dalnok.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace dalnok {

namespace {

std::string statusErr(const char *what, OSStatus s) {
    return std::string(what) + " failed (OSStatus " + std::to_string(static_cast<int>(s)) + ")";
}

CFURLRef makeURL(const std::string &path) {
    return CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(path.c_str()),
                                                   static_cast<CFIndex>(path.size()), false);
}

AudioStreamBasicDescription planarFloat(double sr, UInt32 channels) {
    AudioStreamBasicDescription f{};
    f.mSampleRate = sr;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) | kAudioFormatFlagIsNonInterleaved;
    f.mChannelsPerFrame = channels;
    f.mFramesPerPacket = 1;
    f.mBitsPerChannel = 32;
    f.mBytesPerFrame = 4;
    f.mBytesPerPacket = 4;
    return f;
}

} // namespace

bool decodeAudioFileChunked(const std::string &path, double sampleRate,
                            const std::function<bool(const float *const *, int32_t, int64_t)> &sink,
                            int32_t &channelCount, std::string &err) {
    CFURLRef url = makeURL(path);
    if (!url) {
        err = "invalid path";
        return false;
    }
    ExtAudioFileRef file = nullptr;
    OSStatus s = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (s != noErr) {
        err = statusErr("open audio file", s);
        return false;
    }

    AudioStreamBasicDescription fileFmt{};
    UInt32 size = sizeof(fileFmt);
    ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFmt);
    // Phase 1: mono and stereo. Wider files keep their first two channels.
    const UInt32 fileChannels = std::max<UInt32>(1, fileFmt.mChannelsPerFrame);
    const UInt32 channels = std::min<UInt32>(2, fileChannels);
    const double rate = sampleRate > 0 ? sampleRate : fileFmt.mSampleRate;
    channelCount = static_cast<int32_t>(channels);

    AudioStreamBasicDescription client = planarFloat(rate, fileChannels);
    s = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    if (s != noErr) {
        ExtAudioFileDispose(file);
        err = statusErr("set client format", s);
        return false;
    }

    constexpr UInt32 kChunk = 32768;
    std::vector<std::vector<float>> tmp(fileChannels, std::vector<float>(kChunk));
    std::vector<char> ablStorage(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * fileChannels);
    auto *abl = reinterpret_cast<AudioBufferList *>(ablStorage.data());
    const float *planes[2] = {tmp[0].data(), tmp[channels > 1 ? 1 : 0].data()};
    int64_t total = 0;
    for (;;) {
        abl->mNumberBuffers = fileChannels;
        for (UInt32 c = 0; c < fileChannels; ++c) {
            abl->mBuffers[c].mNumberChannels = 1;
            abl->mBuffers[c].mDataByteSize = kChunk * sizeof(float);
            abl->mBuffers[c].mData = tmp[c].data();
        }
        UInt32 frames = kChunk;
        s = ExtAudioFileRead(file, &frames, abl);
        if (s != noErr) {
            ExtAudioFileDispose(file);
            err = statusErr("decode audio", s);
            return false;
        }
        if (frames == 0) break;
        total += frames;
        // Float files can carry NaN, Inf and absurd peaks; one poisoned sample would turn the whole mix to NaN.
        for (UInt32 c = 0; c < channels; ++c) {
            float *p = tmp[c].data();
            for (UInt32 i = 0; i < frames; ++i) {
                const float v = p[i];
                p[i] = std::isfinite(v) ? std::clamp(v, -1000.0f, 1000.0f) : 0.0f;
            }
        }
        if (!sink(planes, static_cast<int32_t>(channels), frames)) break;
    }
    ExtAudioFileDispose(file);
    if (total == 0) {
        err = "file contains no audio";
        return false;
    }
    return true;
}

bool decodeAudioFile(const std::string &path, double sampleRate, std::vector<std::vector<float>> &out,
                     std::string &err) {
    std::vector<std::vector<float>> all;
    int32_t channels = 0;
    const bool ok = decodeAudioFileChunked(path, sampleRate, [&](const float *const *ch, int32_t n, int64_t frames) {
        if (all.empty()) all.resize(static_cast<size_t>(n));
        for (int32_t c = 0; c < n; ++c) all[static_cast<size_t>(c)].insert(all[static_cast<size_t>(c)].end(), ch[c], ch[c] + frames);
        return true;
    }, channels, err);
    if (!ok) return false;
    out = std::move(all);
    return true;
}

bool probeAudioFile(const std::string &path, double &sampleRate, int64_t &frames, int32_t &channels, std::string &err) {
    CFURLRef url = makeURL(path);
    if (!url) {
        err = "invalid path";
        return false;
    }
    ExtAudioFileRef file = nullptr;
    OSStatus s = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (s != noErr) {
        err = statusErr("open audio file", s);
        return false;
    }
    AudioStreamBasicDescription fmt{};
    UInt32 size = sizeof(fmt);
    ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fmt);
    SInt64 n = 0;
    size = sizeof(n);
    ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &n);
    ExtAudioFileDispose(file);
    sampleRate = fmt.mSampleRate;
    frames = n;
    channels = static_cast<int32_t>(fmt.mChannelsPerFrame);
    return sampleRate > 0;
}

namespace {

class ExtWavWriter final : public WavWriter {
public:
    ExtWavWriter(ExtAudioFileRef f, int32_t ditherBits) : file_(f), dither_(ditherBits == 16) {}
    ~ExtWavWriter() override {
        std::string ignored;
        close(ignored);
    }

    bool write(const float *left, const float *right, int64_t frames, std::string &err) override {
        while (frames > 0) {
            const auto n = static_cast<UInt32>(std::min<int64_t>(frames, 65536));
            const float *l = left, *r = right;
            if (dither_) { // 16-bit: TPDF dither of one LSB, so quiet passages and fades decay into noise, not distortion
                dl_.assign(left, left + n);
                dr_.assign(right, right + n);
                for (UInt32 i = 0; i < n; ++i) {
                    if (dl_[i] == 0 && dr_[i] == 0) continue; // digital silence stays silent (null tests stay exact)
                    dl_[i] += tpdf();
                    dr_[i] += tpdf();
                }
                l = dl_.data();
                r = dr_.data();
            }
            struct {
                UInt32 count;
                AudioBuffer bufs[2];
            } abl{2, {{1, n * 4, const_cast<float *>(l)}, {1, n * 4, const_cast<float *>(r)}}};
            OSStatus s = ExtAudioFileWrite(file_, n, reinterpret_cast<AudioBufferList *>(&abl));
            if (s != noErr) {
                err = statusErr("write audio", s);
                return false;
            }
            left += n;
            right += n;
            frames -= n;
        }
        return true;
    }

    bool close(std::string &err) override {
        if (!file_) return true;
        OSStatus s = ExtAudioFileDispose(file_);
        file_ = nullptr;
        if (s != noErr) {
            err = statusErr("finalize file", s);
            return false;
        }
        return true;
    }

private:
    // Triangular noise of +-1 LSB at 16 bits: the sum of two uniform values (xorshift, fixed seed: renders repeat).
    float tpdf() {
        auto next = [this] {
            seed_ ^= seed_ << 13; seed_ ^= seed_ >> 17; seed_ ^= seed_ << 5;
            return static_cast<float>(seed_) * (1.0f / 4294967296.0f);
        };
        return (next() - next()) * (1.0f / 32768.0f);
    }
    ExtAudioFileRef file_;
    bool dither_;
    uint32_t seed_ = 0x9E3779B9u;
    std::vector<float> dl_, dr_;
};

} // namespace

WavWriter *openWavWriter(const std::string &path, double sampleRate, int32_t bits, std::string &err) {
    if (bits != 16 && bits != 24 && bits != 32) {
        err = "bits must be 16, 24 or 32";
        return nullptr;
    }
    return openAudioWriter(path, sampleRate, bits == 16 ? DALNOK_FORMAT_WAV16 : bits == 24 ? DALNOK_FORMAT_WAV24 : DALNOK_FORMAT_WAV32F, err);
}

WavWriter *openAudioWriter(const std::string &path, double sampleRate, int32_t format, std::string &err) {
    AudioStreamBasicDescription fmt{};
    fmt.mSampleRate = sampleRate;
    fmt.mChannelsPerFrame = 2;
    AudioFileTypeID type = kAudioFileWAVEType;
    UInt32 bitRate = 0;
    int32_t ditherBits = 0;
    auto pcm = [&](UInt32 bits, bool isFloat, bool bigEndian) {
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFramesPerPacket = 1;
        fmt.mBitsPerChannel = bits;
        fmt.mBytesPerFrame = 2 * bits / 8;
        fmt.mBytesPerPacket = fmt.mBytesPerFrame;
        fmt.mFormatFlags = kAudioFormatFlagIsPacked | (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                           (bigEndian ? kAudioFormatFlagIsBigEndian : 0);
    };
    switch (format) {
    case DALNOK_FORMAT_WAV16: pcm(16, false, false); ditherBits = 16; break;
    case DALNOK_FORMAT_WAV24: pcm(24, false, false); break;
    case DALNOK_FORMAT_WAV32F: pcm(32, true, false); break;
    case DALNOK_FORMAT_AIFF24: pcm(24, false, true); type = kAudioFileAIFFType; break;
    case DALNOK_FORMAT_AAC: fmt.mFormatID = kAudioFormatMPEG4AAC; type = kAudioFileM4AType; bitRate = 256000; break;
    case DALNOK_FORMAT_ALAC:
        fmt.mFormatID = kAudioFormatAppleLossless; fmt.mFormatFlags = kAppleLosslessFormatFlag_24BitSourceData;
        fmt.mFramesPerPacket = 4096; type = kAudioFileM4AType; break;
    case DALNOK_FORMAT_FLAC:
        fmt.mFormatID = kAudioFormatFLAC; fmt.mFormatFlags = kAppleLosslessFormatFlag_24BitSourceData;
        fmt.mFramesPerPacket = 4096; type = kAudioFileFLACType; break;
    default: err = "unknown export format"; return nullptr;
    }
    CFURLRef url = makeURL(path);
    if (!url) {
        err = "invalid path";
        return nullptr;
    }
    ExtAudioFileRef file = nullptr;
    OSStatus s = ExtAudioFileCreateWithURL(url, type, &fmt, nullptr, kAudioFileFlags_EraseFile, &file);
    CFRelease(url);
    if (s != noErr) {
        err = statusErr("create file", s);
        return nullptr;
    }
    AudioStreamBasicDescription client = planarFloat(sampleRate, 2);
    s = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    if (s == noErr && bitRate) {
        AudioConverterRef conv = nullptr;
        UInt32 size = sizeof(conv);
        if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &conv) == noErr && conv) {
            AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, sizeof(bitRate), &bitRate);
            CFArrayRef config = nullptr; // tell ExtAudioFile the converter changed
            ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, sizeof(config), &config);
        }
    }
    if (s != noErr) {
        ExtAudioFileDispose(file);
        err = statusErr("set client format", s);
        return nullptr;
    }
    return new ExtWavWriter(file, ditherBits);
}

} // namespace dalnok
