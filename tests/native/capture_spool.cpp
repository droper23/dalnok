// SPDX-License-Identifier: GPL-3.0-or-later
#include "capture_spool.hpp"
#include <cassert>
#include <cerrno>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>

int main() {
    char dir[] = "/tmp/dalnok-spool-XXXXXX";
    assert(mkdtemp(dir));
    // Simulate a process dying after writing audio, before finalization.
    const std::string interrupted = std::string(dir) + "/interrupted.raw";
    int ready[2]; assert(pipe(ready) == 0);
    const pid_t child = fork(); assert(child >= 0);
    if (child == 0) {
        ::close(ready[0]);
        const int childFd = dalnok::CaptureSpool::create(interrupted, 48000, 1);
        if (childFd < 0) _exit(2);
        dalnok::CaptureSpool spool(childFd, 1);
        const float frames[] = {0.125f, -0.25f, 0.5f};
        if (!spool.write(frames, 3) || ::write(ready[1], "x", 1) != 1) _exit(3);
        for (;;) pause();
    }
    ::close(ready[1]);
    char signalByte = 0; assert(::read(ready[0], &signalByte, 1) == 1 && signalByte == 'x');
    ::close(ready[0]);
    assert(kill(child, SIGKILL) == 0);
    int status = 0; assert(waitpid(child, &status, 0) == child && WIFSIGNALED(status));
    dalnok::CaptureSpool::Inspection crashed;
    assert(dalnok::CaptureSpool::inspect(interrupted, crashed));
    assert(crashed.sampleRate == 48000 && crashed.channels == 1 && crashed.completeFrames == 3 && crashed.trailingBytes == 0);
    assert(unlink(interrupted.c_str()) == 0);
    // Ten seconds of deterministic stereo capture through the worker and spool.
    const std::string longPath = std::string(dir) + "/long.raw";
    const int longFd = dalnok::CaptureSpool::create(longPath, 48000, 2); assert(longFd >= 0);
    {
        dalnok::CaptureSpool spool(longFd, 2);
        dalnok::CaptureWriter writer(1 << 19, 2, spool);
        writer.start();
        float block[512 * 2];
        for (unsigned i = 0; i < 512; ++i) { block[i * 2] = 0.25f; block[i * 2 + 1] = -0.5f; }
        constexpr uint32_t blocks = 937; // 479744 frames, just under ten seconds
        for (uint32_t i = 0; i < blocks; ++i) assert(writer.push(block, 512));
        writer.stop();
        assert(writer.ok() && writer.capturedFrames() == uint64_t(blocks) * 512 && writer.writtenFrames() == writer.capturedFrames());
        dalnok::CaptureSpool::Inspection longInfo;
        assert(dalnok::CaptureSpool::inspect(longPath, longInfo));
        assert(longInfo.completeFrames == writer.capturedFrames() && longInfo.trailingBytes == 0);
    }
    {
        std::ifstream samples(longPath, std::ios::binary);
        samples.seekg(16 + 200000 * 2 * sizeof(float));
        float frame[2]{}; samples.read(reinterpret_cast<char *>(frame), sizeof(frame));
        assert(samples && frame[0] == 0.25f && frame[1] == -0.5f);
    }
    assert(unlink(longPath.c_str()) == 0);
    const std::string path = std::string(dir) + "/take.raw";
    int fd = dalnok::CaptureSpool::create(path, 48000, 2);
    assert(fd >= 0);
    assert(dalnok::CaptureSpool::create(path, 48000, 2) == -1 && errno == EEXIST);
    float input[] = {0.25f, -0.5f, 0.75f, -1.0f};
    {
        dalnok::CaptureSpool spool(fd, 2);
        dalnok::CaptureWriter writer(1024, 2, spool);
        writer.start();
        assert(writer.push(input, 2));
        writer.stop();
        assert(writer.ok() && writer.capturedFrames() == 2 && writer.writtenFrames() == 2);
    }
    std::ifstream file(path, std::ios::binary);
    const std::string data((std::istreambuf_iterator<char>(file)), {});
    assert(data.size() == 16 + sizeof(input));
    assert(data.substr(0, 8) == "DLNCAP01");
    assert(static_cast<unsigned char>(data[8]) == 0x80 && static_cast<unsigned char>(data[9]) == 0xbb);
    assert(data[12] == 2 && std::memcmp(data.data() + 16, input, sizeof(input)) == 0);
    {
        const int readOnly = ::open(path.c_str(), O_RDONLY);
        assert(readOnly >= 0);
        dalnok::CaptureSpool failing(readOnly, 2);
        assert(!failing.write(input, 2));
        assert(!failing.write(input, 2));
        (void)failing.finish();
    }
    dalnok::CaptureSpool::Inspection inspected;
    assert(dalnok::CaptureSpool::inspect(path, inspected));
    assert(inspected.sampleRate == 48000 && inspected.channels == 2 && inspected.completeFrames == 2 && inspected.trailingBytes == 0);
    { std::ofstream append(path, std::ios::binary | std::ios::app); append.put('x'); }
    assert(dalnok::CaptureSpool::inspect(path, inspected) && inspected.completeFrames == 2 && inspected.trailingBytes == 1);
    const auto badPath = std::string(dir) + "/bad";
    assert(dalnok::CaptureSpool::create(badPath, 0, 2) == -1 && errno == EINVAL);
    { std::ofstream bad(badPath); bad << "invalid"; }
    assert(!dalnok::CaptureSpool::inspect(badPath, inspected));
    assert(unlink(badPath.c_str()) == 0);
    assert(unlink(path.c_str()) == 0);
    assert(rmdir(dir) == 0);
}
