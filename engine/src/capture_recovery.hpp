// Recovery conversion preserves the source spool and never replaces a file.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <string>
namespace dalnok {
bool recoverCapture(const std::string &source, const std::string &destination,
                    uint64_t &frames, uint32_t &trailingBytes, std::string &error,
                    int channel = -1, // channel >= 0: a mono WAV of that spool channel
                    // emptyRate > 0: a spool that is missing or shorter than its header (the take was killed after its
                    // journal was written but before capture began) recovers as an empty WAV at that rate and channel count.
                    uint32_t emptyRate = 0, uint32_t emptyChannels = 0);
}
