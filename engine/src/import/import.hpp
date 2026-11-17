// Project import from other DAWs. Each importer translates a foreign project
// into a Dalnok project document (the same JSON the loader reads) plus a
// migration report listing what came over and what didn't, and why.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "json.hpp"

#include <map>
#include <string>
#include <vector>

namespace dalnok::import {

struct Report {
    std::string app;      // "REAPER", "Ableton Live", "Logic Pro", "Final Cut Pro XML", "Stems"
    std::string version;
    int tracks = 0, clips = 0, media = 0, missingMedia = 0;
    std::map<std::string, int> skipped; // reason key -> count (see kSkipReasons)
    std::vector<std::string> notes;     // human-readable details
    void skip(const std::string &key, int n = 1) { if (n > 0) skipped[key] += n; }
    json::Value toJson() const;
};

/// Time-stretch settings for an imported clip.
struct ClipStretch { double rate = 1; float pitch = 0; bool preservePitch = true; };

/// Accumulates tracks/clips/media in seconds and emits a Dalnok project document.
class Builder {
public:
    explicit Builder(Report &r, double sampleRate = 48000) : report_(r), rate_(sampleRate) {}

    // Returns 0 if the path is empty. Missing files become offline media.
    int32_t addMedia(const std::string &path);
    double mediaSeconds(int32_t media) const;   // 0 if unknown
    int32_t addTrack(const std::string &name, float gainDb, float pan, bool mute, bool solo);
    // Times in seconds. offset = position within the source.
    using Stretch = ClipStretch;
    // `rate` = source seconds per timeline second (time-stretch when ≠ 1).
    void addClip(int32_t track, int32_t media, double start, double offset, double length, const std::string &name,
                 float gainDb = 0, double fadeIn = 0, double fadeOut = 0, bool equalPower = false, Stretch st = {});
    // Repeats [loopStart, loopEnd) of the source to fill `length`, starting at `firstOffset`.
    void addLoopedClip(int32_t track, int32_t media, double start, double length, double firstOffset,
                       double loopStart, double loopEnd, const std::string &name, float gainDb = 0, Stretch st = {});

    json::Value document() const;

private:
    struct Media { std::string path; double seconds = 0; int64_t frames = 0; int32_t channels = 0; bool exists = false; };
    struct Clip { int32_t media; int64_t start, offset, length, fadeIn, fadeOut; bool equalPower; float gainDb; std::string name; Stretch st; };
    struct Track { std::string name; float gainDb, pan; bool mute, solo; std::vector<Clip> clips; };
    int64_t frames(double seconds) const;

    Report &report_;
    double rate_;
    std::vector<Media> media_;
    std::map<std::string, int32_t> mediaByPath_;
    std::vector<Track> tracks_;
};

struct Result {
    json::Value document;
    Report report;
};

/// Detects the format by extension/contents: .rpp, .als, .logicx, .fcpxml/.fcpxmld, .dawproject, or a folder of stems.
bool importProject(const std::string &path, Result &out, std::string &err);

bool importReaper(const std::string &path, Result &out, std::string &err);
bool importAbleton(const std::string &path, Result &out, std::string &err);
bool importStems(const std::string &folder, Result &out, std::string &err);
bool importFcpxml(const std::string &path, Result &out, std::string &err);
bool importLogic(const std::string &path, Result &out, std::string &err);
bool importDawproject(const std::string &path, Result &out, std::string &err);

float linearToDb(double v);

/// Finds a referenced media file: as given (with Windows separators normalized),
/// relative to the project folder, then by file name anywhere under the project
/// folder (projects copied between machines/OSes keep relative layouts but not
/// absolute paths). Returns the best guess even if nothing exists.
std::string locateMedia(const std::string &reference, const std::string &projectDir);

} // namespace dalnok::import
