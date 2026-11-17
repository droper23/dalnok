// SPDX-License-Identifier: GPL-3.0-or-later
#include "plugins.hpp"
#include "media.hpp"

#include "engine.hpp" // writeFileDurably

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <poll.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <filesystem>
#include <fstream>
#include <sstream>

extern char **environ; // POSIX: the process environment, passed on to the scanner

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

// ---- Stage 2: out-of-process validation ----------------------------------------

namespace {
struct ScanOutcome {
    std::string status; // ok, failed, crashed, timeout
    json::Value result;  // scanner JSON when it produced any
    std::string error;
};

ScanOutcome runScanner(const std::string &scanner, const std::string &kind, const std::string &arg, int timeoutMs) {
    int fds[2];
    if (::pipe(fds) != 0) return {"failed", {}, "cannot create pipe"};
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    std::vector<char *> argv = {const_cast<char *>(scanner.c_str()), const_cast<char *>(kind.c_str()),
                                const_cast<char *>(arg.c_str()), nullptr};
    pid_t pid = 0;
    const int spawned = posix_spawn(&pid, scanner.c_str(), &actions, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    ::close(fds[1]);
    if (spawned != 0) { ::close(fds[0]); return {"failed", {}, "cannot start the scanner: " + std::string(std::strerror(spawned))}; }
    ::fcntl(fds[0], F_SETFL, O_NONBLOCK);
    std::string output;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    int status = 0;
    bool exited = false, timedOut = false;
    char buf[4096];
    while (true) {
        for (ssize_t n; (n = ::read(fds[0], buf, sizeof buf)) > 0;) output.append(buf, static_cast<size_t>(n));
        if (::waitpid(pid, &status, WNOHANG) == pid) { exited = true; break; }
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
        if (left <= 0) { timedOut = true; break; }
        pollfd p{fds[0], POLLIN, 0};
        ::poll(&p, 1, static_cast<int>(std::min<long long>(left, 20)));
    }
    if (timedOut) {
        ::kill(pid, SIGKILL);
        ::waitpid(pid, &status, 0);
    }
    for (ssize_t n; (n = ::read(fds[0], buf, sizeof buf)) > 0;) output.append(buf, static_cast<size_t>(n));
    ::close(fds[0]);
    ScanOutcome o;
    std::string parseErr;
    const auto nl = output.find('\n');
    const bool parsed = json::parse(output.substr(0, nl), o.result, parseErr) && o.result.isObject();
    if (timedOut) { o.status = "timeout"; o.error = "did not finish within " + std::to_string(timeoutMs / 1000.0).substr(0, 4) + " s"; }
    else if (exited && WIFSIGNALED(status)) { o.status = "crashed"; o.error = std::string("crashed (") + strsignal(WTERMSIG(status)) + ")"; }
    else if (parsed && o.result.getBool("ok", false)) o.status = "ok";
    else { o.status = "failed"; o.error = parsed ? o.result.getString("error", "failed") : "no result"; }
    return o;
}

std::string stampFor(const PluginInfo &p) {
    if (p.format == "au") return "au " + p.version;
    struct stat st{}, plist{};
    ::stat(p.path.c_str(), &st);
    ::stat((p.path + "/Contents/Info.plist").c_str(), &plist);
    return std::to_string(st.st_mtimespec.tv_sec) + "." + std::to_string(plist.st_mtimespec.tv_sec) + "." +
           std::to_string(plist.st_size) + " " + p.version;
}

std::string readAll(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

// Refines kind, vendor and version from the scanner's answer.
void applyScan(json::Value &v, const json::Value &result) {
    const json::Value *classes = result.get("classes");
    if (!classes || !classes->isArray()) return;
    for (const auto &c : classes->array) {
        std::vector<std::string> cats;
        if (const json::Value *f = c.get("features"); f && f->isArray()) { // CLAP
            for (const auto &x : f->array) if (x.isString()) cats.push_back(x.string);
        } else if (c.getString("category", "") == "Audio Module Class") { // VST3
            std::string sub = c.getString("subCategories", "");
            for (size_t i = 0; i <= sub.size();) {
                const size_t j = std::min(sub.find('|', i), sub.size());
                if (j > i) cats.push_back(sub.substr(i, j - i));
                i = j + 1;
            }
        } else {
            continue;
        }
        v.set("kind", kindFor(cats));
        json::Value list = json::Value::makeArray();
        for (const auto &x : cats) list.push(x);
        v.set("categories", std::move(list));
        if (const auto vendor = c.getString("vendor", ""); !vendor.empty()) v.set("vendor", vendor);
        if (const auto version = c.getString("version", ""); !version.empty()) v.set("version", version);
        if (const auto name = c.getString("name", ""); !name.empty()) v.set("name", name);
        break;
    }
}
} // namespace

json::Value validatePlugins(const std::vector<PluginInfo> &plugins, const std::string &scanner, const std::string &cachePath,
                            int timeoutMs, bool rescan, int parallel) {
    json::Value cache;
    std::string err;
    if (cachePath.empty() || !json::parse(readAll(cachePath), cache, err) || !cache.isObject()) cache = json::Value::makeObject();
    json::Value entries = cache.get("entries") && cache.get("entries")->isObject() ? *cache.get("entries") : json::Value::makeObject();
    json::Value out = pluginsToJson(plugins);
    std::vector<size_t> todo;
    std::vector<std::string> keys(plugins.size()), stamps(plugins.size());
    for (size_t i = 0; i < plugins.size(); ++i) {
        keys[i] = plugins[i].format + ":" + plugins[i].path;
        stamps[i] = stampFor(plugins[i]);
        const json::Value *hit = entries.get(keys[i]);
        if (!rescan && hit && hit->getString("stamp", "") == stamps[i] && hit->get("scan")) {
            json::Value scan = *hit->get("scan");
            scan.set("cached", true);
            if (const json::Value *r = hit->get("result")) applyScan(out.array[i], *r);
            out.array[i].set("scan", std::move(scan));
        } else {
            todo.push_back(i);
        }
    }
    std::atomic<size_t> next{0};
    std::mutex lock;
    auto worker = [&] {
        for (size_t k; (k = next.fetch_add(1)) < todo.size();) {
            const size_t i = todo[k];
            const auto &p = plugins[i];
            ScanOutcome o = runScanner(scanner, p.format, p.path, timeoutMs);
            json::Value scan = json::Value::makeObject();
            scan.set("status", o.status);
            scan.set("cached", false);
            if (!o.error.empty()) scan.set("error", o.error);
            std::lock_guard<std::mutex> g(lock);
            if (o.status == "ok") applyScan(out.array[i], o.result);
            json::Value entry = json::Value::makeObject();
            entry.set("stamp", stamps[i]);
            entry.set("scan", scan);
            if (o.result.isObject()) entry.set("result", o.result);
            entries.set(keys[i], std::move(entry));
            out.array[i].set("scan", std::move(scan));
        }
    };
    std::vector<std::thread> threads;
    for (int t = 0; t < std::max(1, parallel); ++t) threads.emplace_back(worker);
    for (auto &t : threads) t.join();
    if (!cachePath.empty() && !todo.empty()) {
        std::error_code ec;
        fs::create_directories(fs::path(cachePath).parent_path(), ec);
        json::Value doc = json::Value::makeObject();
        doc.set("format", "dalnok-plugin-cache");
        doc.set("version", 1);
        doc.set("entries", std::move(entries));
        writeFileDurably(cachePath, json::serialize(doc, true), err);
    }
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
