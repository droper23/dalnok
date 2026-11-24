// Recording state (A-06): device capture into the spool, the take in progress, and what the audio thread shares with
// the control thread while recording. Engine owns one `RecordingState`; record.cpp, engine_audio.cpp and
// engine_device.cpp drive it.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "capture_spool.hpp"
#include "dalnok/dalnok.h"
#include "rt.hpp"

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace dalnok {

// An armed audio track in the take: spool channel `channel` becomes `wav`.
// part: 0 a mono take; 1 and 2 the left and right of a stereo track (merged into one stereo file after recording).
struct RecordAudio { DalnokTrackId track; std::string name; int channel; std::string wav; int part = 0; };
// A MIDI event captured during a take, at its timeline position.
struct RecordedMidi { int64_t pos; uint8_t status, data1, data2; };
// Live waveform while recording: the peak of `kLivePeakFrames` captured frames of one spool channel. `index` counts
// buckets from the start of the take (its frames are contiguous in the take).
constexpr int kLivePeakFrames = 256;
struct LivePeak { uint32_t index; uint16_t channel; float peak; };

struct RecordingState {
    // Device capture (set up before the duplex device starts; captureRT is what the audio thread writes to).
    std::unique_ptr<CaptureSpool> captureSpool;
    std::unique_ptr<CaptureWriter> captureWriter;
    // What the audio thread writes to. Published (release) after captureMap/captureChannels/captureScratch are set, so
    // capture can attach to an input device that is already running for monitoring; cleared before they change.
    std::atomic<CaptureWriter *> captureRT{nullptr};
    std::array<int, 64> captureMap{};   // device input channel for each spool channel
    int captureChannels = 0;
    std::vector<float> captureScratch;  // interleaving space
    std::atomic<bool> captureInputFailed{false};
    std::atomic<uint64_t> captureMissingFrames{0};

    // The take (control thread).
    bool active = false;
    DalnokTrackId recordAudioTrack = 0, recordMidiTrack = 0; // audio: the first armed audio track
    std::vector<RecordAudio> recordAudio;                    // spool channel i belongs to recordAudio[i]
    std::string recordSpool, recordWav, recordJournal;
    int64_t latencyOffset = 0;
    std::vector<RecordedMidi> midiTake;
    int64_t recordCycleStart = 0, recordCycleEnd = 0; // the cycle when the take started

    // Shared with the audio thread.
    std::atomic<bool> recordArmed{false}, recordMidi{false}, recordBroken{false}, monitoring{false};
    std::atomic<int64_t> recordStart{-1}, recordEnd{-1};
    std::atomic<bool> recordSession{false}; // capture is gated by the transport (audio take in progress)
    std::atomic<uint32_t> recordTake{0};
    std::atomic<uint64_t> midiRecordDropped{0};
    SpscQueue<RecordedMidi, 4096> midiRecordQueue;
    std::atomic<int32_t> recordSlot{-1};    // a take into a launcher slot
    std::atomic<bool> recordCycle{false};   // the take loops the cycle

    // Live waveform (audio thread → control thread), drained into livePeaks (one list per spool channel).
    // On the heap: 384 KB would not fit an Engine built on a thread's stack.
    std::unique_ptr<SpscQueue<LivePeak, 32768>> livePeakQueue = std::make_unique<SpscQueue<LivePeak, 32768>>();
    std::vector<std::vector<float>> livePeaks;
    // Audio thread only.
    std::array<float, 64> rtPeakAcc{};
    int rtPeakFill = 0;
    uint32_t rtPeakIndex = 0;
    int64_t rtRecordNext = -1;
    bool rtRecordingBlock = false;
    int rtRecordOffset = 0, rtRecordCount = 0; // the part of this callback's block that belongs to the take
};

} // namespace dalnok
