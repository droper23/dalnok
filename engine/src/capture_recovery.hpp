// Recovery conversion preserves the source spool and never replaces a file.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <string>
namespace dalnok {
bool recoverCapture(const std::string &source, const std::string &destination,
                    uint64_t &frames, uint32_t &trailingBytes, std::string &error);
}
