// Minimal ZIP container support for DAWproject files: writing stored (uncompressed) entries, reading stored and
// deflated entries through the central directory. No ZIP64, encryption or multi-disk archives.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace dalnok::zip {

class Writer {
public:
    ~Writer();
    bool open(const std::string &path, std::string &err);
    bool add(const std::string &name, const std::string &data, std::string &err);
    bool addFile(const std::string &name, const std::string &sourcePath, std::string &err); // streamed copy
    bool close(std::string &err); // writes the central directory
private:
    struct Entry { std::string name; uint32_t crc = 0, size = 0, offset = 0; };
    bool header(const std::string &name, uint32_t crc, uint32_t size, std::string &err);
    std::FILE *f_ = nullptr;
    std::vector<Entry> entries_;
};

struct Entry { std::string name; uint32_t method = 0, compressed = 0, size = 0, offset = 0; };

class Reader {
public:
    ~Reader();
    bool open(const std::string &path, std::string &err);
    const std::vector<Entry> &entries() const { return entries_; }
    const Entry *find(const std::string &name) const;
    bool read(const Entry &e, std::string &out, std::string &err);
    bool extract(const Entry &e, const std::string &toPath, std::string &err);
private:
    std::FILE *f_ = nullptr;
    std::vector<Entry> entries_;
};

} // namespace dalnok::zip
