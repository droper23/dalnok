// Helpers shared by the Engine's translation units (engine*.cpp). Not part of any interface.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "engine.hpp"
#include "rt.hpp"

#include <atomic>
#include <cstdint>
#include <ctime>

namespace dalnok::detail {

inline constexpr double kTransportFadeSeconds = 0.005; // de-click ramp for play/pause/seek

// clock_gettime_nsec_np reads the commpage (no syscall, no locks) but is not
// annotated by the SDK, so the effect check is suppressed for this call only.
inline uint64_t nowNs() DALNOK_NONBLOCKING {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#pragma clang diagnostic pop
}

inline void atomicMax(std::atomic<uint64_t> &a, uint64_t v) DALNOK_NONBLOCKING {
    auto cur = a.load(std::memory_order_relaxed);
    while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {}
}


// Denormals are dramatically slower than normal floats on some CPUs and the DSP never needs their
// precision (audit A-12). Flush-to-zero is set while rendering and the caller's mode is restored.
#if defined(__aarch64__)
constexpr uint64_t kFpcrFlushZero = 1ull << 24; // FPCR.FZ
inline uint64_t readFpcr() DALNOK_NONBLOCKING { uint64_t v; __asm__ __volatile__("mrs %0, fpcr" : "=r"(v)); return v; }
inline void writeFpcr(uint64_t v) DALNOK_NONBLOCKING { __asm__ __volatile__("msr fpcr, %0" : : "r"(v)); }
#elif defined(__x86_64__)
constexpr uint32_t kMxcsrFtz = 1u << 15, kMxcsrDaz = 1u << 6;
inline uint32_t readMxcsr() DALNOK_NONBLOCKING { uint32_t v; __asm__ __volatile__("stmxcsr %0" : "=m"(v)); return v; }
inline void writeMxcsr(uint32_t v) DALNOK_NONBLOCKING { __asm__ __volatile__("ldmxcsr %0" : : "m"(v)); }
#endif

struct FlushDenormals {
#if defined(__aarch64__)
    uint64_t saved = readFpcr();
    FlushDenormals() DALNOK_NONBLOCKING { writeFpcr(saved | kFpcrFlushZero); }
    ~FlushDenormals() DALNOK_NONBLOCKING { writeFpcr(saved); }
#elif defined(__x86_64__)
    uint32_t saved = readMxcsr();
    FlushDenormals() DALNOK_NONBLOCKING { writeMxcsr(saved | kMxcsrFtz | kMxcsrDaz); }
    ~FlushDenormals() DALNOK_NONBLOCKING { writeMxcsr(saved); }
#endif
};


// Shared edit helpers (engine.cpp).
bool fail(std::string &err, const char *msg);
std::string stem(const std::string &path);
bool remapMidi(Model &m, const TempoMap &from, const TempoMap &to, std::string &err);
NoteList sortedNotes(std::vector<MidiNote> notes);
bool feedsBack(const Model &m, DalnokTrackId from, DalnokTrackId to);
bool realizeComp(Model &m, const TakeFolder &f, DalnokClipId &nextClip, std::string &err);

} // namespace dalnok::detail

namespace dalnok {
// Runs `fn` against the model; on success records an undo step and publishes. Defined here because every
// engine*.cpp file makes edits.
template <typename F>
bool Engine::edit(const char *name, bool structural, F &&fn) {
    Model before = model_;
    if (!fn(model_)) {
        model_ = std::move(before);
        return false;
    }
    const auto changed = changedTracks(before);
    history_.recordSnapshot(name, std::move(before));
    ++revision_;
    stampTracks(changed);
    syncRuntimes();
    if (structural) commit();
    return true;
}

} // namespace dalnok
