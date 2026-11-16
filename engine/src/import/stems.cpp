// Folder-of-stems import: every audio file becomes a track starting at 0.
// This is the universal migration path ("Export All Tracks as Audio Files" in
// Logic, "Export stems" in Ableton, "Render stems" in REAPER). A common file
// name prefix (e.g. "Song#01 ") is stripped from track names.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "import/import.hpp"

#include <algorithm>
#include <filesystem>
#include <set>

namespace fs = std::filesystem;

namespace dalnok::import {

bool importStems(const std::string &folder, Result &out, std::string &err) {
    static const std::set<std::string> kAudio = {".wav", ".aif", ".aiff", ".caf", ".mp3", ".m4a", ".aac", ".flac", ".alac", ".wave"};
    std::vector<fs::path> files;
    std::error_code ec;
    for (const auto &e : fs::directory_iterator(folder, ec)) {
        if (!e.is_regular_file()) continue;
        auto ext = e.path().extension().string();
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
        if (kAudio.count(ext) && e.path().filename().string()[0] != '.') files.push_back(e.path());
    }
    if (files.empty()) {
        err = "no audio files found in " + folder;
        return false;
    }
    std::sort(files.begin(), files.end());
    // Longest common prefix of the stems' names, cut back to a separator.
    std::string prefix = files[0].stem().string();
    for (const auto &f : files) {
        const auto s = f.stem().string();
        size_t i = 0;
        while (i < prefix.size() && i < s.size() && prefix[i] == s[i]) ++i;
        prefix.resize(i);
    }
    while (!prefix.empty() && std::string(" _-#.").find(prefix.back()) == std::string::npos) prefix.pop_back();
    if (files.size() == 1) prefix.clear();

    Report &rep = out.report;
    rep.app = "Stems";
    Builder b(rep, 48000);
    for (const auto &f : files) {
        std::string name = f.stem().string().substr(prefix.size());
        const int track = b.addTrack(name.empty() ? f.stem().string() : name, 0, 0, false, false);
        const int media = b.addMedia(f.string());
        b.addClip(track, media, 0, 0, b.mediaSeconds(media) > 0 ? b.mediaSeconds(media) : 1e9, name);
    }
    out.document = b.document();
    return true;
}

} // namespace dalnok::import
