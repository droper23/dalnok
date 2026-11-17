// Test-only VST3 module for scripts/ci/plugin-scan.sh. Variants (compile-time):
//   FIXTURE_CRASH: aborts in bundleEntry. FIXTURE_HANG: never returns from GetPluginFactory.
//   FIXTURE_NOISY: writes to stdout while loading. Otherwise: one effect class "Dalnok Test Gain".
// SPDX-License-Identifier: GPL-3.0-or-later
#include "pluginterfaces/base/ipluginbase.h"
#include <CoreFoundation/CoreFoundation.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

using namespace Steinberg;

class Factory final : public IPluginFactory2 {
public:
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        if (FUnknownPrivate::iidEqual(iid, IPluginFactory2::iid) || FUnknownPrivate::iidEqual(iid, IPluginFactory::iid) ||
            FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
            *obj = this;
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API getFactoryInfo(PFactoryInfo *info) override {
        *info = PFactoryInfo("Dalnok Tests", "https://example.invalid", "", PFactoryInfo::kUnicode);
        return kResultOk;
    }
    int32 PLUGIN_API countClasses() override { return 1; }
    tresult PLUGIN_API getClassInfo(int32 index, PClassInfo *info) override {
        if (index != 0) return kInvalidArgument;
        *info = PClassInfo(cid, PClassInfo::kManyInstances, "Audio Module Class", "Dalnok Test Gain");
        return kResultOk;
    }
    tresult PLUGIN_API getClassInfo2(int32 index, PClassInfo2 *info) override {
        if (index != 0) return kInvalidArgument;
        *info = PClassInfo2(cid, PClassInfo::kManyInstances, "Audio Module Class", "Dalnok Test Gain", 0, "Fx|Dynamics",
                            "Dalnok Tests", "1.0.0", "VST 3.8.1");
        return kResultOk;
    }
    tresult PLUGIN_API createInstance(FIDString, FIDString, void **obj) override { *obj = nullptr; return kNotImplemented; }
private:
    TUID cid = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
};

extern "C" {
SMTG_EXPORT_SYMBOL bool bundleEntry(CFBundleRef) {
#ifdef FIXTURE_CRASH
    std::abort();
#endif
#ifdef FIXTURE_NOISY
    for (int i = 0; i < 1000; ++i) std::printf("plugin log line %d {not json}\n", i);
    std::fflush(stdout);
#endif
    return true;
}
SMTG_EXPORT_SYMBOL bool bundleExit() { return true; }
SMTG_EXPORT_SYMBOL IPluginFactory *PLUGIN_API GetPluginFactory() {
#ifdef FIXTURE_HANG
    for (;;) ::sleep(60);
#endif
    static Factory factory;
    return &factory;
}
}
