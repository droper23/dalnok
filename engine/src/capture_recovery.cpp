// Convert a stopped capture spool to a float WAV without modifying the source.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "capture_recovery.hpp"
#include "capture_spool.hpp"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace dalnok {
namespace {
bool writeAll(int fd, const void *data, size_t length) {
    const auto *p = static_cast<const uint8_t *>(data);
    while (length) {
        const auto n = ::write(fd, p, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n; length -= static_cast<size_t>(n);
    }
    return true;
}
void put16(uint8_t *p, uint16_t n) { p[0] = static_cast<uint8_t>(n); p[1] = static_cast<uint8_t>(n >> 8); }
void put32(uint8_t *p, uint32_t n) { for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(n >> (i * 8)); }
}

bool recoverCapture(const std::string &source, const std::string &destination,
                    uint64_t &frames, uint32_t &trailingBytes, std::string &error) {
    frames = 0; trailingBytes = 0;
    const int input = ::open(source.c_str(), O_RDONLY);
    if (input < 0) { error = "cannot open capture spool"; return false; }
    CaptureSpool::Inspection info;
    if (!CaptureSpool::inspectFd(input, info) || info.channels > 2) {
        ::close(input); error = "invalid capture spool or unsupported channel count"; return false;
    }
    const uint64_t bytes = info.completeFrames * info.channels * sizeof(float);
    if (bytes > std::numeric_limits<uint32_t>::max() - 36) {
        ::close(input); error = "capture is too large for WAV"; return false;
    }
    std::string pattern = destination + ".tmp-XXXXXX";
    std::vector<char> temp(pattern.begin(), pattern.end()); temp.push_back('\0');
    const int output = ::mkstemp(temp.data());
    if (output < 0) { ::close(input); error = "cannot create recovery temporary file"; return false; }
    ::fchmod(output, 0644); // an ordinary audio file, like any other in the project folder
    uint8_t header[44]{};
    std::memcpy(header, "RIFF", 4); put32(header + 4, static_cast<uint32_t>(bytes) + 36);
    std::memcpy(header + 8, "WAVEfmt ", 8); put32(header + 16, 16);
    put16(header + 20, 3); put16(header + 22, static_cast<uint16_t>(info.channels));
    put32(header + 24, info.sampleRate); put32(header + 28, info.sampleRate * info.channels * 4);
    put16(header + 32, static_cast<uint16_t>(info.channels * 4)); put16(header + 34, 32);
    std::memcpy(header + 36, "data", 4); put32(header + 40, static_cast<uint32_t>(bytes));
    bool ok = writeAll(output, header, sizeof(header));
    uint8_t buffer[65536];
    uint64_t copied = 0;
    while (ok && copied < bytes) {
        const auto want = static_cast<size_t>(std::min<uint64_t>(sizeof(buffer), bytes - copied));
        const auto n = ::pread(input, buffer, want, static_cast<off_t>(16 + copied));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = false; break; }
        ok = writeAll(output, buffer, static_cast<size_t>(n));
        copied += static_cast<uint64_t>(n);
    }
    if (ok) ok = ::fsync(output) == 0;
    if (::close(output) != 0) ok = false;
    ::close(input);
    // A hard link publishes atomically and fails if the destination exists.
    if (ok) ok = ::link(temp.data(), destination.c_str()) == 0;
    ::unlink(temp.data());
    if (!ok) { error = "capture recovery failed or output already exists"; return false; }
    frames = info.completeFrames; trailingBytes = static_cast<uint32_t>(info.trailingBytes);
    return true;
}
}
