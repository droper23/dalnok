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

#include <algorithm>
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
    return (duplex_ ? duplex_->roundTripLatency() : 0) + rec_.latencyOffset;
}

bool Engine::startRecording(const std::string &inputUid, const std::string &directory, std::string &err) {
    if (rec_.active || rec_.captureWriter) return fail(err, "already recording");
    const TrackState *audio = nullptr, *midi = nullptr;
    std::vector<const TrackState *> audioTracks;
    for (const auto &t : model_.tracks) {
        if (!t.armed) continue;
        if (t.kind == kTrackAudio) { audioTracks.push_back(&t); if (!audio) audio = &t; }
        else midi = &t;
    }
    if (audioTracks.size() > 64) return fail(err, "too many armed audio tracks (64 at most)");
    if (!audio && !midi) return fail(err, "arm a track to record");
    if (audio && inputUid.empty()) return fail(err, "choose an audio input device to record an audio track");

    rec_.recordAudioTrack = audio ? audio->id : 0;
    rec_.recordMidiTrack = midi ? midi->id : 0;
    rec_.recordAudio.clear();
    rec_.recordSpool.clear(); rec_.recordWav.clear(); rec_.recordJournal.clear();
    if (audio) {
        std::error_code ec;
        fs::create_directories(directory, ec);
        if (directory.empty() || !fs::is_directory(directory)) return fail(err, "cannot create recording folder " + directory);
        // Never reuse a name: every file of a take is created exclusively.
        const fs::path dir = fs::absolute(directory);
        // One take number for every armed track: "<Track> Take N.wav" each, never reusing a name.
        // The spool and journal are named after the first track.
        std::string base;
        int take = 1;
        for (; take < 10000; ++take) {
            bool free = true;
            for (const auto *t : audioTracks) {
                const std::string b = (dir / (safeName(t->name) + " Take " + std::to_string(take))).string();
                free = free && !fs::exists(b + ".wav") && !fs::exists(b + ".dlncap") && !fs::exists(b + ".dlntake") &&
                       !fs::exists(b + " (recovered).wav");
            }
            if (free) break;
        }
        base = (dir / (safeName(audio->name) + " Take " + std::to_string(take))).string();
        for (const auto *t : audioTracks) {
            std::string wav = (dir / (safeName(t->name) + " Take " + std::to_string(take))).string() + ".wav";
            // Two armed tracks with the same name: keep their files apart.
            for (int k = 2; std::any_of(rec_.recordAudio.begin(), rec_.recordAudio.end(), [&](const RecordAudio &r) { return r.wav == wav; }); ++k)
                wav = (dir / (safeName(t->name) + " Take " + std::to_string(take) + " (" + std::to_string(k) + ")")).string() + ".wav";
            rec_.recordAudio.push_back({t->id, t->name, t->inputChannel, wav});
        }
        rec_.recordSpool = base + ".dlncap";
        rec_.recordWav = rec_.recordAudio.front().wav;
        rec_.recordJournal = base + ".dlntake";
        json::Value j = json::Value::makeObject();
        j.set("format", "dalnok-take");
        j.set("version", 1);
        j.set("state", "recording");
        j.set("spool", fs::path(rec_.recordSpool).filename().string());
        j.set("wav", fs::path(rec_.recordWav).filename().string());
        j.set("track", audio->id);
        j.set("trackName", audio->name);
        j.set("inputChannel", audio->inputChannel);
        j.set("sampleRate", sampleRate_);
        j.set("channels", static_cast<int64_t>(rec_.recordAudio.size()));
        json::Value tracks = json::Value::makeArray(); // spool channel i → tracks[i]
        for (const auto &r : rec_.recordAudio) {
            json::Value t = json::Value::makeObject();
            t.set("track", r.track);
            t.set("trackName", r.name);
            t.set("inputChannel", r.channel);
            t.set("wav", fs::path(r.wav).filename().string());
            tracks.push(std::move(t));
        }
        j.set("tracks", std::move(tracks));
        j.set("requestedStart", position());
        j.set("created", static_cast<int64_t>(std::time(nullptr)));
        if (!writeJournal(rec_.recordJournal, j, err)) return false;
        std::vector<int> channels;
        for (const auto &r : rec_.recordAudio) channels.push_back(r.channel);
        if (!startCapture(inputUid, channels, rec_.recordSpool, err)) {
            ::unlink(rec_.recordJournal.c_str()); // nothing was captured; the spool was never created or is empty
            std::error_code ignored;
            if (fs::exists(rec_.recordSpool) && fs::file_size(rec_.recordSpool, ignored) <= 16) ::unlink(rec_.recordSpool.c_str());
            return false;
        }
    }
    rec_.midiTake.clear();
    RecordedMidi discard;
    while (rec_.midiRecordQueue.pop(discard)) {}
    rec_.midiRecordDropped.store(0, std::memory_order_relaxed);
    rec_.recordStart.store(-1, std::memory_order_relaxed);
    rec_.recordEnd.store(-1, std::memory_order_relaxed);
    rec_.recordBroken.store(false, std::memory_order_relaxed);
    rec_.recordMidi.store(midi != nullptr, std::memory_order_relaxed);
    // With cycle on (and no punch), the take loops the cycle and becomes one take per pass.
    rec_.recordCycleStart = transport_.cycleStart.load();
    rec_.recordCycleEnd = transport_.cycleEnd.load();
    rec_.recordCycle.store(transport_.cycleOn.load() && transport_.punchIn.load() == INT64_MIN && rec_.recordCycleEnd - rec_.recordCycleStart >= 64,
                       std::memory_order_release);
    rec_.recordTake.fetch_add(1, std::memory_order_acq_rel);
    rec_.recordSession.store(audio != nullptr, std::memory_order_release);
    rec_.recordArmed.store(true, std::memory_order_release);
    rec_.active = true;
    play();
    return true;
}

void Engine::drainRecordedMidi() {
    RecordedMidi e;
    while (rec_.midiRecordQueue.pop(e)) rec_.midiTake.push_back(e);
}

void Engine::waitForAudioCycles() {
    // The audio thread checks rec_.recordArmed once per cycle; two full cycles guarantee
    // that no in-flight cycle can still record after this returns.
    if (!device_ && !(duplex_ && !simulatedInput_)) return;
    const auto target = callbacks_.load(std::memory_order_acquire) + 2;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
    while (callbacks_.load(std::memory_order_acquire) < target && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
}

bool Engine::stopRecording(RecordResult &r, std::string &err) {
    r = RecordResult{};
    if (!rec_.active) return fail(err, "not recording");
    rec_.recordArmed.store(false, std::memory_order_release);
    waitForAudioCycles();
    const bool broken = rec_.recordBroken.load(std::memory_order_acquire);
    r.start = rec_.recordStart.load(std::memory_order_acquire);
    const int64_t end = rec_.recordEnd.load(std::memory_order_acquire);
    r.latency = rec_.recordAudioTrack ? recordLatency() : 0;
    std::vector<std::string> problems;
    if (broken) problems.push_back("the transport stopped or jumped during the take");
    if (rec_.midiRecordDropped.load(std::memory_order_relaxed)) problems.push_back("MIDI events were dropped");

    // ---- Audio: stop capture, finalize, verify ----
    bool audioOK = true;
    std::shared_ptr<const Media> media;
    std::vector<std::shared_ptr<const Media>> takes; // one per armed audio track, in rec_.recordAudio order
    if (rec_.recordAudioTrack) {
        std::string captureErr;
        const bool captureOK = stopCapture(r.stats, captureErr);
        rec_.recordSession.store(false, std::memory_order_release);
        r.journal = rec_.recordJournal;
        audioOK = captureOK && !broken && r.start >= 0;
        if (!captureOK) problems.push_back(captureErr);
        if (r.start < 0)
            problems.push_back(transport_.punchIn.load() != INT64_MIN ? "playback never reached the punch-in point, so nothing was recorded"
                                                            : "the transport never started, so nothing was recorded");
        // One mono WAV per armed track (spool channel i → rec_.recordAudio[i]); each is verified independently.
        uint64_t frames = 0;
        uint32_t trailing = 0;
        bool converted = r.stats.written_frames > 0;
        for (size_t i = 0; i < rec_.recordAudio.size(); ++i) {
            std::string convertErr;
            const std::string target = audioOK ? rec_.recordAudio[i].wav : recoveredPath(rec_.recordAudio[i].wav);
            uint64_t f = 0;
            uint32_t t = 0;
            const bool ok = converted && recoverCapture(rec_.recordSpool, target, f, t, convertErr, static_cast<int>(i));
            if (ok) { rec_.recordAudio[i].wav = target; frames = f; trailing = t; }
            if (!ok) {
                converted = false;
                if (audioOK) problems.push_back("could not finalize the take: " + convertErr);
                audioOK = false;
                break;
            }
            if (audioOK && (f != r.stats.written_frames || t != 0)) {
                audioOK = false;
                problems.push_back("the finished file does not match the captured frame count");
            }
        }
        if (converted) syncDirectory(fs::path(rec_.recordAudio.front().wav).parent_path().string());
        for (size_t i = 0; audioOK && i < rec_.recordAudio.size(); ++i) {
            std::string decodeErr;
            auto take = Media::loadFile(rec_.recordAudio[i].wav, sampleRate_, decodeErr); // long takes stream (A-09)
            if (take && static_cast<uint64_t>(take->frames()) == frames)
                takes.push_back(std::move(take));
            else {
                audioOK = false;
                problems.push_back("the finished take could not be read back");
            }
        }
        if (audioOK) media = takes.front();
        const std::string target = rec_.recordAudio.front().wav;
        r.frames = converted ? frames : 0;
        r.path = converted ? target : "";
        // Journal: complete takes keep only the WAV; anything else keeps spool + journal.
        if (audioOK) {
            ::unlink(rec_.recordSpool.c_str());
            ::unlink(rec_.recordJournal.c_str());
            syncDirectory(fs::path(rec_.recordJournal).parent_path().string());
            r.journal.clear();
        } else {
            r.recovered = converted;
            std::string text;
            json::Value j;
            std::string parseErr, writeErr;
            if (readText(rec_.recordJournal, text) && json::parse(text, j, parseErr) && j.isObject()) {
                j.set("state", converted ? "recovered" : "failed");
                j.set("frames", static_cast<int64_t>(r.frames));
                j.set("start", r.start);
                if (converted) j.set("recoveredWav", fs::path(target).filename().string());
                if (converted)
                    if (json::Value *tracks = j.get("tracks"); tracks && tracks->isArray())
                        for (size_t i = 0; i < tracks->array.size() && i < rec_.recordAudio.size(); ++i)
                            tracks->array[i].set("recoveredWav", fs::path(rec_.recordAudio[i].wav).filename().string());
                std::string all;
                for (const auto &p : problems) all += (all.empty() ? "" : "; ") + p;
                j.set("error", all);
                writeJournal(rec_.recordJournal, j, writeErr);
            }
        }
    }
    rec_.recordSession.store(false, std::memory_order_release);
    pause();
    rec_.active = false;
    drainRecordedMidi();
    rec_.recordMidi.store(false, std::memory_order_relaxed);

    // ---- MIDI: pair note-on/off into notes ----
    std::vector<MidiNote> notes;
    if (rec_.recordMidiTrack && r.start >= 0 && end > r.start) {
        struct Held { int64_t at = -1; uint8_t velocity = 0; };
        Held held[16][128];
        for (const auto &e : rec_.midiTake) {
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
    rec_.midiTake.clear();

    // ---- Placement: one undo step ----
    beginGroup("Record");
    std::string placeErr;
    // Cycle take: cut the capture at every wrap. Pass 0 runs from where recording began to the cycle end;
    // every later pass starts at the cycle start. Each pass is a take; each track's takes form a take folder.
    struct Pass { int64_t start, offset, length; };
    std::vector<Pass> passes;
    if (media && rec_.recordCycle.load()) {
        const int64_t total = media->frames(), cs = rec_.recordCycleStart, ce = rec_.recordCycleEnd;
        int64_t pos = r.start, offset = 0;
        while (offset < total) {
            const int64_t len = pos < ce ? std::min(ce - pos, total - offset) : total - offset;
            passes.push_back({pos, offset, len});
            offset += len;
            pos = cs;
        }
    }
    rec_.recordCycle.store(false, std::memory_order_release);
    if (passes.empty()) passes.push_back({r.start, 0, media ? media->frames() : 0});
    for (size_t i = 0; media && i < takes.size(); ++i) {
        const DalnokMediaId id = poolAdd(takes[i], rec_.recordAudio[i].wav);
        if (i == 0) r.media = id;
        std::vector<DalnokClipId> trackTakes;
        for (const auto &p : passes) {
            int64_t start = p.start - r.latency, offset = p.offset;
            if (start < 0) { offset -= start; start = 0; }
            const int64_t length = p.offset + p.length - offset;
            if (length <= 0 || offset >= takes[i]->frames()) continue;
            const DalnokClipId clip = addClip(rec_.recordAudio[i].track, id, start, offset, length, placeErr);
            if (!clip) problems.push_back("could not place the take on " + rec_.recordAudio[i].name + ": " + placeErr);
            else trackTakes.push_back(clip);
        }
        if (rec_.recordSlot.load() >= 0 && !trackTakes.empty()) { // into the launcher, not the arrangement
            const DalnokClipId clip = takeToSlot(trackTakes, rec_.recordSlot.load(), placeErr);
            if (!clip) problems.push_back("could not put the take in the launcher slot: " + placeErr);
            trackTakes = clip ? std::vector<DalnokClipId>{clip} : std::vector<DalnokClipId>{};
        } else if (trackTakes.size() > 1) {
            const int32_t folder = addTakeFolder(rec_.recordAudio[i].track, trackTakes, placeErr);
            if (!folder) problems.push_back("could not make the take folder: " + placeErr);
            r.takeFolders.push_back(folder);
            // The comp's first piece stands for the track's take in the result.
            for (const auto &c : model_.clips)
                if (c.folder == folder && !c.alt) { trackTakes = {c.id}; break; }
        }
        if (!trackTakes.empty()) {
            if (i == 0) r.audioClip = trackTakes.front();
            r.audioClips.push_back(trackTakes.front());
        }
    }
    if (!notes.empty()) {
        r.notes = static_cast<int32_t>(notes.size());
        r.midiClip = addMidiClip(rec_.recordMidiTrack, r.start, end - r.start, placeErr, std::move(notes), "Record");
        if (!r.midiClip) problems.push_back("could not place the MIDI take: " + placeErr);
        else if (rec_.recordSlot.load() >= 0) {
            r.midiClip = takeToSlot({r.midiClip}, rec_.recordSlot.load(), placeErr);
            if (!r.midiClip) problems.push_back("could not put the MIDI take in the launcher slot: " + placeErr);
        }
    }
    endGroup();

    err.clear();
    for (const auto &p : problems) err += (err.empty() ? "" : "; ") + p;
    if (!audioOK && rec_.recordAudioTrack) {
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
    const std::string spool = (dir / out.getString("spool", "")).string();
    uint64_t frames = 0;
    uint32_t trailing = 0;
    json::Value *tracks = out.get("tracks");
    if (tracks && tracks->isArray() && tracks->array.size() > 1) {
        // Multi-track take: one "<take> (recovered).wav" per track from its spool channel.
        for (size_t i = 0; i < tracks->array.size(); ++i) {
            const std::string wav = tracks->array[i].getString("wav", "");
            if (wav.empty()) return fail(err, "take journal lists a track without a file name");
            const std::string each = recoveredPath((dir / wav).string());
            if (!fs::exists(each) && !recoverCapture(spool, each, frames, trailing, err, static_cast<int>(i))) return false;
            tracks->array[i].set("recoveredWav", fs::path(each).filename().string());
            if (i == 0) out.set("recoveredWav", fs::path(each).filename().string());
        }
        syncDirectory(dir.string());
        out.set("state", "recovered");
        out.set("frames", static_cast<int64_t>(frames));
        out.set("trailingBytes", static_cast<int64_t>(trailing));
        std::string writeErr;
        json::Value stored = out;
        writeJournal(journal, stored, writeErr);
        out.set("path", recoveredPath((dir / tracks->array[0].getString("wav", "")).string()));
        return true;
    }
    if (fs::exists(target)) { // repeated recovery: report the existing file, change nothing
        out.set("recoveredWav", fs::path(target).filename().string());
        out.set("path", target);
        return true;
    }
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
    uint64_t total = rec_.midiRecordDropped.load(std::memory_order_relaxed);
    for (const auto &p : midiParsers_)
        if (p) total += p->dropped();
    return total;
}

} // namespace dalnok
