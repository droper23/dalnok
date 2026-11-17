// Exclusive temporary file for captured interleaved float PCM. The header is
// deliberately small so a valid complete-frame prefix can be recovered later.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "capture_writer.hpp"
#include <bit>
#include <cerrno>
#include <cstdint>
#include <fcntl.h>
#include <string>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>

namespace dalnok {

class CaptureSpool final : public CaptureSink {
public:
    // Creates a new file only. Existing recordings are never truncated.
    static int create(const std::string &path, uint32_t sampleRate, uint32_t channels) {
        if (sampleRate < 8000 || sampleRate > 384000 || channels == 0 || channels > 64) { errno = EINVAL; return -1; }
        const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0) return -1;
        // DLNCAP01 + little-endian rate and channel count; data is float32 LE.
        uint8_t header[16] = {'D','L','N','C','A','P','0','1'};
        for (unsigned i = 0; i < 4; ++i) { header[8 + i] = static_cast<uint8_t>(sampleRate >> (8 * i)); header[12 + i] = static_cast<uint8_t>(channels >> (8 * i)); }
        if (!writeAll(fd, header, sizeof(header)) || ::fsync(fd) != 0) { const int saved = errno; ::close(fd); errno = saved; return -1; }
        return fd;
    }
    struct Inspection {
        uint32_t sampleRate = 0, channels = 0;
        uint64_t completeFrames = 0, trailingBytes = 0;
    };
    // Read-only inspection; a partial final frame is reported, never repaired.
    static bool inspect(const std::string &path, Inspection &result) {
        const int fd = ::open(path.c_str(), O_RDONLY);
        if (fd < 0) return false;
        struct stat info{};
        uint8_t header[16]{};
        const bool validFile = ::fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size >= 16;
        size_t readBytes = 0;
        while (validFile && readBytes < sizeof(header)) {
            const auto n = ::read(fd, header + readBytes, sizeof(header) - readBytes);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            readBytes += static_cast<size_t>(n);
        }
        ::close(fd);
        if (!validFile || readBytes != sizeof(header) || std::memcmp(header, "DLNCAP01", 8) != 0) return false;
        auto number = [&](int at) {
            uint32_t n = 0;
            for (int i = 0; i < 4; ++i) n |= static_cast<uint32_t>(header[at + i]) << (8 * i);
            return n;
        };
        const uint32_t rate = number(8), channels = number(12);
        if (rate < 8000 || rate > 384000 || channels == 0 || channels > 64) return false;
        const uint64_t bytes = static_cast<uint64_t>(info.st_size - 16), frameBytes = channels * sizeof(float);
        result = {rate, channels, bytes / frameBytes, bytes % frameBytes};
        return true;
    }
    CaptureSpool(int fd, uint32_t channels) : fd_(fd), channels_(channels) {}
    ~CaptureSpool() override { if (fd_ >= 0) ::close(fd_); }
    CaptureSpool(const CaptureSpool &) = delete;
    CaptureSpool &operator=(const CaptureSpool &) = delete;

    bool write(const float *samples, uint32_t frames) override {
        static_assert(std::endian::native == std::endian::little && sizeof(float) == 4);
        if (fd_ < 0 || failed_) return false;
        const size_t bytes = static_cast<size_t>(frames) * channels_ * sizeof(float);
        if (!writeAll(fd_, samples, bytes)) { failed_ = true; return false; }
        return true;
    }
    bool finish() override {
        if (fd_ < 0) return false;
        const bool flushed = ::fsync(fd_) == 0;
        const bool closed = ::close(fd_) == 0;
        fd_ = -1;
        return flushed && closed;
    }

private:
    static bool writeAll(int fd, const void *data, size_t bytes) {
        const auto *p = static_cast<const uint8_t *>(data);
        while (bytes) {
            const auto n = ::write(fd, p, bytes);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return false;
            p += n; bytes -= static_cast<size_t>(n);
        }
        return true;
    }
    int fd_;
    uint32_t channels_;
    bool failed_ = false;
};

} // namespace dalnok
