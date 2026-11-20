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
    audioCallback(ctx, left, right, frames);
    const int n = self->captureChannels_;
    bool ok = inputs != nullptr && frames <= kMaxCaptureBlock;
    for (int c = 0; ok && c < n; ++c) {
        const int ch = self->captureMap_[static_cast<size_t>(c)];
        ok = ch < inputCount && inputs[ch] != nullptr;
    }
    if (!ok) {
        self->captureMissingFrames_.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed);
        self->captureInputFailed_.store(true, std::memory_order_release);
        return;
    }
    // Outside a recording session every frame is captured; in one, only the part of the block inside the
    // punch window, and only where the transport rolled continuously.
    const bool session = self->recordSession_.load(std::memory_order_acquire);
    if (self->captureRT_ && n > 0 && (!session || self->rtRecordingBlock_)) {
        const int from = session ? self->rtRecordOffset_ : 0, count = session ? self->rtRecordCount_ : frames;
        float *out = self->captureScratch_.data();
        for (int i = 0; i < count; ++i)
            for (int c = 0; c < n; ++c) out[i * n + c] = inputs[self->captureMap_[static_cast<size_t>(c)]][from + i];
        self->captureRT_->push(out, static_cast<uint32_t>(count));
    }
    if (self->monitoring_.load(std::memory_order_relaxed))
        for (int c = 0; c < n; ++c) {
            const float *in = inputs[self->captureMap_[static_cast<size_t>(c)]];
            for (int i = 0; i < frames; ++i) { left[i] += in[i]; right[i] += in[i]; }
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

void Engine::handleMidiInput(int64_t pos) DALNOK_NONBLOCKING {
    constexpr int kMaxEvents = 256;
    RecordedMidi events[kMaxEvents];
    int count = 0;
    const int32_t live = current_ ? current_->liveTrack : -1;
    const bool pluginLive = live >= 0 && current_->tracks[static_cast<size_t>(live)].instrumentPlugin;
    SynthState *synth = live >= 0 && !pluginLive ? &current_->tracks[static_cast<size_t>(live)].runtime->live : nullptr;
    rtLiveNoteCount_ = 0;
    for (auto &slot : midiInputs_) {
        MidiParser *parser = slot.load(std::memory_order_acquire);
        if (!parser) continue;
        MidiMessage m;
        while (parser->pop(m)) {
            const uint8_t type = m.status & 0xf0;
            const bool on = type == 0x90 && m.data2 > 0, off = type == 0x80 || (type == 0x90 && m.data2 == 0);
            if (pluginLive && (on || off) && rtLiveNoteCount_ < 256)
                rtLiveNotes_[rtLiveNoteCount_++] = PluginNote{0, static_cast<uint8_t>(on ? 1 : 0), m.data1, m.data2};
            if (synth && on) synth->noteOn(current_->synth, m.data1, m.data2, -1);
            else if (synth && off) synth->noteOff(current_->synth, m.data1);
            else if (synth && type == 0xb0 && (m.data1 == 120 || m.data1 == 123)) synth->reset();
            if (!on && !off) continue;
            if (count < kMaxEvents) events[count++] = {pos, m.status, m.data1, m.data2};
            else midiRecordDropped_.fetch_add(1, std::memory_order_relaxed);
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
    // Isolated plug-ins (ADR-0014) share one budget per callback: together they may wait 40 % of its period.
    scratch_.deadlineNs = nowNs() + static_cast<uint64_t>(0.4e9 * frames / sampleRate_);
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
    handleMidiInput(before);
    const bool anySolo = soloCount_.load(std::memory_order_relaxed) > 0;
    const int64_t seek = transport_.seekRequest.exchange(-1, std::memory_order_relaxed);
    if (seek >= 0) pendingSeek_ = seek;
    const bool play = transport_.playing.load(std::memory_order_relaxed);
    const float step = static_cast<float>(1.0 / (kTransportFadeSeconds * sampleRate_));

    // Cycle: read once per callback (the control thread writes start/end before enabling).
    // Recording plays straight through, except a cycle take (recordCycle_), which loops and becomes takes.
    const bool cycleTake = recordCycle_.load(std::memory_order_acquire) && recordArmed_.load(std::memory_order_relaxed);
    const bool cycling = transport_.cycleOn.load(std::memory_order_acquire) && (!recordArmed_.load(std::memory_order_relaxed) || cycleTake);
    int64_t advanced = 0; // frames the transport advanced in this callback (cycle wraps included)
    bool jumped = false;  // a seek landed in this callback
    const int64_t cycleStart = transport_.cycleStart.load(std::memory_order_relaxed), cycleEnd = transport_.cycleEnd.load(std::memory_order_relaxed);
    const bool cycleValid = cycling && cycleEnd - cycleStart >= 64 && cycleStart >= 0;

    for (int off = 0; off < frames;) {
        int n = std::min(kMaxBlock, frames - off);
        // Stop the sub-block exactly at the cycle end so the jump back lands on the right sample.
        if (cycleValid && play && pendingSeek_ < 0 && rtPosition_ < cycleEnd && rtPosition_ + n > cycleEnd)
            n = static_cast<int>(cycleEnd - rtPosition_);
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
            if (current_) renderLiveInput(*current_, n, l, r, scratch_, anySolo, true);
            continue;
        }
        scratch_.liveNotes = rtLiveNotes_;
        scratch_.liveNoteCount = off == n ? rtLiveNoteCount_ : 0;
        if (current_) {
            // Rendered ahead by the delay compensation, so what is heard lines up with the playhead.
            renderBlock(*current_, rtPosition_ + current_->compensation, n, l, r, scratch_, true, anySolo);
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
        if (current_) renderLiveInput(*current_, n, l, r, scratch_, anySolo, false);
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
    const uint32_t take = recordTake_.load(std::memory_order_acquire);
    if (take != rtTake_) { rtTake_ = take; rtRecordNext_ = -1; }
    rtRecordingBlock_ = false;
    rtRecordOffset_ = 0;
    rtRecordCount_ = frames;
    if (recordArmed_.load(std::memory_order_acquire) && !recordBroken_.load(std::memory_order_relaxed)) {
        // Punch window: only frames in [in, out) belong to the take (whole blocks without punch).
        const int64_t in = transport_.punchIn.load(std::memory_order_relaxed), out = transport_.punchOut.load(std::memory_order_relaxed);
        const bool finished = rtRecordNext_ >= 0 && rtRecordNext_ >= out; // past punch-out: nothing more to check
        if (cycleTake) {
            // Cycle take: every frame while the transport rolls continuously, across wraps. The control
            // thread cuts the capture into one take per pass when recording stops.
            if (advanced == frames && !jumped && pendingSeek_ < 0) {
                if (rtRecordNext_ < 0) recordStart_.store(before, std::memory_order_release);
                rtRecordingBlock_ = true;
                rtRecordNext_ = 0; // started
                recordEnd_.store(rtPosition_, std::memory_order_release);
            } else if (rtRecordNext_ >= 0) {
                recordBroken_.store(true, std::memory_order_release);
            }
        }
        // A block that ends with a seek still pending is a fade-out before a jump (e.g. count-in pre-roll
        // requested while playing): it never starts a take, and during a take the jump breaks it below.
        else if (!finished && rtPosition_ - before == frames && pendingSeek_ < 0) {
            const int64_t blockStart = rtPosition_ - frames;
            const int64_t from = std::max(blockStart, in), to = std::min(rtPosition_, out);
            if (to > from) {
                if (rtRecordNext_ < 0) recordStart_.store(from, std::memory_order_release);
                if (rtRecordNext_ >= 0 && from != rtRecordNext_) recordBroken_.store(true, std::memory_order_release);
                else {
                    rtRecordingBlock_ = true;
                    rtRecordOffset_ = static_cast<int>(from - blockStart);
                    rtRecordCount_ = static_cast<int>(to - from);
                    recordEnd_.store(to, std::memory_order_release);
                }
                rtRecordNext_ = to;
            }
        } else if (!finished && rtRecordNext_ >= 0) {
            recordBroken_.store(true, std::memory_order_release); // paused or sought during the take
        }
    }
    if (rtRecordingBlock_ && recordMidi_.load(std::memory_order_acquire)) {
        for (int i = 0; i < rtMidiCount_; ++i) {
            RecordedMidi e = rtMidiEvents_[i];
            e.pos = rtPosition_ - frames + rtRecordOffset_; // block-accurate, clamped into the punch window
            if (!midiRecordQueue_.push(e)) midiRecordDropped_.fetch_add(1, std::memory_order_relaxed);
        }
    }
    rtMidiCount_ = 0;
}

} // namespace dalnok
