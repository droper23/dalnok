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
    if (rec_.captureWriter) { err = "stop recording before changing the output device"; return false; }
    if (uid == outputUid_ && ((device_ && device_->alive()) || (duplex_ && duplex_->alive()))) return true;
    const std::string previous = outputUid_;
    const bool wasRunning = device_ != nullptr || duplex_ != nullptr;
    if (duplex_) closeDuplex();
    stopDevice();
    outputUid_ = uid;
    if (startDevice(err)) { syncInput(); return true; }
    // Fall back to what was running before (or the default if that is gone).
    outputUid_ = previous;
    std::string ignored;
    if (wasRunning && !startDevice(ignored)) {
        outputUid_.clear();
        startDevice(ignored);
    }
    syncInput();
    return false;
}

// ---- Input (monitoring and recording) --------------------------------------

bool Engine::setInputDevice(const std::string &uid, std::string &err) {
    if (rec_.captureWriter && uid != inputUid_) { err = "stop recording before changing the input device"; return false; }
    inputUid_ = uid;
    syncInput();
    if (!inputError_.empty() && monitorWanted()) { err = inputError_; return false; }
    return true;
}

bool Engine::setInputMonitor(DalnokTrackId id, bool on, std::string &err) {
    // Structural: the render state carries the flag (the audio thread reads it from the snapshot).
    const bool ok = edit(on ? "Input Monitoring On" : "Input Monitoring Off", true, [&](Model &m) {
        TrackState *t = m.track(id);
        if (!t) return fail(err, "no such track");
        if (t->kind != kTrackAudio) return fail(err, "only audio tracks monitor an audio input");
        t->inputMonitor = on;
        for (DalnokTrackId o : groupLinked(id, &TrackGroup::monitor))
            if (TrackState *g = m.track(o); g && g->kind == kTrackAudio) g->inputMonitor = on;
        return true;
    });
    if (ok) syncInput();
    return ok;
}

bool Engine::monitorWanted() const {
    const bool armed = rec_.monitoring.load(std::memory_order_relaxed);
    for (const auto &t : model_.tracks)
        if (t.kind == kTrackAudio && (t.inputMonitor || (armed && t.armed))) return true;
    return false;
}

void Engine::syncInput() {
    // Recording or a latency measurement owns the duplex device; nothing real runs before startDevice.
    if (rec_.captureWriter || probeOwnsInput_) return;
    if (inputUid_ == kSimulatedInput || simulatedInput_) {
        // Tests: the simulated input stands in for the device (output stopped; cycles come from pumpInput).
        const bool wantSim = inputUid_ == kSimulatedInput && monitorWanted();
        if (wantSim && !duplex_ && !device_) {
            duplex_ = std::make_unique<SimulatedDuplex>(sampleRate_, simulatedLatency_);
            duplexInputUid_ = kSimulatedInput;
            simulatedInput_ = true;
        } else if (!wantSim && duplex_ && simulatedInput_) {
            duplex_.reset();
            duplexInputUid_.clear();
            simulatedInput_ = false;
        }
        if (inputUid_ == kSimulatedInput || simulatedInput_) return;
    }
    const bool want = monitorWanted() && !inputUid_.empty() && (device_ || duplex_);
    if (!want) {
        if (duplex_) closeDuplex();
        return;
    }
    if (duplex_ && duplexInputUid_ == inputUid_ && duplex_->alive()) return;
    if (duplex_) closeDuplex();
    std::string err;
    if (!openDuplex(inputUid_, 0, err)) inputError_ = err;
    else inputError_.clear();
}

bool Engine::openDuplex(const std::string &uid, int highestChannel, std::string &err) {
    auto duplex = createDuplexDevice(uid, outputUid_, sampleRate_, highestChannel, err);
    if (!duplex) return false;
    if (device_) { device_->stop(); device_.reset(); }
    if (!duplex->start(&Engine::duplexCallback, this, err)) {
        std::string restoreError;
        if (!startDevice(restoreError)) err += "; output restart failed: " + restoreError;
        return false;
    }
    duplex_ = std::move(duplex);
    duplexInputUid_ = uid;
    updateWorkgroup();
    return true;
}

void Engine::closeDuplex() {
    if (!duplex_) return;
    duplex_->stop(); // synchronous: the callback no longer runs
    duplex_.reset();
    duplexInputUid_.clear();
    rtInputs_ = nullptr;
    rtInputCount_ = 0;
    std::string ignored;
    if (!simulatedInput_) startDevice(ignored);
    updateWorkgroup();
}

bool Engine::startLatencyProbe(const std::string &uid, int channel, std::string &err) {
    if (rec_.captureWriter || rec_.active) { err = "stop recording before measuring latency"; return false; }
    if (probeOwnsInput_) { err = "already measuring"; return false; }
    if (channel < 0 || channel > 63) { err = "input channel out of range"; return false; }
    const bool simulated = uid == kSimulatedInput;
    if (!simulated) {
        int inputs = 0;
        for (const auto &d : listInputDevices()) if (d.uid == uid) inputs = d.inputChannels;
        if (channel >= inputs) { err = inputs ? "the input device does not have that input" : "the input device is not available"; return false; }
        if (!device_ && !duplex_) { err = "start the output device first"; return false; }
    } else if (device_ || (duplex_ && !simulatedInput_)) { err = "the simulated input requires the output device to be stopped"; return false; }
    probeBuf_.assign(static_cast<size_t>(sampleRate_ * 2.5), 0.0f);
    probePeriod_ = static_cast<int>(sampleRate_ / 4);
    probeFirst_ = static_cast<int>(sampleRate_ / 20);
    probeChannel_ = channel;
    probeFrame_ = 0;
    // A short tone burst carries far more energy than one sample, so speakers and microphones pick it up too.
    probeBurst_.assign(static_cast<size_t>(sampleRate_ / 500), 0.0f);
    for (size_t i = 0; i < probeBurst_.size(); ++i) {
        const double t = static_cast<double>(i), n = static_cast<double>(probeBurst_.size());
        probeBurst_[i] = static_cast<float>(0.5 * std::sin(2 * M_PI * 2000.0 * t / sampleRate_) * (0.5 - 0.5 * std::cos(2 * M_PI * t / n)));
    }
    probeDone_.store(false, std::memory_order_relaxed);
    probeFailed_.store(false, std::memory_order_relaxed);
    probeOwnsInput_ = true;
    if (simulated) {
        if (!duplex_) { duplex_ = std::make_unique<SimulatedDuplex>(sampleRate_, simulatedLatency_); duplexInputUid_ = kSimulatedInput; simulatedInput_ = true; }
    } else if (!duplex_ || duplexInputUid_ != uid) {
        if (duplex_) closeDuplex();
        if (!openDuplex(uid, channel, err)) { probeOwnsInput_ = false; syncInput(); return false; }
    }
    probeActive_.store(true, std::memory_order_release); // the callback starts at frame 0 from here
    return true;
}

bool Engine::pollLatencyProbe(LatencyResult &r) {
    if (!probeOwnsInput_) { r = {}; r.error = "not measuring"; return true; }
    if (!probeDone_.load(std::memory_order_acquire)) {
        if (duplex_ && !duplex_->alive()) probeFailed_.store(true);
        if (!probeFailed_.load() || !duplex_) return false;
    }
    probeActive_.store(false, std::memory_order_release);
    if (!simulatedInput_) waitForAudioCycles();
    r = {};
    r.reported = duplex_ ? duplex_->roundTripLatency() : 0;
    if (probeFailed_.load()) r.error = "the input stopped during the measurement";
    else {
        // Each burst: the lag of the strongest cross-correlation with the burst within the following period, if it
        // stands well clear of the correlation elsewhere in that period.
        std::vector<int64_t> delays;
        const auto size = static_cast<int64_t>(probeBuf_.size()), len = static_cast<int64_t>(probeBurst_.size());
        for (float v : probeBuf_) r.level = std::max(r.level, std::fabs(v));
        std::vector<double> corr(static_cast<size_t>(probePeriod_));
        for (int64_t c = probeFirst_; c + probePeriod_ + len <= size; c += probePeriod_) {
            int64_t best = 0; double peak = 0;
            for (int64_t lag = 0; lag < probePeriod_; ++lag) {
                double acc = 0;
                for (int64_t j = 0; j < len; ++j) acc += static_cast<double>(probeBuf_[static_cast<size_t>(c + lag + j)]) * probeBurst_[static_cast<size_t>(j)];
                corr[static_cast<size_t>(lag)] = acc;
                if (std::fabs(acc) > peak) { peak = std::fabs(acc); best = lag; }
            }
            double noise = 0; int64_t n = 0;
            for (int64_t lag = 0; lag < probePeriod_; ++lag)
                if (lag < best - 2 * len || lag > best + 2 * len) { noise += corr[static_cast<size_t>(lag)] * corr[static_cast<size_t>(lag)]; ++n; }
            const double rms = n ? std::sqrt(noise / static_cast<double>(n)) : 0;
            if (peak > 1e-6 && peak > 8 * rms) delays.push_back(best);
        }
        std::sort(delays.begin(), delays.end());
        r.clicks = static_cast<int32_t>(delays.size());
        if (delays.size() >= 3) {
            r.measured = delays[delays.size() / 2];
            r.spread = static_cast<int32_t>(delays.back() - delays.front());
        }
        if (delays.size() < 3) r.error = "the clicks were not heard on that input (connect an output to it, or choose a loopback input)";
        else if (r.spread > 48) r.error = "the clicks arrived inconsistently (" + std::to_string(r.spread) + " frames apart); use a cable or a loopback input";
        else r.ok = true;
    }
    probeOwnsInput_ = false;
    probeDone_.store(false, std::memory_order_relaxed);
    if (simulatedInput_ && !rec_.captureWriter && !(inputUid_ == kSimulatedInput && monitorWanted())) {
        duplex_.reset(); duplexInputUid_.clear(); simulatedInput_ = false;
    }
    syncInput(); // back to monitoring, or to the output alone
    if (duplex_ && !monitorWanted() && !simulatedInput_) closeDuplex();
    return true;
}

const std::vector<float> *Engine::livePeaks(DalnokTrackId track) {
    LivePeak p;
    while (rec_.livePeakQueue->pop(p)) {
        if (p.channel >= rec_.livePeaks.size()) continue;
        auto &v = rec_.livePeaks[p.channel];
        if (v.size() <= p.index) v.resize(p.index + 1, 0.0f);
        v[p.index] = p.peak;
    }
    for (size_t i = 0; i < rec_.recordAudio.size() && i < rec_.livePeaks.size(); ++i)
        if (rec_.recordAudio[i].track == track) return &rec_.livePeaks[i];
    return nullptr;
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
    if (rec_.captureWriter) { err = "capture is already active"; return false; }
    if (channels.empty() || channels.size() > 64) { err = "choose 1 to 64 input channels"; return false; }
    int highest = 0;
    for (int c : channels) {
        if (c < 0 || c > 63) { err = "input channel out of range"; return false; }
        highest = std::max(highest, c);
    }
    const auto count = static_cast<uint32_t>(channels.size());
    const bool simulated = uid == kSimulatedInput;
    const bool simulatedRunning = simulatedInput_ && duplex_ && duplexInputUid_ == kSimulatedInput; // monitoring it
    if (simulated ? (device_ != nullptr || (duplex_ != nullptr && !simulatedRunning)) : (uid.empty() || (!device_ && !duplex_))) {
        err = simulated ? "the simulated input requires the output device to be stopped"
                        : "start the output device and choose an input device before capture";
        return false;
    }
    if (path.empty() || sampleRate_ != std::floor(sampleRate_) || sampleRate_ < 8000 || sampleRate_ > 384000) {
        err = "invalid capture path or sample rate"; return false;
    }
    if (!simulated) {
        int inputs = 0;
        for (const auto &d : listInputDevices()) if (d.uid == uid) inputs = d.inputChannels;
        if (highest >= inputs) { err = inputs ? "the input device does not have the requested input" : "the input device is not available (unplugged?)"; return false; }
    }
    const int fd = CaptureSpool::create(path, static_cast<uint32_t>(sampleRate_), count);
    if (fd < 0) { err = "cannot create new capture spool"; return false; }
    try {
        rec_.captureSpool = std::make_unique<CaptureSpool>(fd, count);
        // About 5.5 seconds at 48 kHz; overflow always reports an error.
        rec_.captureWriter = std::make_unique<CaptureWriter>(1 << 18, count, *rec_.captureSpool);
        rec_.captureScratch.assign(static_cast<size_t>(kMaxCaptureBlock) * count, 0.0f);
        for (size_t i = 0; i < channels.size(); ++i) rec_.captureMap[i] = channels[i];
        rec_.captureChannels = static_cast<int>(count);
        rec_.captureWriter->start();
    } catch (...) {
        if (!rec_.captureSpool) ::close(fd);
        rec_.captureWriter.reset(); rec_.captureSpool.reset();
        err = "cannot start capture writer; spool retained"; return false;
    }
    rec_.captureInputFailed.store(false, std::memory_order_relaxed);
    rec_.captureMissingFrames.store(0, std::memory_order_relaxed);
    rec_.livePeaks.assign(count, {});
    for (LivePeak p; rec_.livePeakQueue->pop(p);) {}
    rec_.rtPeakAcc.fill(0); rec_.rtPeakFill = 0; rec_.rtPeakIndex = 0; // the audio thread reads them only once captureRT is set
    auto undo = [&] {
        rec_.captureRT.store(nullptr, std::memory_order_release);
        rec_.captureWriter->stop(); rec_.captureWriter.reset(); rec_.captureSpool.reset();
    };
    if (simulated) {
        if (!duplex_) duplex_ = std::make_unique<SimulatedDuplex>(sampleRate_, simulatedLatency_);
        duplexInputUid_ = kSimulatedInput;
        rec_.captureRT.store(rec_.captureWriter.get(), std::memory_order_release);
        simulatedInput_ = true;
        return true;
    }
    // Already running this input (monitoring): attach to it without a gap. Otherwise open input and output together.
    if (duplex_ && duplexInputUid_ != uid) closeDuplex();
    if (!duplex_ && !openDuplex(uid, highest, err)) { undo(); return false; }
    rec_.captureRT.store(rec_.captureWriter.get(), std::memory_order_release);
    return true;
}

bool Engine::captureStatus(DalnokCaptureStats &stats) const {
    if (!duplex_ || !rec_.captureWriter) return false;
    stats = {};
    stats.captured_frames = rec_.captureWriter->capturedFrames();
    stats.written_frames = rec_.captureWriter->writtenFrames();
    stats.dropped_frames = rec_.captureWriter->droppedFrames() + rec_.captureMissingFrames.load(std::memory_order_relaxed);
    const double hardwareRate = duplex_->hardwareSampleRate();
    stats.input_error = rec_.captureInputFailed.load(std::memory_order_acquire) || duplex_->captureFailed() || !duplex_->alive() ||
                        hardwareRate <= 0 || std::abs(hardwareRate - sampleRate_) > 0.5;
    stats.overflow = rec_.captureWriter->hasError(CaptureWriter::Error::overflow);
    stats.write_error = rec_.captureWriter->hasError(CaptureWriter::Error::write);
    stats.finalize_error = rec_.captureWriter->hasError(CaptureWriter::Error::finalize);
    return true;
}

bool Engine::stopCapture(DalnokCaptureStats &stats, std::string &err, bool restoreOutput) {
    if (!duplex_ || !rec_.captureWriter) { err = "capture is not active"; return false; }
    // Keep the input running if something still monitors it; otherwise go back to the output device alone.
    const bool keep = restoreOutput && monitorWanted() && duplexInputUid_ == inputUid_;
    if (keep) {
        rec_.captureRT.store(nullptr, std::memory_order_release);
        waitForAudioCycles(); // no callback still writes to the writer
    } else {
        duplex_->stop(); // callback no longer accesses rec_.captureRT
        rec_.captureRT.store(nullptr, std::memory_order_release);
    }
    rec_.captureChannels = 0;
    rec_.captureWriter->stop();
    captureStatus(stats);
    if (!keep) { duplex_.reset(); duplexInputUid_.clear(); }
    rec_.captureWriter.reset(); rec_.captureSpool.reset();
    updateWorkgroup();
    const bool valid = !stats.input_error && !stats.overflow && !stats.write_error && !stats.finalize_error &&
                       stats.captured_frames > 0 && stats.captured_frames == stats.written_frames;
    std::string outputError;
    const bool restore = restoreOutput && !simulatedInput_;
    if (!keep) simulatedInput_ = false;
    const bool outputOK = keep || !restore || startDevice(outputError);
    if (restore && !keep) syncInput(); // e.g. monitoring another input
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
    if (rec_.captureWriter && duplex_) { DalnokCaptureStats stats{}; std::string ignored; stopCapture(stats, ignored, false); }
    if (duplex_) { // monitoring only
        duplex_->stop();
        duplex_.reset();
        duplexInputUid_.clear();
        rtInputs_ = nullptr;
        rtInputCount_ = 0;
        updateWorkgroup();
    }
    if (!device_) return;
    device_->stop(); // synchronous: the audio thread is no longer inside process()
    device_.reset();
    updateWorkgroup();
}

void Engine::collectGarbage() {
    RenderState *s = nullptr;
    while (retired_.pop(s)) delete s;
    // Plug-ins edited in their editors, and isolated plug-ins whose host failed: stamp only their tracks (A-05).
    // A failure changes what the track shows but is not an edit: a clean project stays clean.
    std::vector<DalnokTrackId> edited;
    std::vector<int32_t> failed;
    const auto changed = pluginHost_.poll(&failed);
    for (int32_t id : changed) for (const auto &t : model_.tracks)
        for (const auto &slot : t.plugins) if (slot.id == id) edited.push_back(t.id);
    for (int32_t id : failed) for (const auto &t : model_.tracks)
        for (const auto &slot : t.plugins) if (slot.id == id) edited.push_back(t.id);
    if (!changed.empty() || !failed.empty()) {
        const bool clean = revision_ == savedRevision_;
        ++revision_;
        stampTracks(edited);
        if (changed.empty() && clean) savedRevision_ = revision_;
    }
    if (rec_.active) drainRecordedMidi();
}

} // namespace dalnok
