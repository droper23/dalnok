// SPDX-License-Identifier: GPL-3.0-or-later
#include "zip.hpp"

#include <zlib.h>

#include <cstring>
#include <limits>

namespace dalnok::zip {
namespace {
void put16(std::string &b, uint32_t v) { b.push_back(char(v & 0xff)); b.push_back(char((v >> 8) & 0xff)); }
void put32(std::string &b, uint32_t v) { put16(b, v & 0xffff); put16(b, v >> 16); }
uint32_t get16(const unsigned char *p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8; }
uint32_t get32(const unsigned char *p) { return get16(p) | get16(p + 2) << 16; }
constexpr uint32_t kMax = std::numeric_limits<uint32_t>::max();
} // namespace

Writer::~Writer() { if (f_) std::fclose(f_); }

bool Writer::open(const std::string &path, std::string &err) {
    f_ = std::fopen(path.c_str(), "wb");
    if (!f_) { err = "cannot write " + path; return false; }
    return true;
}

bool Writer::header(const std::string &name, uint32_t crc, uint32_t size, std::string &err) {
    const long at = std::ftell(f_);
    if (at < 0 || static_cast<unsigned long>(at) > kMax) { err = "archive larger than 4 GB"; return false; }
    std::string h;
    put32(h, 0x04034b50); put16(h, 20); put16(h, 0x0800 /* UTF-8 names */); put16(h, 0 /* stored */);
    put16(h, 0); put16(h, 0x21); // time, date (1980-01-01)
    put32(h, crc); put32(h, size); put32(h, size);
    put16(h, static_cast<uint32_t>(name.size())); put16(h, 0);
    h += name;
    if (std::fwrite(h.data(), 1, h.size(), f_) != h.size()) { err = "write failed"; return false; }
    entries_.push_back({name, crc, size, static_cast<uint32_t>(at)});
    return true;
}

bool Writer::add(const std::string &name, const std::string &data, std::string &err) {
    if (data.size() > kMax) { err = name + " is larger than 4 GB"; return false; }
    const uint32_t crc = static_cast<uint32_t>(crc32(0, reinterpret_cast<const Bytef *>(data.data()), static_cast<uInt>(data.size())));
    if (!header(name, crc, static_cast<uint32_t>(data.size()), err)) return false;
    if (std::fwrite(data.data(), 1, data.size(), f_) != data.size()) { err = "write failed"; return false; }
    return true;
}

bool Writer::addFile(const std::string &name, const std::string &source, std::string &err) {
    std::FILE *in = std::fopen(source.c_str(), "rb");
    if (!in) { err = "cannot read " + source; return false; }
    std::vector<unsigned char> buf(1 << 16);
    uLong crc = crc32(0, nullptr, 0);
    uint64_t size = 0;
    for (size_t n; (n = std::fread(buf.data(), 1, buf.size(), in)) > 0;) { crc = crc32(crc, buf.data(), static_cast<uInt>(n)); size += n; }
    if (size > kMax) { std::fclose(in); err = source + " is larger than 4 GB"; return false; }
    bool ok = header(name, static_cast<uint32_t>(crc), static_cast<uint32_t>(size), err);
    std::rewind(in);
    for (size_t n; ok && (n = std::fread(buf.data(), 1, buf.size(), in)) > 0;)
        if (std::fwrite(buf.data(), 1, n, f_) != n) { err = "write failed"; ok = false; }
    std::fclose(in);
    return ok;
}

bool Writer::close(std::string &err) {
    if (!f_) return true;
    const long dirAt = std::ftell(f_);
    std::string d;
    for (const auto &e : entries_) {
        put32(d, 0x02014b50); put16(d, 20); put16(d, 20); put16(d, 0x0800); put16(d, 0);
        put16(d, 0); put16(d, 0x21);
        put32(d, e.crc); put32(d, e.size); put32(d, e.size);
        put16(d, static_cast<uint32_t>(e.name.size())); put16(d, 0); put16(d, 0); put16(d, 0); put16(d, 0);
        put32(d, 0); put32(d, e.offset);
        d += e.name;
    }
    put32(d, 0x06054b50); put16(d, 0); put16(d, 0);
    put16(d, static_cast<uint32_t>(entries_.size())); put16(d, static_cast<uint32_t>(entries_.size()));
    put32(d, static_cast<uint32_t>(d.size() - 0)); // patched below
    put32(d, static_cast<uint32_t>(dirAt)); put16(d, 0);
    const uint32_t dirSize = static_cast<uint32_t>(d.size() - 22);
    std::memcpy(&d[d.size() - 10], &dirSize, 4); // little-endian hosts only (macOS arm64/x86-64)
    const bool ok = std::fwrite(d.data(), 1, d.size(), f_) == d.size();
    const bool closed = std::fclose(f_) == 0;
    f_ = nullptr;
    if (!ok || !closed) { err = "write failed"; return false; }
    return true;
}

Reader::~Reader() { if (f_) std::fclose(f_); }

bool Reader::open(const std::string &path, std::string &err) {
    f_ = std::fopen(path.c_str(), "rb");
    if (!f_) { err = "cannot open " + path; return false; }
    std::fseek(f_, 0, SEEK_END);
    const long size = std::ftell(f_);
    const long tail = std::min<long>(size, 65557);
    std::vector<unsigned char> b(static_cast<size_t>(tail));
    std::fseek(f_, size - tail, SEEK_SET);
    if (std::fread(b.data(), 1, b.size(), f_) != b.size()) { err = "not a ZIP archive"; return false; }
    long eocd = -1;
    for (long i = tail - 22; i >= 0; --i) if (get32(&b[size_t(i)]) == 0x06054b50) { eocd = i; break; }
    if (eocd < 0) { err = "not a ZIP archive (no end of central directory)"; return false; }
    const uint32_t count = get16(&b[size_t(eocd) + 10]), dirSize = get32(&b[size_t(eocd) + 12]), dirAt = get32(&b[size_t(eocd) + 16]);
    std::vector<unsigned char> dir(dirSize);
    std::fseek(f_, dirAt, SEEK_SET);
    if (std::fread(dir.data(), 1, dir.size(), f_) != dir.size()) { err = "damaged ZIP directory"; return false; }
    size_t p = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (p + 46 > dir.size() || get32(&dir[p]) != 0x02014b50) { err = "damaged ZIP directory"; return false; }
        Entry e;
        e.method = get16(&dir[p + 10]);
        e.compressed = get32(&dir[p + 20]);
        e.size = get32(&dir[p + 24]);
        const uint32_t n = get16(&dir[p + 28]), extra = get16(&dir[p + 30]), comment = get16(&dir[p + 32]);
        e.offset = get32(&dir[p + 42]);
        if (p + 46 + n > dir.size()) { err = "damaged ZIP directory"; return false; }
        e.name.assign(reinterpret_cast<const char *>(&dir[p + 46]), n);
        entries_.push_back(std::move(e));
        p += 46 + n + extra + comment;
    }
    return true;
}

const Entry *Reader::find(const std::string &name) const {
    for (const auto &e : entries_) if (e.name == name) return &e;
    return nullptr;
}

bool Reader::read(const Entry &e, std::string &out, std::string &err) {
    unsigned char h[30];
    std::fseek(f_, e.offset, SEEK_SET);
    if (std::fread(h, 1, 30, f_) != 30 || get32(h) != 0x04034b50) { err = "damaged entry " + e.name; return false; }
    std::fseek(f_, long(e.offset) + 30 + long(get16(h + 26)) + long(get16(h + 28)), SEEK_SET);
    std::string raw(e.compressed, '\0');
    if (e.compressed && std::fread(raw.data(), 1, raw.size(), f_) != raw.size()) { err = "truncated entry " + e.name; return false; }
    if (e.method == 0) { out = std::move(raw); return true; }
    if (e.method != 8) { err = e.name + ": unsupported compression method " + std::to_string(e.method); return false; }
    out.assign(e.size, '\0');
    z_stream z{};
    if (inflateInit2(&z, -MAX_WBITS) != Z_OK) { err = "inflate failed"; return false; }
    z.next_in = reinterpret_cast<Bytef *>(raw.data()); z.avail_in = static_cast<uInt>(raw.size());
    z.next_out = reinterpret_cast<Bytef *>(out.data()); z.avail_out = static_cast<uInt>(out.size());
    const int r = inflate(&z, Z_FINISH);
    inflateEnd(&z);
    if (r != Z_STREAM_END || z.total_out != e.size) { err = e.name + ": damaged compressed data"; return false; }
    return true;
}

bool Reader::extract(const Entry &e, const std::string &toPath, std::string &err) {
    std::string data;
    if (!read(e, data, err)) return false;
    std::FILE *o = std::fopen(toPath.c_str(), "wb");
    if (!o) { err = "cannot write " + toPath; return false; }
    const bool ok = std::fwrite(data.data(), 1, data.size(), o) == data.size();
    if (std::fclose(o) != 0 || !ok) { err = "cannot write " + toPath; return false; }
    return true;
}

} // namespace dalnok::zip
