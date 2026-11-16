// SPDX-License-Identifier: GPL-3.0-or-later
#include "media.hpp"

#include <algorithm>
#include <cmath>

namespace dalnok {

namespace {
constexpr int64_t kBaseBlock = 64;
constexpr int64_t kLevelFactor = 4;
constexpr int kMaxLevels = 8; // 64 .. 64*4^7 (~1M frames)
} // namespace

Media::Media(std::vector<std::vector<float>> channels, double sampleRate)
    : channels_(std::move(channels)), sampleRate_(sampleRate) {
    frames_ = channels_.empty() ? 0 : static_cast<int64_t>(channels_[0].size());
    buildPeaks();
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

} // namespace dalnok
