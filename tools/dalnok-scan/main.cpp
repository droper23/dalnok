// dalnok-scan: loads ONE plugin in its own process and prints what it declares as JSON.
// Dalnok runs it with a timeout (ADR-0009 stage 2), so a plugin that crashes or hangs
// only takes this process down. Usage:
//   dalnok-scan vst3 <bundle>     classes from the plugin factory (IPluginFactory2 when available)
//   dalnok-scan clap <bundle>     descriptors from clap.plugin-factory
//   dalnok-scan au <type:subtype:manufacturer>   instantiate, initialize, read latency/tail/parameters
// Anything the plugin prints is discarded; the JSON goes to the original stdout. Exit 0 = success.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "pluginterfaces/base/ipluginbase.h"
#include "clap/clap.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>
#include <vector>

namespace {
int out = 1;

std::string esc(const char *s) {
    std::string r = "\"";
    for (const char *p = s ? s : ""; *p; ++p) {
        const unsigned char c = static_cast<unsigned char>(*p);
        if (c == '"' || c == '\\') { r += '\\'; r += static_cast<char>(c); }
        else if (c < 0x20) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", c); r += b; }
        else r += static_cast<char>(c);
    }
    return r + "\"";
}
std::string escN(const char *s, size_t n) { return esc(std::string(s, strnlen(s, n)).c_str()); }

[[noreturn]] void finish(const std::string &json, int code) {
    const std::string line = json + "\n";
    (void)!::write(out, line.data(), line.size());
    _exit(code); // skip plugin static destructors, which are a common crash source
}
[[noreturn]] void fail(const std::string &why) { finish("{\"ok\":false,\"error\":" + esc(why.c_str()) + "}", 2); }

CFBundleRef openBundle(const char *path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(path),
                                                           static_cast<CFIndex>(std::strlen(path)), true);
    if (!url) fail("bad path");
    CFBundleRef bundle = CFBundleCreate(nullptr, url);
    CFRelease(url);
    if (!bundle) fail("not a bundle");
    CFErrorRef error = nullptr;
    if (!CFBundleLoadExecutableAndReturnError(bundle, &error)) {
        if (error) CFRelease(error);
        fail("the bundle's code could not be loaded (architecture, signature or missing library)");
    }
    return bundle;
}

void scanVst3(const char *path) {
    using namespace Steinberg;
    CFBundleRef bundle = openBundle(path);
    using Entry = bool (*)(CFBundleRef);
    using Factory = IPluginFactory *(PLUGIN_API *)();
    if (auto entry = reinterpret_cast<Entry>(CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleEntry"))))
        if (!entry(bundle)) fail("bundleEntry failed");
    auto get = reinterpret_cast<Factory>(CFBundleGetFunctionPointerForName(bundle, CFSTR("GetPluginFactory")));
    if (!get) fail("no GetPluginFactory");
    IPluginFactory *factory = get();
    if (!factory) fail("GetPluginFactory returned nothing");
    PFactoryInfo info{};
    factory->getFactoryInfo(&info);
    IPluginFactory2 *f2 = nullptr;
    if (factory->queryInterface(IPluginFactory2::iid, reinterpret_cast<void **>(&f2)) != kResultOk) f2 = nullptr;
    std::string classes;
    const int32 count = factory->countClasses();
    for (int32 i = 0; i < count && i < 256; ++i) {
        std::string item;
        if (f2) {
            PClassInfo2 ci{};
            if (f2->getClassInfo2(i, &ci) != kResultOk) continue;
            item = "{\"category\":" + escN(ci.category, sizeof ci.category) + ",\"name\":" + escN(ci.name, sizeof ci.name) +
                   ",\"subCategories\":" + escN(ci.subCategories, sizeof ci.subCategories) + ",\"vendor\":" +
                   escN(ci.vendor, sizeof ci.vendor) + ",\"version\":" + escN(ci.version, sizeof ci.version) +
                   ",\"sdkVersion\":" + escN(ci.sdkVersion, sizeof ci.sdkVersion) + "}";
        } else {
            PClassInfo ci{};
            if (factory->getClassInfo(i, &ci) != kResultOk) continue;
            item = "{\"category\":" + escN(ci.category, sizeof ci.category) + ",\"name\":" + escN(ci.name, sizeof ci.name) + "}";
        }
        classes += (classes.empty() ? "" : ",") + item;
    }
    finish("{\"ok\":true,\"format\":\"vst3\",\"vendor\":" + escN(info.vendor, sizeof info.vendor) + ",\"classes\":[" + classes + "]}", 0);
}

void scanClap(const char *path) {
    // The CLAP entry lives in the bundle's executable as the data symbol clap_entry.
    CFBundleRef bundle = openBundle(path);
    auto *entry = static_cast<const clap_plugin_entry_t *>(CFBundleGetDataPointerForName(bundle, CFSTR("clap_entry")));
    if (!entry) fail("no clap_entry");
    if (!clap_version_is_compatible(entry->clap_version)) fail("incompatible CLAP version");
    if (!entry->init(path)) fail("clap_entry init failed");
    auto *factory = static_cast<const clap_plugin_factory_t *>(entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
    if (!factory) fail("no plugin factory");
    std::string classes;
    const uint32_t count = factory->get_plugin_count(factory);
    for (uint32_t i = 0; i < count && i < 256; ++i) {
        const clap_plugin_descriptor_t *d = factory->get_plugin_descriptor(factory, i);
        if (!d) continue;
        std::string features;
        for (const char *const *f = d->features; f && *f; ++f) features += (features.empty() ? "" : ",") + esc(*f);
        classes += (classes.empty() ? "" : ",") + std::string("{\"id\":") + esc(d->id) + ",\"name\":" + esc(d->name) +
                   ",\"vendor\":" + esc(d->vendor) + ",\"version\":" + esc(d->version) + ",\"features\":[" + features + "]}";
    }
    entry->deinit();
    finish("{\"ok\":true,\"format\":\"clap\",\"classes\":[" + classes + "]}", 0);
}

OSType fourCC(const char *s) {
    return static_cast<OSType>((static_cast<unsigned char>(s[0]) << 24) | (static_cast<unsigned char>(s[1]) << 16) |
                               (static_cast<unsigned char>(s[2]) << 8) | static_cast<unsigned char>(s[3]));
}

void scanAudioUnit(const char *id) {
    if (std::strlen(id) != 14 || id[4] != ':' || id[9] != ':') fail("expected type:subtype:manufacturer");
    AudioComponentDescription desc{fourCC(id), fourCC(id + 5), fourCC(id + 10), 0, 0};
    AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
    if (!comp) fail("Audio Unit not registered");
    AudioComponentInstance unit = nullptr;
    if (AudioComponentInstanceNew(comp, &unit) != noErr || !unit) fail("could not instantiate");
    if (AudioUnitInitialize(unit) != noErr) fail("could not initialize");
    Float64 latency = 0, tail = 0;
    UInt32 size = sizeof latency;
    AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size);
    size = sizeof tail;
    AudioUnitGetProperty(unit, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &tail, &size);
    UInt32 listSize = 0;
    AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &listSize, nullptr);
    char buf[256];
    std::snprintf(buf, sizeof buf, "{\"ok\":true,\"format\":\"au\",\"latencySeconds\":%g,\"tailSeconds\":%g,\"parameters\":%u}",
                  latency, tail, static_cast<unsigned>(listSize / sizeof(AudioUnitParameterID)));
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    finish(buf, 0);
}
} // namespace

int main(int argc, char **argv) {
    // Keep the real stdout for our JSON; send everything else (plugin logging) to /dev/null.
    out = ::dup(1);
    const int null = ::open("/dev/null", O_WRONLY);
    if (out < 0 || null < 0 || ::dup2(null, 1) < 0) return 3;
    ::close(null);
    if (argc != 3) fail("usage: dalnok-scan vst3|clap|au <path-or-id>");
    const std::string kind = argv[1];
    if (kind == "vst3") scanVst3(argv[2]);
    if (kind == "clap") scanClap(argv[2]);
    if (kind == "au") scanAudioUnit(argv[2]);
    fail("unknown kind " + kind);
}
