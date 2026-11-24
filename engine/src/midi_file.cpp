// Standard MIDI File reader and writer (see midi_file.hpp). Written from the SMF 1.0 specification.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "midi_file.hpp"

#include <algorithm>
#include <array>
#include <cmath>

namespace dalnok {
namespace {
constexpr size_t kMaxEvents = 2'000'000; // per file: a guard against hostile files, far beyond real songs

struct Reader {
    const std::string &b;
    size_t pos, end;
    bool ok = true;
    uint8_t u8() { if (pos >= end) { ok = false; return 0; } return static_cast<uint8_t>(b[pos++]); }
    uint32_t be(int n) { uint32_t v = 0; for (int i = 0; i < n; ++i) v = v << 8 | u8(); return v; }
    uint32_t vlq() { // variable-length quantity, at most 4 bytes
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) { const uint8_t c = u8(); v = v << 7 | (c & 0x7f); if (!(c & 0x80)) return v; }
        ok = false;
        return 0;
    }
    void skip(uint32_t n) { if (n > end - pos) { ok = false; pos = end; } else pos += n; }
};
} // namespace

bool parseMidiFile(const std::string &bytes, SmfFile &out, std::string &err) {
    out = SmfFile{};
    Reader r{bytes, 0, bytes.size()};
    if (bytes.size() < 14 || bytes.compare(0, 4, "MThd") != 0) { err = "not a MIDI file (no MThd header)"; return false; }
    r.pos = 4;
    const uint32_t hlen = r.be(4);
    if (hlen < 6 || hlen > bytes.size() - 8) { err = "damaged MIDI file header"; return false; }
    const uint32_t format = r.be(2), ntrks = r.be(2), division = r.be(2);
    r.pos = 8 + hlen;
    if (format > 1) { err = "MIDI file format 2 (independent patterns) is not supported"; return false; }
    if (division & 0x8000) { err = "MIDI files timed in SMPTE frames are not supported"; return false; }
    if (division == 0) { err = "damaged MIDI file (zero ticks per quarter note)"; return false; }
    const double ppq = division;
    size_t events = 0;
    struct Held { int64_t tick = -1; uint8_t velocity = 0; };
    for (uint32_t t = 0; t < ntrks && r.pos + 8 <= bytes.size(); ++t) {
        if (bytes.compare(r.pos, 4, "MTrk") != 0) { // an unknown chunk: skip it
            r.pos += 4;
            r.skip(r.be(4));
            if (!r.ok) break;
            --t;
            continue;
        }
        r.pos += 4;
        const uint32_t len = r.be(4);
        if (!r.ok || len > bytes.size() - r.pos) { err = "damaged MIDI track (length past the end of the file)"; return false; }
        Reader tr{bytes, r.pos, r.pos + len};
        r.pos += len;
        SmfTrack track;
        std::array<std::array<Held, 128>, 16> held{};
        int64_t tick = 0;
        uint8_t running = 0;
        while (tr.ok && tr.pos < tr.end) {
            if (++events > kMaxEvents) { err = "the MIDI file has too many events"; return false; }
            tick += tr.vlq();
            if (tick > (int64_t(1) << 40)) { err = "damaged MIDI file (event too late)"; return false; }
            uint8_t status = tr.u8();
            if (status == 0xff) { // meta
                const uint8_t type = tr.u8();
                const uint32_t n = tr.vlq();
                if (!tr.ok || n > tr.end - tr.pos) break;
                if (type == 0x2f) break; // end of track
                if (type == 0x03 && track.name.empty()) track.name.assign(bytes, tr.pos, std::min<uint32_t>(n, 128));
                if (type == 0x51 && n == 3) {
                    const uint32_t us = static_cast<uint32_t>(static_cast<uint8_t>(bytes[tr.pos])) << 16 |
                                        static_cast<uint32_t>(static_cast<uint8_t>(bytes[tr.pos + 1])) << 8 |
                                        static_cast<uint8_t>(bytes[tr.pos + 2]);
                    // Microseconds per beat round a tempo like 90 to 89.99996: read to 0.001 BPM.
                    if (us > 0) out.tempo.push_back({static_cast<double>(tick) / ppq, std::clamp(std::round(60e9 / us) / 1000, 10.0, 999.0)});
                }
                if (type == 0x58 && n >= 2 && tick == 0) {
                    out.meterNum = std::clamp<int32_t>(static_cast<uint8_t>(bytes[tr.pos]), 1, 32);
                    const int p = static_cast<uint8_t>(bytes[tr.pos + 1]);
                    out.meterDen = p <= 5 ? 1 << p : 4;
                }
                tr.skip(n);
                continue;
            }
            if (status == 0xf0 || status == 0xf7) { tr.skip(tr.vlq()); running = 0; continue; } // SysEx
            if (status < 0x80) { // running status: this byte is the first data byte
                if (!running) { err = "damaged MIDI track (data without a status)"; return false; }
                --tr.pos;
                status = running;
            } else if (status >= 0xf0) { // other system messages: no data in a file
                continue;
            } else {
                running = status;
            }
            const uint8_t type = status & 0xf0, ch = status & 0x0f;
            const uint8_t d1 = tr.u8() & 0x7f;
            const uint8_t d2 = (type == 0xc0 || type == 0xd0) ? 0 : tr.u8() & 0x7f;
            if (!tr.ok) break;
            const double beat = static_cast<double>(tick) / ppq;
            if (type == 0x90 || type == 0x80) {
                Held &h = held[ch][d1];
                if (h.tick >= 0) { // a note-off, or a repeated note-on, ends the held note
                    track.notes.push_back({static_cast<double>(h.tick) / ppq, std::max(1.0, static_cast<double>(tick - h.tick)) / ppq, d1, h.velocity, ch});
                    h.tick = -1;
                }
                if (type == 0x90 && d2 > 0) h = {tick, d2};
            } else if (type == 0xb0) {
                track.controllers.push_back({beat, d1, d2});
            } else if (type == 0xe0) {
                track.controllers.push_back({beat, 128, static_cast<uint16_t>(d1 | d2 << 7)});
            }
            out.lengthBeats = std::max(out.lengthBeats, beat);
        }
        for (int c = 0; c < 16; ++c) // notes never released end with the track
            for (int p = 0; p < 128; ++p)
                if (held[c][p].tick >= 0)
                    track.notes.push_back({static_cast<double>(held[c][p].tick) / ppq,
                                           std::max(1.0, static_cast<double>(tick - held[c][p].tick)) / ppq, static_cast<uint8_t>(p),
                                           held[c][p].velocity, static_cast<uint8_t>(c)});
        for (const auto &n : track.notes) out.lengthBeats = std::max(out.lengthBeats, n.beat + n.length);
        if (!track.notes.empty() || !track.controllers.empty()) out.tracks.push_back(std::move(track));
    }
    std::sort(out.tempo.begin(), out.tempo.end(), [](const SmfTempo &a, const SmfTempo &b) { return a.beat < b.beat; });
    if (out.tracks.empty()) { err = "the MIDI file has no notes"; return false; }
    return true;
}

std::string writeMidiFile(const SmfTrack &track, const std::vector<SmfTempo> &tempo, int32_t meterNum, int32_t meterDen) {
    constexpr double ppq = 960;
    auto put = [](std::string &s, uint32_t v, int n) { for (int i = n - 1; i >= 0; --i) s.push_back(static_cast<char>((v >> (8 * i)) & 0xff)); };
    auto vlq = [](std::string &s, uint32_t v) {
        char buf[5]; int n = 0;
        buf[n++] = static_cast<char>(v & 0x7f);
        while (v >>= 7) buf[n++] = static_cast<char>((v & 0x7f) | 0x80);
        while (n) s.push_back(buf[--n]);
    };
    struct Ev { uint32_t tick; int order; std::string bytes; };
    auto chunk = [&](std::vector<Ev> evs) {
        std::stable_sort(evs.begin(), evs.end(), [](const Ev &a, const Ev &b) { return a.tick != b.tick ? a.tick < b.tick : a.order < b.order; });
        std::string body;
        uint32_t last = 0;
        for (const auto &e : evs) { vlq(body, e.tick - last); last = e.tick; body += e.bytes; }
        vlq(body, 0); body += "\xff\x2f";
        body.push_back('\0');
        std::string c = "MTrk";
        put(c, static_cast<uint32_t>(body.size()), 4);
        return c + body;
    };
    auto ticks = [&](double beat) { return static_cast<uint32_t>(std::llround(std::max(0.0, beat) * ppq)); };
    std::vector<Ev> meta;
    int den = 0;
    while ((1 << den) < meterDen && den < 6) ++den;
    meta.push_back({0, 0, std::string("\xff\x58\x04", 3) + char(meterNum) + char(den) + char(24) + char(8)});
    for (const auto &t : tempo) {
        const uint32_t us = static_cast<uint32_t>(std::llround(60e6 / t.bpm));
        std::string m("\xff\x51\x03", 3);
        put(m, us, 3);
        meta.push_back({ticks(t.beat), 1, m});
    }
    std::vector<Ev> evs;
    if (!track.name.empty()) evs.push_back({0, 0, std::string("\xff\x03", 2) + char(std::min<size_t>(track.name.size(), 127)) + track.name.substr(0, 127)});
    for (const auto &c : track.controllers) {
        std::string m;
        if (c.controller == 128) { m.push_back('\xe0'); m.push_back(char(c.value & 0x7f)); m.push_back(char((c.value >> 7) & 0x7f)); }
        else { m.push_back('\xb0'); m.push_back(char(c.controller & 0x7f)); m.push_back(char(std::min<int>(c.value, 127))); }
        evs.push_back({ticks(c.beat), 1, m});
    }
    for (const auto &n : track.notes) {
        evs.push_back({ticks(n.beat + n.length), 0, std::string{'\x80', char(n.pitch & 0x7f), '\0'}}); // offs before ons
        evs.push_back({ticks(n.beat), 2, std::string{'\x90', char(n.pitch & 0x7f), char(std::max<int>(1, n.velocity & 0x7f))}});
    }
    std::string out = "MThd";
    put(out, 6, 4); put(out, 1, 2); put(out, 2, 2); put(out, static_cast<uint32_t>(ppq), 2);
    return out + chunk(meta) + chunk(evs);
}

} // namespace dalnok
