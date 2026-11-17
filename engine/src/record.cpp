// Recording sessions: take files, journal, finalization, placement, and MIDI input.
// See ADR-0008. Control thread only, except where noted.
//
// Files for a take named "<Track> Take N" in the recording folder:
//   <name>.dlncap   capture spool (raw float32 after a 16-byte header; see capture_spool.hpp)
//   <name>.dlntake  journal (JSON): {"format":"dalnok-take","state":"recording"|"failed"|"recovered", ...}
//   <name>.wav      finished take (32-bit float), created from the spool by an atomic link
// A complete take keeps only the WAV. A failed take keeps the spool and journal and saves the
// valid prefix as "<name> (recovered).wav", which is never placed automatically.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "record.hpp"

#include "capture_recovery.hpp"
#include "capture_spool.hpp"
#include "midi.hpp"

#include <chrono>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <thread>
#include <unistd.h>

namespace fs = std::filesystem;

namespace dalnok {

namespace {
bool fail(std::string &err, const std::string &msg) {
    err = msg;
    return false;
}

std::string safeName(const std::string &name) {
    std::string out;
    for (char c : name) out += (c == '/' || c == ':' || c == '\0' || static_cast<unsigned char>(c) < 32) ? '-' : c;
    if (out.empty() || out[0] == '.') out = "Track" + out;
    return out.substr(0, 80);
}

bool readText(const std::string &path, std::string &out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

std::string recoveredPath(const std::string &journal) {
    fs::path p(journal);
    return (p.parent_path() / (p.stem().string() + " (recovered).wav")).string();
}

bool writeJournal(const std::string &path, const json::Value &j, std::string &err) {
    return writeFileDurably(path, json::serialize(j, true), err);
}
} // namespace

// ---- Sessions ---------------------------------------------------------------

int64_t Engine::recordLatency() const {
    return (duplex_ ? duplex_->roundTripLatency() : 0) + latencyOffset_;
}

bool Engine::startRecording(const std::string &inputUid, const std::string &directory, std::string &err) {
    if (recording_ || duplex_) return fail(err, "already recording");
    const TrackState *audio = nullptr, *midi = nullptr;
    for (const auto &t : model_.tracks) {
        if (!t.armed) continue;
        (t.kind == kTrackAudio ? audio : midi) = &t;
    }
    if (!audio && !midi) return fail(err, "arm a track to record");
    if (audio && inputUid.empty()) return fail(err, "choose an audio input device to record an audio track");

    recordAudioTrack_ = audio ? audio->id : 0;
    recordMidiTrack_ = midi ? midi->id : 0;
    recordSpool_.clear(); recordWav_.clear(); recordJournal_.clear();
    if (audio) {
        std::error_code ec;
        fs::create_directories(directory, ec);
        if (directory.empty() || !fs::is_directory(directory)) return fail(err, "cannot create recording folder " + directory);
        // Never reuse a name: every file of a take is created exclusively.
        const fs::path dir = fs::absolute(directory);
        std::string base;
        for (int n = 1; n < 10000; ++n) {
            base = (dir / (safeName(audio->name) + " Take " + std::to_string(n))).string();
            if (!fs::exists(base + ".wav") && !fs::exists(base + ".dlncap") && !fs::exists(base + ".dlntake") &&
                !fs::exists(base + " (recovered).wav"))
                break;
        }
        recordSpool_ = base + ".dlncap";
        recordWav_ = base + ".wav";
        recordJournal_ = base + ".dlntake";
        json::Value j = json::Value::makeObject();
        j.set("format", "dalnok-take");
        j.set("version", 1);
        j.set("state", "recording");
        j.set("spool", fs::path(recordSpool_).filename().string());
        j.set("wav", fs::path(recordWav_).filename().string());
        j.set("track", audio->id);
        j.set("trackName", audio->name);
        j.set("inputChannel", audio->inputChannel);
        j.set("sampleRate", sampleRate_);
        j.set("channels", 1);
        j.set("requestedStart", position());
        j.set("created", static_cast<int64_t>(std::time(nullptr)));
        if (!writeJournal(recordJournal_, j, err)) return false;
        if (!startCapture(inputUid, audio->inputChannel, recordSpool_, err)) {
            ::unlink(recordJournal_.c_str()); // nothing was captured; the spool was never created or is empty
            std::error_code ignored;
            if (fs::exists(recordSpool_) && fs::file_size(recordSpool_, ignored) <= 16) ::unlink(recordSpool_.c_str());
            return false;
        }
    }
    midiTake_.clear();
    RecordedMidi discard;
    while (midiRecordQueue_.pop(discard)) {}
    midiRecordDropped_.store(0, std::memory_order_relaxed);
    recordStart_.store(-1, std::memory_order_relaxed);
    recordEnd_.store(-1, std::memory_order_relaxed);
    recordBroken_.store(false, std::memory_order_relaxed);
    recordMidi_.store(midi != nullptr, std::memory_order_relaxed);
    recordTake_.fetch_add(1, std::memory_order_acq_rel);
    recordSession_.store(audio != nullptr, std::memory_order_release);
    recordArmed_.store(true, std::memory_order_release);
    recording_ = true;
    play();
    return true;
}

void Engine::drainRecordedMidi() {
    RecordedMidi e;
    while (midiRecordQueue_.pop(e)) midiTake_.push_back(e);
}

void Engine::waitForAudioCycles() {
    // The audio thread checks recordArmed_ once per cycle; two full cycles guarantee
    // that no in-flight cycle can still record after this returns.
    if (!device_ && !(duplex_ && !simulatedInput_)) return;
    const auto target = callbacks_.load(std::memory_order_acquire) + 2;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
    while (callbacks_.load(std::memory_order_acquire) < target && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
}

bool Engine::stopRecording(RecordResult &r, std::string &err) {
    r = RecordResult{};
    if (!recording_) return fail(err, "not recording");
    recordArmed_.store(false, std::memory_order_release);
    waitForAudioCycles();
    const bool broken = recordBroken_.load(std::memory_order_acquire);
    r.start = recordStart_.load(std::memory_order_acquire);
    const int64_t end = recordEnd_.load(std::memory_order_acquire);
    r.latency = recordAudioTrack_ ? recordLatency() : 0;
    std::vector<std::string> problems;
    if (broken) problems.push_back("the transport stopped or jumped during the take");
    if (midiRecordDropped_.load(std::memory_order_relaxed)) problems.push_back("MIDI events were dropped");

    // ---- Audio: stop capture, finalize, verify ----
    bool audioOK = true;
    std::shared_ptr<const Media> media;
    if (recordAudioTrack_) {
        std::string captureErr;
        const bool captureOK = stopCapture(r.stats, captureErr);
        recordSession_.store(false, std::memory_order_release);
        r.journal = recordJournal_;
        audioOK = captureOK && !broken && r.start >= 0;
        if (!captureOK) problems.push_back(captureErr);
        if (r.start < 0) problems.push_back("the transport never started, so nothing was recorded");
        uint64_t frames = 0;
        uint32_t trailing = 0;
        std::string convertErr;
        const std::string target = audioOK ? recordWav_ : recoveredPath(recordJournal_);
        const bool converted = r.stats.written_frames > 0 &&
                               recoverCapture(recordSpool_, target, frames, trailing, convertErr);
        if (converted) syncDirectory(fs::path(target).parent_path().string());
        if (audioOK && (!converted || frames != r.stats.written_frames || trailing != 0)) {
            audioOK = false;
            problems.push_back(converted ? "the finished file does not match the captured frame count"
                                         : "could not finalize the take: " + convertErr);
        }
        if (audioOK) {
            std::vector<std::vector<float>> ch;
            std::string decodeErr;
            if (decodeAudioFile(recordWav_, sampleRate_, ch, decodeErr) && !ch.empty() &&
                static_cast<uint64_t>(ch[0].size()) == frames)
                media = std::make_shared<const Media>(std::move(ch), sampleRate_);
            else {
                audioOK = false;
                problems.push_back("the finished take could not be read back");
            }
        }
        r.frames = converted ? frames : 0;
        r.path = converted ? target : "";
        // Journal: complete takes keep only the WAV; anything else keeps spool + journal.
        if (audioOK) {
            ::unlink(recordSpool_.c_str());
            ::unlink(recordJournal_.c_str());
            syncDirectory(fs::path(recordJournal_).parent_path().string());
            r.journal.clear();
        } else {
            r.recovered = converted;
            std::string text;
            json::Value j;
            std::string parseErr, writeErr;
            if (readText(recordJournal_, text) && json::parse(text, j, parseErr) && j.isObject()) {
                j.set("state", converted ? "recovered" : "failed");
                j.set("frames", static_cast<int64_t>(r.frames));
                j.set("start", r.start);
                if (converted) j.set("recoveredWav", fs::path(target).filename().string());
                std::string all;
                for (const auto &p : problems) all += (all.empty() ? "" : "; ") + p;
                j.set("error", all);
                writeJournal(recordJournal_, j, writeErr);
            }
        }
    }
    recordSession_.store(false, std::memory_order_release);
    pause();
    recording_ = false;
    drainRecordedMidi();
    recordMidi_.store(false, std::memory_order_relaxed);

    // ---- MIDI: pair note-on/off into notes ----
    std::vector<MidiNote> notes;
    if (recordMidiTrack_ && r.start >= 0 && end > r.start) {
        struct Held { int64_t at = -1; uint8_t velocity = 0; };
        Held held[16][128];
        for (const auto &e : midiTake_) {
            const uint8_t type = e.status & 0xf0, ch = e.status & 0x0f, pitch = e.data1 & 0x7f;
            Held &h = held[ch][pitch];
            const bool on = type == 0x90 && e.data2 > 0;
            if (h.at >= 0) { // a note-off, or a repeated note-on, ends the held note
                notes.push_back({h.at - r.start, std::max<int64_t>(1, e.pos - h.at), pitch, h.velocity});
                h.at = -1;
            }
            if (on) h = {e.pos, static_cast<uint8_t>(e.data2 & 0x7f)};
        }
        for (int c = 0; c < 16; ++c)
            for (int p = 0; p < 128; ++p)
                if (held[c][p].at >= 0)
                    notes.push_back({held[c][p].at - r.start, std::max<int64_t>(1, end - held[c][p].at),
                                     static_cast<uint8_t>(p), held[c][p].velocity});
    }
    midiTake_.clear();

    // ---- Placement: one undo step ----
    beginGroup("Record");
    std::string placeErr;
    if (media) {
        r.media = poolAdd(media, recordWav_);
        int64_t start = r.start - r.latency, offset = 0;
        if (start < 0) { offset = -start; start = 0; }
        if (offset < media->frames()) {
            r.audioClip = addClip(recordAudioTrack_, r.media, start, offset, media->frames() - offset, placeErr);
            if (!r.audioClip) problems.push_back("could not place the take: " + placeErr);
        }
    }
    if (!notes.empty()) {
        r.notes = static_cast<int32_t>(notes.size());
        r.midiClip = addMidiClip(recordMidiTrack_, r.start, end - r.start, placeErr, std::move(notes), "Record");
        if (!r.midiClip) problems.push_back("could not place the MIDI take: " + placeErr);
    }
    endGroup();

    err.clear();
    for (const auto &p : problems) err += (err.empty() ? "" : "; ") + p;
    if (!audioOK && recordAudioTrack_) {
        if (r.recovered) err += "; the valid part was saved to " + fs::path(r.path).filename().string();
        else if (r.stats.written_frames > 0) err += "; the capture spool was kept for manual recovery";
    }
    return problems.empty();
}

// ---- Recovery (any thread; no engine) -----------------------------------------

json::Value scanTakes(const std::string &directory) {
    json::Value list = json::Value::makeArray();
    std::error_code ec;
    for (fs::directory_iterator it(directory, ec), endIt; !ec && it != endIt; it.increment(ec)) {
        if (it->path().extension() != ".dlntake") continue;
        std::string text, err;
        json::Value j;
        if (!readText(it->path().string(), text) || !json::parse(text, j, err) || !j.isObject() ||
            j.getString("format", "") != "dalnok-take")
            continue;
        j.set("journal", it->path().string());
        list.push(std::move(j));
    }
    return list;
}

bool recoverTake(const std::string &journal, json::Value &out, std::string &err) {
    std::string text;
    if (!readText(journal, text) || !json::parse(text, out, err) || !out.isObject() ||
        out.getString("format", "") != "dalnok-take")
        return fail(err, "not a Dalnok take journal");
    const fs::path dir = fs::path(journal).parent_path();
    const std::string target = recoveredPath(journal);
    if (fs::exists(target)) { // repeated recovery: report the existing file, change nothing
        out.set("recoveredWav", fs::path(target).filename().string());
        out.set("path", target);
        return true;
    }
    const std::string spool = (dir / out.getString("spool", "")).string();
    uint64_t frames = 0;
    uint32_t trailing = 0;
    if (!recoverCapture(spool, target, frames, trailing, err)) return false;
    syncDirectory(dir.string());
    out.set("state", "recovered");
    out.set("frames", static_cast<int64_t>(frames));
    out.set("trailingBytes", static_cast<int64_t>(trailing));
    out.set("recoveredWav", fs::path(target).filename().string());
    std::string writeErr;
    json::Value stored = out;
    writeJournal(journal, stored, writeErr);
    out.set("path", target);
    return true;
}

// ---- MIDI input ---------------------------------------------------------------

bool Engine::openMidiInput(int32_t uniqueId, std::string &err) {
    for (int i = 1; i < kMidiInputs; ++i) {
        if (midiParsers_[static_cast<size_t>(i)]) continue;
        // Publish first: the receive thread and the audio thread both find the parser through the slot.
        auto &slot = midiInputs_[static_cast<size_t>(i)];
        midiParsers_[static_cast<size_t>(i)] = std::make_unique<MidiParser>();
        slot.store(midiParsers_[static_cast<size_t>(i)].get(), std::memory_order_release);
        if (connectMidiSource(midiClient_, uniqueId, &slot, err)) return true;
        // The audio thread may still hold the pointer for this cycle: keep the parser until the engine goes away.
        slot.store(nullptr, std::memory_order_release);
        retiredParsers_.push_back(std::move(midiParsers_[static_cast<size_t>(i)]));
        return false;
    }
    return fail(err, "too many MIDI inputs are open");
}

bool Engine::injectMidi(uint8_t status, uint8_t data1, uint8_t data2) {
    if (status < 0x80 || status >= 0xf0) return false;
    MidiParser &p = *midiParsers_[0];
    const uint64_t before = p.dropped();
    p.feed(status, 0);
    p.feed(data1 & 0x7f, 0);
    const uint8_t type = status & 0xf0;
    if (type != 0xc0 && type != 0xd0) p.feed(data2 & 0x7f, 0);
    return p.dropped() == before;
}

uint64_t Engine::midiDropped() const {
    uint64_t total = midiRecordDropped_.load(std::memory_order_relaxed);
    for (const auto &p : midiParsers_)
        if (p) total += p->dropped();
    return total;
}

} // namespace dalnok
