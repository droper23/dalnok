// Engine: the real-time audio path (split from engine.cpp, A-06).
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

// ---- Audio thread -------------------------------------------------------

void Engine::duplexCallback(void *ctx, float *left, float *right, const float *const *inputs, int inputCount,
                            int frames) DALNOK_NONBLOCKING {
    auto *self = static_cast<Engine *>(ctx);
    // Monitored tracks read the inputs inside process() (sub-block slices set there).
    self->rtInputs_ = inputs;
    self->rtInputCount_ = inputs ? std::min(inputCount, 64) : 0;
    self->scratch_.monitorArmed = self->rec_.monitoring.load(std::memory_order_relaxed);
    audioCallback(ctx, left, right, frames);
    self->rtInputs_ = nullptr;
    self->rtInputCount_ = 0;
    self->scratch_.liveInputCount = 0;

    // Latency probe: silence except a click every period; read the probe channel back.
    if (self->probeActive_.load(std::memory_order_acquire)) {
        const int ch = self->probeChannel_;
        const float *in = inputs && ch < inputCount ? inputs[ch] : nullptr;
        if (!in) self->probeFailed_.store(true, std::memory_order_relaxed);
        const auto size = static_cast<int64_t>(self->probeBuf_.size());
        const auto burst = static_cast<int64_t>(self->probeBurst_.size());
        for (int i = 0; i < frames; ++i) {
            const int64_t f = self->probeFrame_ + i;
            const int64_t k = f >= self->probeFirst_ ? (f - self->probeFirst_) % self->probePeriod_ : burst;
            left[i] = right[i] = k < burst ? self->probeBurst_[static_cast<size_t>(k)] : 0.0f;
            if (f < size) self->probeBuf_[static_cast<size_t>(f)] = in ? in[i] : 0.0f;
        }
        self->probeFrame_ += frames;
        if (self->probeFrame_ >= size) {
            self->probeActive_.store(false, std::memory_order_relaxed);
            self->probeDone_.store(true, std::memory_order_release);
        }
    }

    // Stream check: the quiet burst train goes out with the mix; the mix as written and the loopback come back.
    if (self->checkActive_.load(std::memory_order_acquire)) {
        const int ch = self->checkChannel_;
        const float *in = inputs && ch < inputCount ? inputs[ch] : nullptr;
        const auto size = static_cast<int64_t>(self->checkIn_.size());
        for (int i = 0; i < frames; ++i) {
            const int64_t f = self->checkFrame_ + i;
            if (f >= size) break;
            const float b = self->checkAdd_[static_cast<size_t>(f)];
            left[i] += b; right[i] += b;
            self->checkRef_[static_cast<size_t>(f)] = 0.5f * (left[i] + right[i]);
            self->checkIn_[static_cast<size_t>(f)] = in ? in[i] : 0.0f;
        }
        self->checkFrame_ += frames;
        if (self->checkFrame_ >= size) {
            self->checkActive_.store(false, std::memory_order_relaxed);
            self->checkDone_.store(true, std::memory_order_release);
        }
    }

    CaptureWriter *writer = self->rec_.captureRT.load(std::memory_order_acquire);
    if (!writer) return; // monitoring only
    const int n = self->rec_.captureChannels;
    bool ok = inputs != nullptr && frames <= kMaxCaptureBlock;
    for (int c = 0; ok && c < n; ++c) {
        const int ch = self->rec_.captureMap[static_cast<size_t>(c)];
        ok = ch < inputCount && inputs[ch] != nullptr;
    }
    if (!ok) {
        self->rec_.captureMissingFrames.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed);
        self->rec_.captureInputFailed.store(true, std::memory_order_release);
        return;
    }
    // Outside a recording session every frame is captured; in one, only the part of the block inside the
    // punch window, and only where the transport rolled continuously.
    const bool session = self->rec_.recordSession.load(std::memory_order_acquire);
    if (n > 0 && (!session || self->rec_.rtRecordingBlock)) {
        const int from = session ? self->rec_.rtRecordOffset : 0, count = session ? self->rec_.rtRecordCount : frames;
        float *out = self->rec_.captureScratch.data();
        RecordingState &r = self->rec_;
        for (int i = 0; i < count; ++i) {
            for (int c = 0; c < n; ++c) {
                const float v = inputs[r.captureMap[static_cast<size_t>(c)]][from + i];
                out[i * n + c] = v;
                const float a = v < 0 ? -v : v;
                if (a > r.rtPeakAcc[static_cast<size_t>(c)]) r.rtPeakAcc[static_cast<size_t>(c)] = a;
            }
            // Live waveform: one peak per channel every kLivePeakFrames frames of the take.
            if (session && ++r.rtPeakFill == kLivePeakFrames) {
                for (int c = 0; c < n; ++c) {
                    r.livePeakQueue->push(LivePeak{r.rtPeakIndex, static_cast<uint16_t>(c), r.rtPeakAcc[static_cast<size_t>(c)]});
                    r.rtPeakAcc[static_cast<size_t>(c)] = 0;
                }
                r.rtPeakFill = 0;
                ++r.rtPeakIndex;
            }
        }
        writer->push(out, static_cast<uint32_t>(count));
    }
}

void Engine::renderClick(float *left, float *right, int frames, int64_t pos) DALNOK_NONBLOCKING {
    const bool on = transport_.metronome.load(std::memory_order_relaxed);
    const int64_t until = transport_.countInUntil.load(std::memory_order_relaxed); // count-in clicks even with the metronome off
    const float level = transport_.metronomeLevel.load(std::memory_order_relaxed), decay = clickDecay_.load(std::memory_order_relaxed);
    bool accent = false;
    int64_t next = (on || pos < until) && current_ ? nextClick(*current_, pos, accent) : INT64_MAX;
    for (int i = 0; i < frames; ++i) {
        if ((on || pos + i < until) && pos + i == next) { // start a click: sine via a two-term recursion, no libm on this thread
            clickCoefNow_ = accent ? clickAccentCoef_.load(std::memory_order_relaxed) : clickCoef_.load(std::memory_order_relaxed);
            clickY1_ = 0;
            clickY2_ = -(accent ? clickAccentSin_.load(std::memory_order_relaxed) : clickSin_.load(std::memory_order_relaxed));
            clickEnv_ = level * (accent ? 1.0f : 0.6f);
            clickLeft_ = static_cast<int>(sampleRate_ * 0.08);
            next = nextClick(*current_, pos + i + 1, accent);
        }
        if (clickLeft_ <= 0) continue;
        const float y = clickCoefNow_ * clickY1_ - clickY2_;
        clickY2_ = clickY1_;
        clickY1_ = y;
        const float v = y * clickEnv_; // sin(w), sin(2w), ...: the onset sample is already non-zero
        left[i] += v;
        right[i] += v;
        clickEnv_ *= decay;
        --clickLeft_;
    }
}

void Engine::handleMidiInput(int64_t pos, int frames) DALNOK_NONBLOCKING {
    constexpr int kMaxEvents = 256;
    RecordedMidi events[kMaxEvents];
    int count = 0;
    // Auditioned notes (piano roll): they choose the track that plays live input for a while.
    PreviewNote previews[64];
    int previewCount = 0;
    for (PreviewNote pn; previewCount < 64 && previewNotes_.pop(pn);) {
        if (pn.track != rtPreviewTrack_) { rtPreviewTrack_ = pn.track; rtPreviewHeld_ = 0; }
        rtPreviewHeld_ = pn.on ? rtPreviewHeld_ + 1 : (rtPreviewHeld_ > 0 ? rtPreviewHeld_ - 1 : 0);
        rtPreviewHoldFrames_ = static_cast<int64_t>(2 * sampleRate_);
        previews[previewCount++] = pn;
    }
    int32_t live = current_ ? current_->liveTrack : -1;
    if (current_ && rtPreviewTrack_ && (rtPreviewHeld_ > 0 || rtPreviewHoldFrames_ > 0)) {
        for (size_t i = 0; i < current_->tracks.size(); ++i)
            if (current_->tracks[i].id == rtPreviewTrack_) { live = static_cast<int32_t>(i); break; }
    }
    if (rtPreviewHeld_ == 0 && rtPreviewHoldFrames_ > 0) rtPreviewHoldFrames_ -= frames;
    scratch_.liveTrack = live;
    if (live >= 0 && current_ && !(current_->tracks[static_cast<size_t>(live)].instrument || current_->tracks[static_cast<size_t>(live)].instrumentPlugin))
        live = -1;
    const bool pluginLive = live >= 0 && current_->tracks[static_cast<size_t>(live)].instrumentPlugin;
    SynthState *synth = live >= 0 && !pluginLive ? &current_->tracks[static_cast<size_t>(live)].runtime->live : nullptr;
    rtLiveNoteCount_ = 0;
    for (int i = 0; i < previewCount; ++i) {
        const PreviewNote &pn = previews[i];
        if (live < 0 || current_->tracks[static_cast<size_t>(live)].id != pn.track) continue;
        if (pluginLive && rtLiveNoteCount_ < 256) rtLiveNotes_[rtLiveNoteCount_++] = PluginNote{0, static_cast<uint8_t>(pn.on ? 1 : 0), pn.pitch, pn.velocity};
        if (synth && pn.on) synth->noteOn(current_->synth, pn.pitch, pn.velocity, -1);
        else if (synth) synth->noteOff(current_->synth, pn.pitch);
    }
    for (auto &slot : midiInputs_) {
        MidiParser *parser = slot.load(std::memory_order_acquire);
        if (!parser) continue;
        MidiMessage m;
        while (parser->pop(m)) {
            const uint8_t type = m.status & 0xf0;
            const bool on = type == 0x90 && m.data2 > 0, off = type == 0x80 || (type == 0x90 && m.data2 == 0);
            if (on || off) (void)inputNotes_.push({m.data1, m.data2, on}); // for step input; full = dropped, harmless
            if (pluginLive && (on || off) && rtLiveNoteCount_ < 256)
                rtLiveNotes_[rtLiveNoteCount_++] = PluginNote{0, static_cast<uint8_t>(on ? 1 : 0), m.data1, m.data2};
            // Controllers (sustain pedal, mod wheel, ...) and pitch bend reach a plug-in instrument played live.
            if (pluginLive && (type == 0xb0 || type == 0xe0) && rtLiveNoteCount_ < 256)
                rtLiveNotes_[rtLiveNoteCount_++] = PluginNote{0, type == 0xb0 ? kEventControl : kEventPitchBend, m.data1, m.data2};
            if (synth && on) synth->noteOn(current_->synth, m.data1, m.data2, -1);
            else if (synth && off) synth->noteOff(current_->synth, m.data1);
            else if (synth && type == 0xb0) synth->control(current_->synth, m.data1, m.data2);
            else if (synth && type == 0xe0) synth->pitchBend(m.data1 | (m.data2 << 7));
            if (!on && !off && type != 0xb0 && type != 0xe0) continue; // notes, controllers and pitch bend are recorded
            if (count < kMaxEvents) events[count++] = {pos, m.status, m.data1, m.data2};
            else rec_.midiRecordDropped.fetch_add(1, std::memory_order_relaxed);
        }
    }
    // Record after the block decided whether the transport rolled (see process).
    rtMidiCount_ = 0;
    for (int i = 0; i < count; ++i) rtMidiEvents_[rtMidiCount_++] = events[i];
}

void Engine::audioCallback(void *ctx, float *left, float *right, int frames) DALNOK_NONBLOCKING {
    auto *self = static_cast<Engine *>(ctx);
    const uint64_t t0 = nowNs();
    self->process(left, right, frames);
    const uint64_t dt = nowNs() - t0;

    self->callbacks_.fetch_add(1, std::memory_order_relaxed);
    self->framesRendered_.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed);
    self->lastCallbackNs_.store(dt, std::memory_order_relaxed);
    atomicMax(self->maxCallbackNs_, dt);
    if (static_cast<uint32_t>(frames) > self->maxFrames_.load(std::memory_order_relaxed))
        self->maxFrames_.store(static_cast<uint32_t>(frames), std::memory_order_relaxed);
    if (static_cast<double>(dt) > static_cast<double>(frames) / self->sampleRate_ * 1e9)
        self->overloads_.fetch_add(1, std::memory_order_relaxed);
}


void Engine::process(float *left, float *right, int frames) DALNOK_NONBLOCKING {
    [[maybe_unused]] const FlushDenormals flushDenormals;
    // Isolated plug-ins (ADR-0014) share one budget per callback. It used to be a fixed 40 % of the period, which
    // dropped effects on big projects (512 isolated units: 7.6 % of blocks skipped one, while the same project
    // in-process kept up with 30 % to spare). Now it is what the rest of the block leaves: the period, less the
    // non-plug-in work of recent callbacks (with 50 % headroom) and a 10 % margin, kept between 40 and 85 %.
    const uint64_t startNs = nowNs();
    const double periodNs = 1e9 * frames / sampleRate_;
    const double budget = std::clamp(periodNs * 0.9 - 1.5 * static_cast<double>(restEstimateNs_), periodNs * 0.4, periodNs * 0.85);
    scratch_.deadlineNs = startNs + static_cast<uint64_t>(budget);
    scratch_.isolatedWaitNs = 0;
    lastIsolatedBudget_.store(static_cast<float>(budget / periodNs), std::memory_order_relaxed);
    // Adopt the newest snapshot only if the previous one can be retired.
    if (!retired_.full()) {
        if (RenderState *s = pending_.exchange(nullptr, std::memory_order_acq_rel)) {
            if (current_) retired_.push(current_);
            current_ = s;
            swaps_.fetch_add(1, std::memory_order_relaxed);
            pendingSnapshotCallbacks_.store(0, std::memory_order_relaxed);
            const auto depth = static_cast<uint32_t>(retired_.size());
            const auto high = retiredHighWater_.load(std::memory_order_relaxed);
            if (depth > high) retiredHighWater_.store(depth, std::memory_order_relaxed);
        }
    } else if (pending_.load(std::memory_order_acquire)) {
        pendingSnapshotCallbacks_.fetch_add(1, std::memory_order_relaxed);
        adoptionSkips_.fetch_add(1, std::memory_order_relaxed);
    }
    const int64_t before = rtPosition_;
    handleMidiInput(before, frames);
    const bool anySolo = soloCount_.load(std::memory_order_relaxed) > 0;
    const int64_t seek = transport_.seekRequest.exchange(-1, std::memory_order_relaxed);
    if (seek >= 0) pendingSeek_ = seek;
    const bool play = transport_.playing.load(std::memory_order_relaxed);
    const float step = static_cast<float>(1.0 / (kTransportFadeSeconds * sampleRate_));

    // Cycle: read once per callback (the control thread writes start/end before enabling).
    // Recording plays straight through, except a cycle take (rec_.recordCycle), which loops and becomes takes.
    const bool cycleTake = rec_.recordCycle.load(std::memory_order_acquire) && rec_.recordArmed.load(std::memory_order_relaxed);
    const bool cycling = transport_.cycleOn.load(std::memory_order_acquire) && (!rec_.recordArmed.load(std::memory_order_relaxed) || cycleTake);
    int64_t advanced = 0; // frames the transport advanced in this callback (cycle wraps included)
    bool jumped = false;  // a seek landed in this callback
    const int64_t cycleStart = transport_.cycleStart.load(std::memory_order_relaxed), cycleEnd = transport_.cycleEnd.load(std::memory_order_relaxed);
    const bool cycleValid = cycling && cycleEnd - cycleStart >= 64 && cycleStart >= 0;

    for (int off = 0; off < frames;) {
        int n = std::min(kMaxBlock, frames - off);
        // Stop the sub-block exactly at the cycle end so the jump back lands on the right sample.
        if (cycleValid && play && pendingSeek_ < 0 && rtPosition_ < cycleEnd && rtPosition_ + n > cycleEnd)
            n = static_cast<int>(cycleEnd - rtPosition_);
        // Rendering runs `compensation` frames ahead of the playhead, so it reaches the cycle end first: it wraps there
        // (and the sub-block stops there), while the playhead wraps `compensation` frames later.
        const int64_t comp = current_ ? current_->compensation : 0;
        auto renderAt = [&](int64_t p) DALNOK_NONBLOCKING {
            int64_t rp = p + comp;
            if (cycleValid && play && pendingSeek_ < 0 && p < cycleEnd && rp >= cycleEnd) rp = cycleStart + (rp - cycleEnd) % (cycleEnd - cycleStart);
            return rp;
        };
        const int64_t renderPos = renderAt(rtPosition_);
        if (cycleValid && play && pendingSeek_ < 0 && rtPosition_ < cycleEnd && renderPos < cycleEnd && renderPos + n > cycleEnd)
            n = static_cast<int>(cycleEnd - renderPos);
        // Clip launcher: switch tracks exactly at their launch frame and cut blocks at loop ends, so every
        // change lands on a block start (rendered position = playhead + compensation).
        if (current_ && play && pendingSeek_ < 0) {
            const int64_t rp = rtPosition_ + current_->compensation;
            for (const RenderTrack &t : current_->tracks) {
                TrackRuntime &rt = *t.runtime;
                const int64_t la = rt.launchAt.load(std::memory_order_acquire);
                const bool logging = launcherRecording_.load(std::memory_order_relaxed);
                if (la >= 0 && la <= rp) {
                    const int32_t target = rt.launchTarget.load(std::memory_order_relaxed);
                    rt.playingSlot.store(target, std::memory_order_relaxed);
                    rt.slotStart.store(la, std::memory_order_relaxed);
                    rt.slotLoops = 0;
                    rt.launchAt.store(-1, std::memory_order_relaxed);
                    if (logging) launchEvents_.push(LaunchEvent{t.id, target, la});
                } else if (la >= 0 && la < rp + n) {
                    n = static_cast<int>(la - rp);
                }
                const int32_t ps = rt.playingSlot.load(std::memory_order_relaxed);
                if (ps < 0) continue;
                for (const RenderSlot &sl : t.content->slots) {
                    if (sl.slot != ps || sl.length <= 0) continue;
                    const int64_t start = rt.slotStart.load(std::memory_order_relaxed);
                    const int64_t rel = ((rp - start) % sl.length + sl.length) % sl.length;
                    // At a loop boundary: count it and run the follow action, exactly here.
                    if (rel == 0 && rp > start) {
                        ++rt.slotLoops;
                        if (sl.follow != 0 && rt.slotLoops >= sl.followLoops && rt.launchAt.load(std::memory_order_relaxed) < 0) {
                            const int32_t next = sl.follow == 1 ? sl.nextSlot : -1;
                            rt.playingSlot.store(next, std::memory_order_relaxed);
                            rt.slotStart.store(rp, std::memory_order_relaxed);
                            rt.slotLoops = 0;
                            if (logging) launchEvents_.push(LaunchEvent{t.id, next, rp});
                            break;
                        }
                    }
                    if (rel + n > sl.length) n = static_cast<int>(sl.length - rel);
                }
            }
        }
        float *l = left + off, *r = right + off;
        scratch_.liveInputCount = rtInputCount_;
        for (int c = 0; c < rtInputCount_; ++c) scratch_.liveInputs[c] = rtInputs_[c] ? rtInputs_[c] + off : nullptr;
        off += n;

        if (pendingSeek_ >= 0 && transportGain_ == 0.0f) {
            rtPosition_ = pendingSeek_;
            pendingSeek_ = -1;
            jumped = true;
        }
        const float target = (play && pendingSeek_ < 0) ? 1.0f : 0.0f;

        if (transportGain_ == 0.0f && target == 0.0f) {
            for (int i = 0; i < n; ++i) l[i] = r[i] = 0.0f;
            scratch_.liveNotes = rtLiveNotes_;
            scratch_.liveNoteCount = off == n ? rtLiveNoteCount_ : 0; // live notes go to the first sub-block
            if (current_) {
                // Input Monitoring while stopped: monitored tracks (and the buses they feed) play their input.
                // and live MIDI plays the live instrument track: both through their strips and routing.
                bool monitor = false;
                for (int k = 0; scratch_.liveInputCount > 0 && k < static_cast<int>(current_->tracks.size()) && !monitor; ++k)
                    monitor = monitorsInput(current_->tracks[static_cast<size_t>(k)], scratch_);
                const int32_t lt = scratch_.liveTrack;
                const bool live = lt >= 0 && lt < static_cast<int32_t>(current_->tracks.size()) &&
                                  (current_->tracks[static_cast<size_t>(lt)].instrumentPlugin ||
                                   (current_->tracks[static_cast<size_t>(lt)].instrument && current_->tracks[static_cast<size_t>(lt)].runtime->live.active()));
                scratch_.timelineOff = monitor || live;
                if (off == n) idlePlugins(*current_, scratch_); // once per callback
                if (monitor || live) renderBlock(*current_, rtPosition_ + current_->compensation, n, l, r, scratch_, true, anySolo);
                scratch_.timelineOff = false;
                // The master meter shows live input and auditioned notes while stopped, as the track meter does.
                float pl = 0, pr = 0;
                for (int i = 0; i < n; ++i) {
                    pl = std::max(pl, meterLevel(l[i], masterDcL_));
                    pr = std::max(pr, meterLevel(r[i], masterDcR_));
                }
                raisePeak(masterPeakL_, pl);
                raisePeak(masterPeakR_, pr);
            }
            continue;
        }
        scratch_.liveNotes = rtLiveNotes_;
        scratch_.liveNoteCount = off == n ? rtLiveNoteCount_ : 0;
        if (current_) {
            // Rendered ahead by the delay compensation, so what is heard lines up with the playhead.
            renderBlock(*current_, renderAt(rtPosition_), n, l, r, scratch_, true, anySolo); // after a seek landed
        } else {
            for (int i = 0; i < n; ++i) l[i] = r[i] = 0.0f;
        }
        float g = transportGain_;
        if (g != target) {
            for (int i = 0; i < n; ++i) {
                g = target > g ? std::min(target, g + step) : std::max(target, g - step);
                l[i] *= g;
                r[i] *= g;
            }
            transportGain_ = g;
        }
        if (play && pendingSeek_ < 0) loudness_->process(l, r, n); // before the click: it is never part of the mix
        if (play && pendingSeek_ < 0 && (clickLeft_ > 0 || transport_.metronome.load(std::memory_order_relaxed) ||
                                         rtPosition_ < transport_.countInUntil.load(std::memory_order_relaxed)))
            renderClick(l, r, n, rtPosition_);
        float pl = 0, pr = 0;
        for (int i = 0; i < n; ++i) {
            pl = std::max(pl, meterLevel(l[i], masterDcL_));
            pr = std::max(pr, meterLevel(r[i], masterDcR_));
        }
        raisePeak(masterPeakL_, pl);
        raisePeak(masterPeakR_, pr);
        rtPosition_ += n;
        advanced += n;
        if (cycleValid && play && pendingSeek_ < 0 && rtPosition_ == cycleEnd) rtPosition_ = cycleStart;
    }
    transport_.position.store(pendingSeek_ >= 0 ? pendingSeek_ : rtPosition_, std::memory_order_relaxed);

    // Recording: a take covers the blocks where the transport advanced continuously.
    const uint32_t take = rec_.recordTake.load(std::memory_order_acquire);
    if (take != rtTake_) { rtTake_ = take; rec_.rtRecordNext = -1; }
    rec_.rtRecordingBlock = false;
    rec_.rtRecordOffset = 0;
    rec_.rtRecordCount = frames;
    if (rec_.recordArmed.load(std::memory_order_acquire) && !rec_.recordBroken.load(std::memory_order_relaxed)) {
        // Punch window: only frames in [in, out) belong to the take (whole blocks without punch).
        const int64_t in = transport_.punchIn.load(std::memory_order_relaxed), out = transport_.punchOut.load(std::memory_order_relaxed);
        const bool finished = rec_.rtRecordNext >= 0 && rec_.rtRecordNext >= out; // past punch-out: nothing more to check
        if (cycleTake) {
            // Cycle take: every frame while the transport rolls continuously, across wraps. The control
            // thread cuts the capture into one take per pass when recording stops.
            if (advanced == frames && !jumped && pendingSeek_ < 0) {
                if (rec_.rtRecordNext < 0) rec_.recordStart.store(before, std::memory_order_release);
                rec_.rtRecordingBlock = true;
                rec_.rtRecordNext = 0; // started
                rec_.recordEnd.store(rtPosition_, std::memory_order_release);
            } else if (rec_.rtRecordNext >= 0) {
                rec_.recordBroken.store(true, std::memory_order_release);
            }
        }
        // A block that ends with a seek still pending is a fade-out before a jump (e.g. count-in pre-roll
        // requested while playing): it never starts a take, and during a take the jump breaks it below.
        else if (!finished && rtPosition_ - before == frames && pendingSeek_ < 0) {
            const int64_t blockStart = rtPosition_ - frames;
            const int64_t from = std::max(blockStart, in), to = std::min(rtPosition_, out);
            if (to > from) {
                if (rec_.rtRecordNext < 0) rec_.recordStart.store(from, std::memory_order_release);
                if (rec_.rtRecordNext >= 0 && from != rec_.rtRecordNext) rec_.recordBroken.store(true, std::memory_order_release);
                else {
                    rec_.rtRecordingBlock = true;
                    rec_.rtRecordOffset = static_cast<int>(from - blockStart);
                    rec_.rtRecordCount = static_cast<int>(to - from);
                    rec_.recordEnd.store(to, std::memory_order_release);
                }
                rec_.rtRecordNext = to;
            }
        } else if (!finished && rec_.rtRecordNext >= 0) {
            rec_.recordBroken.store(true, std::memory_order_release); // paused or sought during the take
        }
    }
    if (rec_.rtRecordingBlock && rec_.recordMidi.load(std::memory_order_acquire)) {
        for (int i = 0; i < rtMidiCount_; ++i) {
            RecordedMidi e = rtMidiEvents_[i];
            e.pos = rtPosition_ - frames + rec_.rtRecordOffset; // block-accurate, clamped into the punch window
            if (!rec_.midiRecordQueue.push(e)) rec_.midiRecordDropped.fetch_add(1, std::memory_order_relaxed);
        }
    }
    rtMidiCount_ = 0;
    // This block's own work (everything but waiting on isolated hosts) feeds the next budget. The estimate jumps up
    // at once and decays slowly (about 1 % every 2.7 callbacks), so one light block doesn't invite an overload.
    const uint64_t total = nowNs() - startNs, own = total > scratch_.isolatedWaitNs ? total - scratch_.isolatedWaitNs : 0;
    restEstimateNs_ = std::max(own, restEstimateNs_ - restEstimateNs_ / 256);
}

} // namespace dalnok
