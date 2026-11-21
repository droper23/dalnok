// C API internals shared by the dalnok_api*.cpp files (A-06 split): the opaque handles and small helpers.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "dalnok/dalnok.h"
#include "engine.hpp"

#include <algorithm>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

using namespace dalnok;

struct DalnokEngine {
    Engine impl;
    explicit DalnokEngine(double sr) : impl(sr) {}
};

struct DalnokProjectData {
    std::unique_ptr<Engine::PreparedProject> impl;
};

namespace dalnok::api {
inline size_t copyOut(char *buf, size_t len, const std::string &s) {
    if (buf && len > 0) {
        const size_t n = std::min(len - 1, s.size());
        std::memcpy(buf, s.data(), n);
        buf[n] = '\0';
    }
    return s.size();
}
inline std::vector<MidiNote> toNotes(const DalnokNote *notes, int32_t count) {
    std::vector<MidiNote> v;
    for (int32_t i = 0; notes && i < count; ++i) v.push_back({notes[i].start, notes[i].length, notes[i].pitch, notes[i].velocity});
    return v;
}
inline DalnokStatus statusFor(bool ok, const std::string &err) {
    if (ok) return DALNOK_OK;
    return err.rfind("no such", 0) == 0 ? DALNOK_ERR_NOT_FOUND : DALNOK_ERR_INVALID_ARG;
}
} // namespace dalnok::api

using namespace dalnok::api;
