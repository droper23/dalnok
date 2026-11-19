// libFuzzer target for every untrusted document parser (audit A-10): the Dalnok project reader and the
// REAPER, Ableton, Logic, FCPXML and DAWproject importers. Built and run by scripts/ci/fuzz.sh.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The first input byte picks the format; the rest becomes the file. Container formats are wrapped here so the
// fuzzer explores the parser behind them instead of fighting checksums: .als is gzipped, the DAWproject
// variant is stored in a valid zip, and the Logic variant becomes a package's ProjectData. One variant feeds
// raw bytes to the zip reader itself. Plug-ins are never loaded (recovery-mode apply), so fuzzed paths
// cannot run plug-in code.
#include "dalnok/dalnok.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>
#include <zlib.h>

namespace fs = std::filesystem;

namespace {
const fs::path &workDir() {
    static const fs::path dir = [] {
        fs::path d = fs::temp_directory_path() / ("dalnok-fuzz-" + std::to_string(::getpid()));
        fs::create_directories(d);
        return d;
    }();
    return dir;
}

void writeFile(const fs::path &p, const std::string &bytes) {
    std::ofstream out(p, std::ios::binary | std::ios::trunc);
    out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

std::string gzip(const std::string &in) {
    z_stream z{};
    deflateInit2(&z, Z_BEST_SPEED, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
    std::string out(deflateBound(&z, in.size()) + 32, '\0');
    z.next_in = reinterpret_cast<Bytef *>(const_cast<char *>(in.data()));
    z.avail_in = static_cast<uInt>(in.size());
    z.next_out = reinterpret_cast<Bytef *>(out.data());
    z.avail_out = static_cast<uInt>(out.size());
    deflate(&z, Z_FINISH);
    out.resize(z.total_out);
    deflateEnd(&z);
    return out;
}

void put16(std::string &s, uint32_t v) { s.push_back(char(v & 0xff)); s.push_back(char((v >> 8) & 0xff)); }
void put32(std::string &s, uint32_t v) { put16(s, v & 0xffff); put16(s, v >> 16); }

// A one-entry stored (uncompressed) zip archive.
std::string storedZip(const std::string &name, const std::string &data) {
    const uint32_t crc = static_cast<uint32_t>(crc32(0, reinterpret_cast<const Bytef *>(data.data()), static_cast<uInt>(data.size())));
    const uint32_t size = static_cast<uint32_t>(data.size());
    std::string z;
    put32(z, 0x04034b50); put16(z, 20); put16(z, 0); put16(z, 0); put16(z, 0); put16(z, 0);
    put32(z, crc); put32(z, size); put32(z, size); put16(z, static_cast<uint32_t>(name.size())); put16(z, 0);
    z += name;
    z += data;
    const uint32_t central = static_cast<uint32_t>(z.size());
    put32(z, 0x02014b50); put16(z, 20); put16(z, 20); put16(z, 0); put16(z, 0); put16(z, 0); put16(z, 0);
    put32(z, crc); put32(z, size); put32(z, size); put16(z, static_cast<uint32_t>(name.size()));
    put16(z, 0); put16(z, 0); put16(z, 0); put16(z, 0); put32(z, 0); put32(z, 0);
    z += name;
    const uint32_t centralSize = static_cast<uint32_t>(z.size()) - central;
    put32(z, 0x06054b50); put16(z, 0); put16(z, 0); put16(z, 1); put16(z, 1);
    put32(z, centralSize); put32(z, central); put16(z, 0);
    return z;
}

DalnokEngine *engine() {
    static DalnokEngine *e = [] {
        DalnokEngine *created = dalnok_engine_create(48000);
        std::atexit([] { dalnok_engine_destroy(engine()); }); // joins its worker thread before the leak check
        return created;
    }();
    return e;
}

void applyAndRelease(DalnokProjectData *data) {
    if (!data) return;
    // Recovery mode keeps plug-in slots unloaded: no third-party code runs on fuzzed paths.
    if (dalnok_project_apply_recovery(engine(), data) == DALNOK_OK) {
        char err[256];
        const fs::path out = workDir() / "resaved.dalnok";
        (void)dalnok_project_save_snapshot(engine(), out.c_str(), err, sizeof err); // the writer must cope too
    }
}
} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    if (size < 1) return 0;
    const uint8_t kind = bytes[0] % 7;
    const std::string body(reinterpret_cast<const char *>(bytes) + 1, size - 1);
    const fs::path dir = workDir();
    fs::path path;
    switch (kind) {
        case 0: path = dir / "in.dalnok"; writeFile(path, body); break;
        case 1: path = dir / "in.rpp"; writeFile(path, body); break;
        case 2: path = dir / "in.als"; writeFile(path, gzip(body)); break;
        case 3: {
            path = dir / "in.logicx";
            fs::create_directories(path / "Alternatives" / "000");
            writeFile(path / "Alternatives" / "000" / "ProjectData", body);
            break;
        }
        case 4: path = dir / "in.fcpxml"; writeFile(path, body); break;
        case 5: path = dir / "in.dawproject"; writeFile(path, storedZip("project.xml", body)); break;
        default: path = dir / "raw.dawproject"; writeFile(path, body); break; // the zip reader itself
    }
    char report[1 << 14], err[512];
    DalnokProjectData *data = nullptr;
    if (kind == 0) {
        int32_t missing = 0;
        if (dalnok_project_prepare(path.c_str(), 48000, &data, &missing, err, sizeof err) == DALNOK_OK) applyAndRelease(data);
    } else {
        (void)dalnok_project_import_report(path.c_str(), report, sizeof report, err, sizeof err);
        if (dalnok_project_import(path.c_str(), 48000, &data, nullptr, report, sizeof report, err, sizeof err) == DALNOK_OK)
            applyAndRelease(data);
    }
    return 0;
}
