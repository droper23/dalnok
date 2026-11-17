// SPDX-License-Identifier: GPL-3.0-or-later
#include "capture_writer.hpp"
#include <cassert>
#include <chrono>
#include <thread>
#include <vector>

struct Sink : dalnok::CaptureSink {
    std::vector<float> samples;
    bool failWrite = false, failFinish = false, finished = false;
    bool write(const float *p, uint32_t frames) override {
        if (failWrite) return false;
        samples.insert(samples.end(), p, p + frames * 2);
        return true;
    }
    bool finish() override { finished = true; return !failFinish; }
};

int main() {
    using Writer = dalnok::CaptureWriter;
    {
        Sink sink;
        Writer w(1024, 2, sink);
        w.start();
        float input[] = {0.25f, -0.5f, 0.75f, -1.0f};
        assert(w.push(input, 2));
        w.stop();
        assert(w.ok() && w.capturedFrames() == 2 && w.writtenFrames() == 2);
        assert(sink.finished && sink.samples == std::vector<float>(input, input + 4));
        assert(!w.push(input, 2));
    }
    // Repeated immediate stops exercise the empty-check versus final write race.
    for (int i = 0; i < 500; ++i) {
        Sink sink;
        Writer w(2, 2, sink);
        w.start();
        float input[] = {0.25f, -0.5f};
        assert(w.push(input, 1));
        w.stop();
        assert(w.ok() && w.capturedFrames() == 1 && w.writtenFrames() == 1);
        assert(sink.samples == std::vector<float>(input, input + 2));
    }
    {
        Sink sink;
        Writer w(2, 2, sink);
        float input[] = {0, 1, 2, 3, 4, 5};
        assert(!w.push(input, 3));
        assert(w.hasError(Writer::Error::overflow) && w.droppedFrames() == 3);
        assert(!w.push(input, 1));
        assert(w.droppedFrames() == 4);
        w.start(); w.stop();
        assert(sink.finished && w.writtenFrames() == 0);
    }
    {
        Sink sink; sink.failWrite = true;
        Writer w(1024, 2, sink);
        w.start();
        float input[] = {0, 1};
        assert(w.push(input, 1));
        w.stop();
        assert(w.hasError(Writer::Error::write) && w.capturedFrames() == 1 && w.writtenFrames() == 0 && sink.finished);
    }
    {
        Sink sink; sink.failWrite = true; sink.failFinish = true;
        Writer w(2, 2, sink);
        float input[] = {0, 1, 2, 3, 4, 5};
        assert(w.push(input, 2));
        assert(!w.push(input + 4, 1));
        w.start(); w.stop();
        assert(w.hasError(Writer::Error::overflow));
        assert(w.hasError(Writer::Error::write));
        assert(w.hasError(Writer::Error::finalize));
        assert(w.capturedFrames() == 2 && w.writtenFrames() == 0 && w.droppedFrames() == 1);
    }
    {
        Sink sink; sink.failFinish = true;
        Writer w(1024, 2, sink);
        w.start(); w.stop();
        assert(w.hasError(Writer::Error::finalize));
    }
}
