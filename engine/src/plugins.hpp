// Plugin discovery (Phase 4, step 1). Read-only: bundles are inspected through their metadata
// files and the OS component registry. No plugin code is loaded (see ADR-0009).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "json.hpp"
#include <string>
#include <vector>

namespace dalnok {

struct PluginInfo {
    std::string format;  // "vst3", "au", "clap"
    std::string name, vendor, version;
    std::string kind;    // "instrument", "effect", "midi", or "unknown" (needs a sandboxed scan)
    std::string path;    // bundle path (VST3, CLAP) or "type:subtype:manufacturer" (AU)
    std::vector<std::string> categories;
};

// Standard macOS plugin folders (system and user), plus any extra folders.
std::vector<std::string> pluginFolders();
// VST3 and CLAP bundles found in `folders` (recursing into subfolders, not into bundles).
std::vector<PluginInfo> scanPluginBundles(const std::vector<std::string> &folders);
// Audio Units registered with the OS (platform; empty elsewhere).
std::vector<PluginInfo> listAudioUnits();
json::Value pluginsToJson(const std::vector<PluginInfo> &plugins);
// VST3 moduleinfo.json allows trailing commas; this strips them (outside strings) before strict parsing.
std::string relaxJson(const std::string &text);

} // namespace dalnok
