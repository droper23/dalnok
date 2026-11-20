// SPDX-License-Identifier: GPL-3.0-or-later
#include "media.hpp"
#include "stream_cache.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace dalnok {

namespace {
constexpr int64_t kBaseBlock = 64;
constexpr int64_t kLevelFactor = 4;
constexpr int kMaxLevels = 8; // 64 .. 64*4^7 (~1M frames)
constexpr int64_t kStreamPeakBase = 1024; // streamed media keep peaks from 1,024-frame blocks up (~5 MB per stereo hour)
} // namespace

Media::Media(std::vector<std::vector<float>> channels, double sampleRate)
    : channels_(std::move(channels)), sampleRate_(sampleRate) {
    frames_ = channels_.empty() ? 0 : static_cast<int64_t>(channels_[0].size());
    channels_count_ = static_cast<int32_t>(channels_.size());
    buildPeaks();
}

Media::Media(std::shared_ptr<StreamSource> source, double sampleRate, Level base)
    : source_(std::move(source)), sampleRate_(sampleRate) {
    frames_ = source_->frames();
    channels_count_ = source_->channels();
    levels_.push_back(std::move(base));
    buildCoarserLevels();
}

Media::~Media() = default;


void Media::read(int64_t start, int64_t n, float *l, float *r) const {
    if (n <= 0) return;
    if (streamed()) { source_->readFile(start, n, l, r); return; }
    for (int64_t i = 0; i < n; ++i) {
        const int64_t at = start + i;
        const bool inside = at >= 0 && at < frames_;
        l[i] = inside ? channels_[0][static_cast<size_t>(at)] : 0.0f;
        if (r) r[i] = inside ? channels_[channels_.size() > 1 ? 1 : 0][static_cast<size_t>(at)] : 0.0f;
    }
}

int Media::readResident(int64_t start, int n, float *l, float *r) const DALNOK_NONBLOCKING {
    return source_ ? source_->readResident(start, n, l, r) : 0;
}

void Media::buildCoarserLevels() {
    while (static_cast<int>(levels_.size()) < kMaxLevels && levels_.back().blockSize < frames_) {
        const Level &prev = levels_.back();
        Level lvl{prev.blockSize * kLevelFactor, {}, {}};
        for (size_t c = 0; c < prev.mins.size(); ++c) {
            const auto &pm = prev.mins[c], &px = prev.maxs[c];
            const size_t n = (pm.size() + static_cast<size_t>(kLevelFactor) - 1) / static_cast<size_t>(kLevelFactor);
            std::vector<float> mins(n), maxs(n);
            for (size_t b = 0; b < n; ++b) {
                const size_t a = b * static_cast<size_t>(kLevelFactor), e = std::min(pm.size(), a + static_cast<size_t>(kLevelFactor));
                float lo = pm[a], hi = px[a];
                for (size_t i = a + 1; i < e; ++i) { lo = std::min(lo, pm[i]); hi = std::max(hi, px[i]); }
                mins[b] = lo;
                maxs[b] = hi;
            }
            lvl.mins.push_back(std::move(mins));
            lvl.maxs.push_back(std::move(maxs));
        }
        levels_.push_back(std::move(lvl));
    }
}

void Media::buildPeaks() {
    int64_t block = kBaseBlock;
    for (int l = 0; l < kMaxLevels && block / kLevelFactor < frames_; ++l, block *= kLevelFactor) {
        Level lvl{block, {}, {}};
        const auto nBlocks = (frames_ + block - 1) / block;
        for (size_t c = 0; c < channels_.size(); ++c) {
            std::vector<float> mins(static_cast<size_t>(nBlocks)), maxs(static_cast<size_t>(nBlocks));
            for (int64_t b = 0; b < nBlocks; ++b) {
                float lo = 0, hi = 0;
                if (l == 0) {
                    const float *s = channels_[c].data();
                    const int64_t a = b * block, e = std::min(frames_, a + block);
                    lo = hi = s[a];
                    for (int64_t i = a + 1; i < e; ++i) {
                        lo = std::min(lo, s[i]);
                        hi = std::max(hi, s[i]);
                    }
                } else {
                    const Level &prev = levels_.back();
                    const auto &pm = prev.mins[c], &px = prev.maxs[c];
                    const auto a = static_cast<size_t>(b * kLevelFactor);
                    const auto e = std::min(pm.size(), a + static_cast<size_t>(kLevelFactor));
                    lo = pm[a];
                    hi = px[a];
                    for (size_t i = a + 1; i < e; ++i) {
                        lo = std::min(lo, pm[i]);
                        hi = std::max(hi, px[i]);
                    }
                }
                mins[static_cast<size_t>(b)] = lo;
                maxs[static_cast<size_t>(b)] = hi;
            }
            lvl.mins.push_back(std::move(mins));
            lvl.maxs.push_back(std::move(maxs));
        }
        levels_.push_back(std::move(lvl));
    }
}

int64_t Media::peaks(int32_t channel, int64_t startFrame, double fpc, float *minOut, float *maxOut,
                     int64_t count) const {
    if (channel < 0 || channel >= channelCount() || fpc <= 0 || count <= 0) return 0;
    const auto c = static_cast<size_t>(channel);
    const Level *lvl = nullptr;
    for (const auto &l : levels_)
        if (static_cast<double>(l.blockSize) <= fpc) lvl = &l;

    for (int64_t col = 0; col < count; ++col) {
        auto a = startFrame + static_cast<int64_t>(std::floor(static_cast<double>(col) * fpc));
        auto e = startFrame + static_cast<int64_t>(std::floor(static_cast<double>(col + 1) * fpc));
        e = std::max(e, a + 1);
        a = std::max<int64_t>(a, 0);
        e = std::min(e, frames_);
        float lo = 0, hi = 0;
        if (a < e) {
            if (lvl) {
                const auto &mins = lvl->mins[c], &maxs = lvl->maxs[c];
                const auto ba = static_cast<size_t>(a / lvl->blockSize);
                const auto be = std::min(mins.size(), static_cast<size_t>((e + lvl->blockSize - 1) / lvl->blockSize));
                lo = mins[ba];
                hi = maxs[ba];
                for (size_t i = ba + 1; i < be; ++i) {
                    lo = std::min(lo, mins[i]);
                    hi = std::max(hi, maxs[i]);
                }
            } else if (streamed()) { // closer than the stored peaks: read the samples (UI thread; blocks on disk)
                std::vector<float> l(static_cast<size_t>(e - a)), r(l.size());
                source_->readFile(a, e - a, l.data(), r.data());
                const auto &v = c == 0 ? l : r;
                lo = hi = v[0];
                for (float x : v) { lo = std::min(lo, x); hi = std::max(hi, x); }
            } else {
                const float *s = channels_[c].data();
                lo = hi = s[a];
                for (int64_t i = a + 1; i < e; ++i) {
                    lo = std::min(lo, s[i]);
                    hi = std::max(hi, s[i]);
                }
            }
        }
        minOut[col] = lo;
        maxOut[col] = hi;
    }
    return count;
}

// ---- Loading and the stream cache file (A-09) --------------------------------------------------------------------
//
// File layout: a 4,096-byte header, then blocks of kStreamBlockFrames frames (channel 0's block, then channel 1's),
// the last block zero-padded, then the base peak level (per channel: mins, then maxs).

namespace {
struct StreamHeader {
    char magic[8];
    uint32_t version, channels;
    int64_t frames;
    double rate;
    int64_t blockFrames, peakBase, peakBlocks;
};
constexpr char kStreamMagic[8] = {'D', 'L', 'N', 'K', 'S', 'T', 'R', 'M'};
constexpr uint32_t kStreamVersion = 1;
constexpr int64_t kStreamHeaderBytes = 4096;

uint64_t fnv(uint64_t h, const void *data, size_t n) {
    const auto *p = static_cast<const unsigned char *>(data);
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

bool writeAt(int fd, const void *data, size_t bytes, off_t at) {
    size_t done = 0;
    while (done < bytes) {
        const ssize_t n = ::pwrite(fd, static_cast<const char *>(data) + done, bytes - done, at + static_cast<off_t>(done));
        if (n <= 0) return false;
        done += static_cast<size_t>(n);
    }
    return true;
}

bool readAt(int fd, void *data, size_t bytes, off_t at) {
    size_t done = 0;
    while (done < bytes) {
        const ssize_t n = ::pread(fd, static_cast<char *>(data) + done, bytes - done, at + static_cast<off_t>(done));
        if (n <= 0) return false;
        done += static_cast<size_t>(n);
    }
    return true;
}

off_t peakOffset(const StreamHeader &h) {
    const int64_t blocks = (h.frames + h.blockFrames - 1) / h.blockFrames;
    return static_cast<off_t>(kStreamHeaderBytes + blocks * h.blockFrames * static_cast<int64_t>(h.channels) * 4);
}

// Opens an existing, complete cache file; null if there is none or it doesn't match.
std::shared_ptr<const Media> openStreamFile(const std::string &file, double rate) {
    const int fd = ::open(file.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return nullptr;
    StreamHeader h{};
    if (!readAt(fd, &h, sizeof h, 0) || std::memcmp(h.magic, kStreamMagic, 8) != 0 || h.version != kStreamVersion ||
        h.rate != rate || h.blockFrames != kStreamBlockFrames || h.channels < 1 || h.channels > 2 || h.frames <= 0) {
        ::close(fd);
        return nullptr;
    }
    Media::Level base{h.peakBase, {}, {}};
    const off_t at = peakOffset(h);
    for (uint32_t c = 0; c < h.channels; ++c) {
        std::vector<float> mins(static_cast<size_t>(h.peakBlocks)), maxs(mins.size());
        const size_t bytes = mins.size() * sizeof(float);
        if (!readAt(fd, mins.data(), bytes, at + static_cast<off_t>(2 * c * bytes)) ||
            !readAt(fd, maxs.data(), bytes, at + static_cast<off_t>((2 * c + 1) * bytes))) {
            ::close(fd);
            return nullptr;
        }
        base.mins.push_back(std::move(mins));
        base.maxs.push_back(std::move(maxs));
    }
    auto source = std::make_shared<StreamSource>(file, fd, static_cast<int32_t>(h.channels), h.frames, rate);
    return std::make_shared<const Media>(std::move(source), rate, std::move(base));
}
} // namespace

std::shared_ptr<const Media> Media::loadFile(const std::string &path, double sampleRate, std::string &err) {
    StreamCache &cache = StreamCache::shared(); // constructed here, never first on an audio thread
    double nativeRate = 0;
    int64_t nativeFrames = 0;
    int32_t probed = 0;
    std::string probeErr;
    const bool long_ = probeAudioFile(path, nativeRate, nativeFrames, probed, probeErr) && nativeRate > 0 &&
                       static_cast<double>(nativeFrames) / nativeRate > cache.streamAfterSeconds();
    if (!long_) {
        std::vector<std::vector<float>> ch;
        if (!decodeAudioFile(path, sampleRate, ch, err)) return nullptr;
        return std::make_shared<const Media>(std::move(ch), sampleRate);
    }
    // The cache file is named after the source file, its size and modification time, and the decode rate.
    struct stat st{};
    if (::stat(path.c_str(), &st) != 0) { err = "cannot read " + path; return nullptr; }
    uint64_t key = 14695981039346656037ull;
    key = fnv(key, path.data(), path.size());
    key = fnv(key, &st.st_size, sizeof st.st_size);
    key = fnv(key, &st.st_mtimespec, sizeof st.st_mtimespec);
    key = fnv(key, &sampleRate, sizeof sampleRate);
    key = fnv(key, &kStreamVersion, sizeof kStreamVersion);
    const std::string dir = cache.directory();
    ::mkdir(dir.c_str(), 0700);
    char name[32];
    std::snprintf(name, sizeof name, "%016llx", static_cast<unsigned long long>(key));
    const std::string file = dir + "/" + name + ".dlnkstream";
    if (auto existing = openStreamFile(file, sampleRate)) return existing;

    // Decode block by block into a temporary file, building the base peak level on the way, then publish it.
    const std::string tmp = file + ".part." + std::to_string(::getpid());
    const int fd = ::open(tmp.c_str(), O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) { err = "cannot create the stream cache in " + dir; return nullptr; }
    int32_t channels = 0;
    int64_t frames = 0, block = 0;
    std::vector<float> buf[2];
    std::vector<float> mins[2], maxs[2];
    float lo[2] = {0, 0}, hi[2] = {0, 0};
    int64_t inPeak = 0;
    bool ioOk = true;
    const auto flushBlock = [&](int32_t ch) {
        for (int32_t c = 0; c < ch; ++c) {
            buf[c].resize(kStreamBlockFrames, 0.0f);
            const off_t at = static_cast<off_t>(kStreamHeaderBytes + (block * ch + c) * kStreamBlockFrames * 4);
            ioOk = writeAt(fd, buf[c].data(), kStreamBlockFrames * sizeof(float), at) && ioOk;
            buf[c].clear();
        }
        ++block;
    };
    const bool decoded = decodeAudioFileChunked(path, sampleRate, [&](const float *const *ch, int32_t n, int64_t count) {
        channels = n;
        for (int64_t i = 0; i < count; ++i) {
            for (int32_t c = 0; c < n; ++c) {
                const float x = ch[c][i];
                buf[c].push_back(x);
                if (inPeak == 0) lo[c] = hi[c] = x;
                else { lo[c] = std::min(lo[c], x); hi[c] = std::max(hi[c], x); }
            }
            if (++inPeak == kStreamPeakBase) {
                for (int32_t c = 0; c < n; ++c) { mins[c].push_back(lo[c]); maxs[c].push_back(hi[c]); }
                inPeak = 0;
            }
            if (static_cast<int64_t>(buf[0].size()) == kStreamBlockFrames) flushBlock(n);
        }
        frames += count;
        return ioOk;
    }, channels, err);
    if (decoded && !buf[0].empty()) flushBlock(channels);
    if (decoded && inPeak > 0)
        for (int32_t c = 0; c < channels; ++c) { mins[c].push_back(lo[c]); maxs[c].push_back(hi[c]); }
    StreamHeader h{};
    std::memcpy(h.magic, kStreamMagic, 8);
    h.version = kStreamVersion;
    h.channels = static_cast<uint32_t>(channels);
    h.frames = frames;
    h.rate = sampleRate;
    h.blockFrames = kStreamBlockFrames;
    h.peakBase = kStreamPeakBase;
    h.peakBlocks = channels > 0 ? static_cast<int64_t>(mins[0].size()) : 0;
    if (decoded && ioOk) {
        const off_t at = peakOffset(h);
        const size_t bytes = static_cast<size_t>(h.peakBlocks) * sizeof(float);
        for (int32_t c = 0; c < channels; ++c) {
            ioOk = writeAt(fd, mins[c].data(), bytes, at + static_cast<off_t>(2 * c * bytes)) && ioOk;
            ioOk = writeAt(fd, maxs[c].data(), bytes, at + static_cast<off_t>((2 * c + 1) * bytes)) && ioOk;
        }
        ioOk = writeAt(fd, &h, sizeof h, 0) && ioOk; // last: an interrupted decode never looks complete
    }
    ::close(fd);
    if (!decoded || !ioOk || frames == 0 || ::rename(tmp.c_str(), file.c_str()) != 0) {
        ::unlink(tmp.c_str());
        if (err.empty()) err = "cannot write the stream cache (disk full?)";
        return nullptr;
    }
    auto media = openStreamFile(file, sampleRate);
    if (!media) err = "cannot open the stream cache";
    return media;
}

} // namespace dalnok
