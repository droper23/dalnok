// Audio file decode/encode via ExtAudioFile (WAV, AIFF, CAF, MP3, AAC, ALAC, FLAC).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "media.hpp"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>

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
    explicit ExtWavWriter(ExtAudioFileRef f) : file_(f) {}
    ~ExtWavWriter() override {
        std::string ignored;
        close(ignored);
    }

    bool write(const float *left, const float *right, int64_t frames, std::string &err) override {
        while (frames > 0) {
            const auto n = static_cast<UInt32>(std::min<int64_t>(frames, 65536));
            struct {
                UInt32 count;
                AudioBuffer bufs[2];
            } abl{2, {{1, n * 4, const_cast<float *>(left)}, {1, n * 4, const_cast<float *>(right)}}};
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
    ExtAudioFileRef file_;
};

} // namespace

WavWriter *openWavWriter(const std::string &path, double sampleRate, int32_t bits, std::string &err) {
    if (bits != 16 && bits != 24 && bits != 32) {
        err = "bits must be 16, 24 or 32";
        return nullptr;
    }
    AudioStreamBasicDescription fmt{};
    fmt.mSampleRate = sampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mChannelsPerFrame = 2;
    fmt.mFramesPerPacket = 1;
    fmt.mBitsPerChannel = static_cast<UInt32>(bits);
    fmt.mBytesPerFrame = 2 * static_cast<UInt32>(bits) / 8;
    fmt.mBytesPerPacket = fmt.mBytesPerFrame;
    fmt.mFormatFlags = kAudioFormatFlagIsPacked |
                       (bits == 32 ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger);

    CFURLRef url = makeURL(path);
    if (!url) {
        err = "invalid path";
        return nullptr;
    }
    ExtAudioFileRef file = nullptr;
    OSStatus s = ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fmt, nullptr, kAudioFileFlags_EraseFile, &file);
    CFRelease(url);
    if (s != noErr) {
        err = statusErr("create file", s);
        return nullptr;
    }
    AudioStreamBasicDescription client = planarFloat(sampleRate, 2);
    s = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    if (s != noErr) {
        ExtAudioFileDispose(file);
        err = statusErr("set client format", s);
        return nullptr;
    }
    return new ExtWavWriter(file);
}

} // namespace dalnok
