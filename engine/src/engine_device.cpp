// Engine: audio devices, capture and the device workgroup (split from engine.cpp, A-06).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.hpp"
#include "engine_internal.hpp"
#include "plugin_remote.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <set>
#include <unordered_map>
#include <utility>

namespace dalnok {
using detail::kTransportFadeSeconds;
using detail::nowNs;
using detail::atomicMax;
using detail::FlushDenormals;
using namespace detail;

namespace {
// Stands in for a duplex device in tests: the caller drives each cycle through pumpInput.
class SimulatedDuplex final : public AudioDuplexDevice {
public:
    SimulatedDuplex(double rate, int64_t latency) : rate_(rate), latency_(latency) {}
    bool start(Callback, void *, std::string &) override { return true; }
    void stop() override {}
    bool captureFailed() const override { return false; }
    bool alive() const override { return true; }
    double hardwareSampleRate() const override { return rate_; }
    int64_t roundTripLatency() const override { return latency_; }
private:
    double rate_;
    int64_t latency_;
};
} // namespace

// ---- Device -------------------------------------------------------------

bool Engine::startDevice(std::string &err) {
    if (device_ || duplex_) return true;
    auto dev = createOutputDevice(outputUid_, sampleRate_, err);
    if (!dev || !dev->start(&Engine::audioCallback, this, err)) return false;
    device_ = std::move(dev);
    updateWorkgroup();
    return true;
}

void Engine::updateWorkgroup() {
    const uint32_t port = duplex_ ? duplex_->workgroupPort() : device_ ? device_->workgroupPort() : 0;
    pluginHost_.setWorkgroupPort(port);
}

bool Engine::setOutputDevice(const std::string &uid, std::string &err) {
    if (duplex_) { err = "stop capture before changing the output device"; return false; }
    if (uid == outputUid_ && device_ && device_->alive()) return true;
    const std::string previous = outputUid_;
    const bool wasRunning = device_ != nullptr;
    stopDevice();
    outputUid_ = uid;
    if (startDevice(err)) return true;
    // Fall back to what was running before (or the default if that is gone).
    outputUid_ = previous;
    std::string ignored;
    if (wasRunning && !startDevice(ignored)) {
        outputUid_.clear();
        startDevice(ignored);
    }
    return false;
}

bool Engine::pump(float *left, float *right, int frames) {
    if (device_ || duplex_ || !left || !right || frames <= 0) return false;
    process(left, right, frames);
    collectGarbage();
    return true;
}

bool Engine::pumpInput(const float *input, float *left, float *right, int frames) {
    // Mono test input appears on every device channel.
    const float *channels[64];
    for (auto &c : channels) c = input;
    return pumpInputChannels(input ? channels : nullptr, input ? 64 : 0, left, right, frames);
}

bool Engine::pumpInputChannels(const float *const *inputs, int count, float *left, float *right, int frames) {
    if (!simulatedInput_ || !duplex_ || !left || !right || frames <= 0 || count < 0 || count > 64) return false;
    duplexCallback(this, left, right, inputs, count, frames);
    collectGarbage();
    return true;
}

bool Engine::startCapture(const std::string &uid, const std::vector<int> &channels, const std::string &path, std::string &err) {
    if (duplex_ || captureWriter_) { err = "capture is already active"; return false; }
    if (channels.empty() || channels.size() > 64) { err = "choose 1 to 64 input channels"; return false; }
    int highest = 0;
    for (int c : channels) {
        if (c < 0 || c > 63) { err = "input channel out of range"; return false; }
        highest = std::max(highest, c);
    }
    const auto count = static_cast<uint32_t>(channels.size());
    const bool simulated = uid == kSimulatedInput;
    if (simulated ? device_ != nullptr : (!device_ || uid.empty() || uid != outputUid_)) {
        err = simulated ? "the simulated input requires the output device to be stopped"
                        : "select the same explicit input and output device before capture";
        return false;
    }
    if (path.empty() || sampleRate_ != std::floor(sampleRate_) || sampleRate_ < 8000 || sampleRate_ > 384000) {
        err = "invalid capture path or sample rate"; return false;
    }
    std::unique_ptr<AudioDuplexDevice> duplex;
    if (simulated) duplex = std::make_unique<SimulatedDuplex>(sampleRate_, simulatedLatency_);
    else duplex = createDuplexDevice(uid, sampleRate_, highest, err);
    if (!duplex) return false;
    const int fd = CaptureSpool::create(path, static_cast<uint32_t>(sampleRate_), count);
    if (fd < 0) { err = "cannot create new capture spool"; return false; }
    try {
        captureSpool_ = std::make_unique<CaptureSpool>(fd, count);
        // About 5.5 seconds at 48 kHz; overflow always reports an error.
        captureWriter_ = std::make_unique<CaptureWriter>(1 << 18, count, *captureSpool_);
        captureScratch_.assign(static_cast<size_t>(kMaxCaptureBlock) * count, 0.0f);
        for (size_t i = 0; i < channels.size(); ++i) captureMap_[i] = channels[i];
        captureChannels_ = static_cast<int>(count);
        captureWriter_->start();
    } catch (...) {
        if (!captureSpool_) ::close(fd);
        captureWriter_.reset(); captureSpool_.reset();
        err = "cannot start capture writer; spool retained"; return false;
    }
    captureInputFailed_.store(false, std::memory_order_relaxed);
    captureMissingFrames_.store(0, std::memory_order_relaxed);
    captureRT_ = captureWriter_.get();
    if (device_) { device_->stop(); device_.reset(); }
    if (!duplex->start(&Engine::duplexCallback, this, err)) {
        captureRT_ = nullptr;
        captureWriter_->stop(); captureWriter_.reset(); captureSpool_.reset();
        std::string restoreError;
        if (!simulated && !startDevice(restoreError)) err += "; output restart failed: " + restoreError;
        return false;
    }
    duplex_ = std::move(duplex);
    simulatedInput_ = simulated;
    updateWorkgroup();
    return true;
}

bool Engine::captureStatus(DalnokCaptureStats &stats) const {
    if (!duplex_ || !captureWriter_) return false;
    stats = {};
    stats.captured_frames = captureWriter_->capturedFrames();
    stats.written_frames = captureWriter_->writtenFrames();
    stats.dropped_frames = captureWriter_->droppedFrames() + captureMissingFrames_.load(std::memory_order_relaxed);
    const double hardwareRate = duplex_->hardwareSampleRate();
    stats.input_error = captureInputFailed_.load(std::memory_order_acquire) || duplex_->captureFailed() || !duplex_->alive() ||
                        hardwareRate <= 0 || std::abs(hardwareRate - sampleRate_) > 0.5;
    stats.overflow = captureWriter_->hasError(CaptureWriter::Error::overflow);
    stats.write_error = captureWriter_->hasError(CaptureWriter::Error::write);
    stats.finalize_error = captureWriter_->hasError(CaptureWriter::Error::finalize);
    return true;
}

bool Engine::stopCapture(DalnokCaptureStats &stats, std::string &err, bool restoreOutput) {
    if (!duplex_ || !captureWriter_) { err = "capture is not active"; return false; }
    duplex_->stop(); // callback no longer accesses captureRT_
    captureRT_ = nullptr;
    captureChannels_ = 0;
    captureWriter_->stop();
    captureStatus(stats);
    duplex_.reset(); captureWriter_.reset(); captureSpool_.reset();
    updateWorkgroup();
    const bool valid = !stats.input_error && !stats.overflow && !stats.write_error && !stats.finalize_error &&
                       stats.captured_frames > 0 && stats.captured_frames == stats.written_frames;
    std::string outputError;
    const bool restore = restoreOutput && !simulatedInput_;
    simulatedInput_ = false;
    const bool outputOK = !restore || startDevice(outputError);
    if (!valid) err = "capture failed; the original spool was retained";
    if (!outputOK) { if (!err.empty()) err += "; "; err += "output restart failed: " + outputError; }
    return valid && outputOK;
}

bool Engine::readTrackMeter(DalnokTrackId id, float &l, float &r) {
    const TrackState *t = model_.track(id);
    if (!t) return false;
    l = t->runtime->peakL.exchange(0.0f, std::memory_order_relaxed);
    r = t->runtime->peakR.exchange(0.0f, std::memory_order_relaxed);
    return true;
}

void Engine::readMasterMeter(float &l, float &r) {
    l = masterPeakL_.exchange(0.0f, std::memory_order_relaxed);
    r = masterPeakR_.exchange(0.0f, std::memory_order_relaxed);
}

void Engine::stopDevice() {
    if (duplex_) { DalnokCaptureStats stats{}; std::string ignored; stopCapture(stats, ignored, false); }
    if (!device_) return;
    device_->stop(); // synchronous: the audio thread is no longer inside process()
    device_.reset();
    updateWorkgroup();
}

void Engine::collectGarbage() {
    RenderState *s = nullptr;
    while (retired_.pop(s)) delete s;
    // Plug-ins edited in their editors, and isolated plug-ins whose host failed: stamp only their tracks (A-05).
    std::vector<DalnokTrackId> edited;
    const auto changed = pluginHost_.poll();
    const bool any = !changed.empty();
    for (int32_t id : changed)
        for (const auto &t : model_.tracks)
            for (const auto &slot : t.plugins) if (slot.id == id) edited.push_back(t.id);
    if (any) { ++revision_; stampTracks(edited); }
    if (recording_) drainRecordedMidi();
}

} // namespace dalnok
