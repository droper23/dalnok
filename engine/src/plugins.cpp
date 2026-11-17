// SPDX-License-Identifier: GPL-3.0-or-later
#include "plugins.hpp"
#include "media.hpp"

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace dalnok {

std::vector<std::string> pluginFolders() {
    std::vector<std::string> out = {"/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/CLAP"};
    if (const char *home = std::getenv("HOME"); home && *home) {
        out.push_back(std::string(home) + "/Library/Audio/Plug-Ins/VST3");
        out.push_back(std::string(home) + "/Library/Audio/Plug-Ins/CLAP");
    }
    return out;
}

std::string relaxJson(const std::string &t) {
    std::string out;
    out.reserve(t.size());
    bool inString = false;
    for (size_t i = 0; i < t.size(); ++i) {
        const char c = t[i];
        if (inString) {
            out += c;
            if (c == '\\' && i + 1 < t.size()) out += t[++i];
            else if (c == '"') inString = false;
            continue;
        }
        if (c == '"') { inString = true; out += c; continue; }
        if (c == '/' && i + 1 < t.size() && t[i + 1] == '/') { // line comment
            while (i < t.size() && t[i] != '\n') ++i;
            continue;
        }
        if (c == ',') {
            size_t j = i + 1;
            while (j < t.size() && (t[j] == ' ' || t[j] == '\t' || t[j] == '\n' || t[j] == '\r')) ++j;
            if (j < t.size() && (t[j] == '}' || t[j] == ']')) continue; // trailing comma
        }
        out += c;
    }
    return out;
}

namespace {
std::string readText(const fs::path &p) {
    std::ifstream in(p, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

std::string kindFor(const std::vector<std::string> &categories) {
    for (const auto &c : categories) {
        if (c == "Instrument" || c == "instrument" || c == "Synth") return "instrument";
    }
    for (const auto &c : categories) {
        if (c == "Fx" || c == "audio-effect" || c == "Analyzer") return "effect";
        if (c == "note-effect") return "midi";
    }
    return categories.empty() ? "unknown" : "effect";
}

void fromBundlePlist(const fs::path &bundle, PluginInfo &info) {
    json::Value plist;
    std::string err;
    if (!readPropertyList((bundle / "Contents" / "Info.plist").string(), plist, err)) return;
    info.version = plist.getString("CFBundleShortVersionString", info.version);
    const std::string display = plist.getString("CFBundleDisplayName", plist.getString("CFBundleName", ""));
    if (!display.empty()) info.name = display;
}

PluginInfo inspectVst3(const fs::path &bundle) {
    PluginInfo info;
    info.format = "vst3";
    info.path = bundle.string();
    info.name = bundle.stem().string();
    info.kind = "unknown";
    fromBundlePlist(bundle, info);
    const fs::path moduleInfo = bundle / "Contents" / "Resources" / "moduleinfo.json";
    json::Value doc;
    std::string err;
    std::error_code ec;
    if (!fs::exists(moduleInfo, ec) || !json::parse(relaxJson(readText(moduleInfo)), doc, err) || !doc.isObject()) return info;
    info.name = doc.getString("Name", info.name);
    info.version = doc.getString("Version", info.version);
    if (const json::Value *factory = doc.get("Factory Info")) info.vendor = factory->getString("Vendor", "");
    if (const json::Value *classes = doc.get("Classes"); classes && classes->isArray()) {
        for (const auto &c : classes->array) {
            if (c.getString("Category", "") != "Audio Module Class") continue;
            if (const json::Value *subs = c.get("Sub Categories"); subs && subs->isArray())
                for (const auto &sc : subs->array)
                    if (sc.isString()) info.categories.push_back(sc.string);
            if (info.vendor.empty()) info.vendor = c.getString("Vendor", "");
            break;
        }
    }
    info.kind = kindFor(info.categories);
    return info;
}

PluginInfo inspectClap(const fs::path &bundle) {
    // CLAP descriptors live inside the binary; without loading it only the bundle metadata is known.
    PluginInfo info;
    info.format = "clap";
    info.path = bundle.string();
    info.name = bundle.stem().string();
    info.kind = "unknown";
    fromBundlePlist(bundle, info);
    return info;
}
} // namespace

std::vector<PluginInfo> scanPluginBundles(const std::vector<std::string> &folders) {
    std::vector<PluginInfo> out;
    for (const auto &folder : folders) {
        std::error_code ec;
        if (!fs::is_directory(folder, ec)) continue;
        fs::recursive_directory_iterator it(folder, fs::directory_options::skip_permission_denied, ec), end;
        for (; !ec && it != end; it.increment(ec)) {
            if (it.depth() > 4) { it.disable_recursion_pending(); continue; }
            const auto ext = it->path().extension().string();
            if (ext == ".vst3" || ext == ".clap") {
                out.push_back(ext == ".vst3" ? inspectVst3(it->path()) : inspectClap(it->path()));
                it.disable_recursion_pending(); // never look inside a bundle for more bundles
            }
        }
    }
    std::sort(out.begin(), out.end(), [](const PluginInfo &a, const PluginInfo &b) {
        return a.name != b.name ? a.name < b.name : a.format < b.format;
    });
    return out;
}

json::Value pluginsToJson(const std::vector<PluginInfo> &plugins) {
    json::Value list = json::Value::makeArray();
    for (const auto &p : plugins) {
        json::Value v = json::Value::makeObject();
        v.set("format", p.format);
        v.set("name", p.name);
        v.set("vendor", p.vendor);
        v.set("version", p.version);
        v.set("kind", p.kind);
        v.set("path", p.path);
        json::Value cats = json::Value::makeArray();
        for (const auto &c : p.categories) cats.push(c);
        v.set("categories", std::move(cats));
        list.push(std::move(v));
    }
    return list;
}

} // namespace dalnok
