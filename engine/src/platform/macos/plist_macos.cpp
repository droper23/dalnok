// Property-list reading via CoreFoundation (used by the Logic importer).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "json.hpp"
#include "media.hpp"

#include <CoreFoundation/CoreFoundation.h>

#include <fstream>
#include <sstream>

namespace dalnok {

namespace {
json::Value convert(CFTypeRef v, int depth) {
    if (!v || depth > 64) return {};
    const CFTypeID t = CFGetTypeID(v);
    if (t == CFStringGetTypeID()) {
        const auto s = static_cast<CFStringRef>(v);
        if (const char *c = CFStringGetCStringPtr(s, kCFStringEncodingUTF8)) return json::Value(std::string(c));
        std::string buf(static_cast<size_t>(CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8)) + 1, '\0');
        CFStringGetCString(s, buf.data(), static_cast<CFIndex>(buf.size()), kCFStringEncodingUTF8);
        buf.resize(std::strlen(buf.c_str()));
        return json::Value(buf);
    }
    if (t == CFNumberGetTypeID()) {
        double d = 0;
        CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberDoubleType, &d);
        return json::Value(d);
    }
    if (t == CFBooleanGetTypeID()) return json::Value(static_cast<bool>(CFBooleanGetValue(static_cast<CFBooleanRef>(v))));
    if (t == CFArrayGetTypeID()) {
        json::Value a = json::Value::makeArray();
        const auto arr = static_cast<CFArrayRef>(v);
        for (CFIndex i = 0; i < CFArrayGetCount(arr); ++i) a.push(convert(CFArrayGetValueAtIndex(arr, i), depth + 1));
        return a;
    }
    if (t == CFDictionaryGetTypeID()) {
        json::Value o = json::Value::makeObject();
        const auto dict = static_cast<CFDictionaryRef>(v);
        const CFIndex n = CFDictionaryGetCount(dict);
        std::vector<const void *> keys(static_cast<size_t>(n)), vals(static_cast<size_t>(n));
        CFDictionaryGetKeysAndValues(dict, keys.data(), vals.data());
        for (CFIndex i = 0; i < n; ++i) {
            const json::Value k = convert(keys[static_cast<size_t>(i)], depth + 1);
            if (k.isString()) o.set(k.string, convert(vals[static_cast<size_t>(i)], depth + 1));
        }
        return o;
    }
    return {};
}
} // namespace

bool readPropertyList(const std::string &path, json::Value &out, std::string &err) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        err = "cannot open " + path;
        return false;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    const std::string bytes = ss.str();
    CFDataRef data = CFDataCreate(nullptr, reinterpret_cast<const UInt8 *>(bytes.data()), static_cast<CFIndex>(bytes.size()));
    CFErrorRef cfErr = nullptr;
    CFPropertyListRef pl = CFPropertyListCreateWithData(nullptr, data, kCFPropertyListImmutable, nullptr, &cfErr);
    CFRelease(data);
    if (!pl) {
        if (cfErr) CFRelease(cfErr);
        err = "invalid property list: " + path;
        return false;
    }
    out = convert(pl, 0);
    CFRelease(pl);
    return true;
}

} // namespace dalnok
