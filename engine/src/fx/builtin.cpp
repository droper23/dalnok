// Built-in plug-in registry and shared parameter/state handling (ADR-0011).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "fx/builtin.hpp"

#include "fx/channel_eq.hpp"
#include "json.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace dalnok {

const std::vector<BuiltinInfo> &builtinPlugins() {
    static const std::vector<BuiltinInfo> list = {
        {"channel-eq", "Dalnok Channel EQ", "EQ"},
    };
    return list;
}

std::unique_ptr<PluginProcessor> loadBuiltin(const std::string &id, double sampleRate, int maxBlock, std::string &err) {
    (void)maxBlock;
    if (id == "channel-eq") return std::make_unique<fx::ChannelEq>(sampleRate);
    err = "unknown built-in plug-in " + id;
    return nullptr;
}

std::string BuiltinProcessor::categories() const {
    for (const auto &b : builtinPlugins()) if (id_ == b.id) return std::string("Fx|") + b.category;
    return "Fx";
}

BuiltinProcessor::BuiltinProcessor(const char *id, const char *name, std::vector<Param> params)
    : id_(id), name_(name), params_(std::move(params)) {
    uint32_t top = 0;
    for (const auto &p : params_) top = std::max(top, p.id + 1);
    values_.assign(top, 0.0);
    for (const auto &p : params_) values_[p.id] = p.def;
    rtValues_ = values_;
}

const BuiltinProcessor::Param *BuiltinProcessor::find(uint32_t id) const {
    for (const auto &p : params_) if (p.id == id) return &p;
    return nullptr;
}

double BuiltinProcessor::toPlain(const Param &p, double n) const {
    n = std::clamp(n, 0.0, 1.0);
    switch (p.scale) {
    case Param::Log: return p.min * std::pow(p.max / p.min, n);
    case Param::Toggle: return n >= 0.5 ? 1.0 : 0.0;
    case Param::Choice: return std::round(p.min + n * (p.max - p.min));
    case Param::Linear: break;
    }
    return p.min + n * (p.max - p.min);
}

double BuiltinProcessor::toNormalized(const Param &p, double v) const {
    if (p.max <= p.min) return 0;
    if (p.scale == Param::Log) return std::clamp(std::log(std::max(v, p.min) / p.min) / std::log(p.max / p.min), 0.0, 1.0);
    if (p.scale == Param::Toggle) return v >= 0.5 ? 1.0 : 0.0;
    return std::clamp((v - p.min) / (p.max - p.min), 0.0, 1.0);
}

double BuiltinProcessor::value(uint32_t id) const { return id < values_.size() ? values_[id] : 0.0; }

void BuiltinProcessor::setPlain(uint32_t id, double plain) {
    values_[id] = plain;
    if (!changes_.push({id, plain})) primed_ = false; // queue full: the next block takes a full snapshot
}

bool BuiltinProcessor::parameter(int32_t index, PluginParameter &out) {
    if (index < 0 || index >= static_cast<int32_t>(params_.size())) return false;
    const Param &p = params_[static_cast<size_t>(index)];
    const double v = values_[p.id];
    out.id = p.id;
    out.title = p.title;
    out.units = p.units;
    out.value = toNormalized(p, v);
    out.defaultValue = toNormalized(p, p.def);
    out.stepCount = p.scale == Param::Toggle ? 1 : p.scale == Param::Choice ? static_cast<int32_t>(p.max - p.min) : 0;
    out.automatable = true;
    out.display = format(p, v);
    return true;
}

std::string BuiltinProcessor::format(const Param &p, double v) {
    char text[64];
    if (p.scale == Param::Toggle) snprintf(text, sizeof text, "%s", v >= 0.5 ? "On" : "Off");
    else if (p.scale == Param::Choice && p.choices) snprintf(text, sizeof text, "%s", p.choices[static_cast<int>(std::round(v - p.min))]);
    else if (std::fabs(v) >= 1000) snprintf(text, sizeof text, "%.0f", v);
    else if (std::fabs(v) >= 100) snprintf(text, sizeof text, "%.1f", v);
    else snprintf(text, sizeof text, "%.2f", v);
    return text;
}

bool BuiltinProcessor::parameterText(uint32_t id, double normalized, std::string &out) {
    const Param *p = find(id);
    if (!p) return false;
    out = format(*p, toPlain(*p, normalized));
    return true;
}

bool BuiltinProcessor::setParameter(uint32_t id, double normalized) {
    const Param *p = find(id);
    if (!p || !(normalized >= 0 && normalized <= 1)) return false;
    setPlain(id, toPlain(*p, normalized));
    auto it = std::find_if(touched_.begin(), touched_.end(), [&](const auto &t) { return t.first == id; });
    if (it == touched_.end()) touched_.emplace_back(id, normalized);
    else it->second = normalized;
    return true;
}

void BuiltinProcessor::touchedParameters(std::vector<std::pair<uint32_t, double>> &out) { out = touched_; }

bool BuiltinProcessor::automationRange(uint32_t id, double &lo, double &hi) {
    // Automation delivers normalized values; `applyPending` maps them through the parameter's scale.
    if (!find(id)) return false;
    lo = 0; hi = 1;
    return true;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects" // toPlain uses libm (allocation- and lock-free)
void BuiltinProcessor::applyPending() DALNOK_NONBLOCKING {
    bool any = !primed_;
    if (!primed_) {
        // First block (or after an overflow): take every value. The vectors were sized at construction.
        for (size_t i = 0; i < rtValues_.size() && i < values_.size(); ++i) rtValues_[i] = values_[i];
        primed_ = true;
    }
    Change c;
    while (changes_.pop(c)) if (c.id < rtValues_.size()) { rtValues_[c.id] = c.plain; any = true; }
    for (int i = 0; i < autoCount_; ++i) {
        const uint32_t id = autoQueue_[i].id;
        for (const auto &p : params_) {
            if (p.id != id) continue;
            rtValues_[id] = toPlain(p, autoQueue_[i].value);
            any = true;
            break;
        }
    }
    autoCount_ = 0;
    if (any) changed();
}
#pragma clang diagnostic pop

bool BuiltinProcessor::getState(std::string &bytes) {
    json::Value doc = json::Value::makeObject(), values = json::Value::makeObject();
    doc.set("plugin", id_);
    doc.set("version", 1);
    for (const auto &p : params_) values.set(std::to_string(p.id), values_[p.id]);
    for (const auto &[k, v] : extra_) values.set(k, v);
    doc.set("values", std::move(values));
    bytes = json::serialize(doc);
    return true;
}

bool BuiltinProcessor::setState(const std::string &bytes) {
    stateError_.clear();
    json::Value doc;
    std::string err;
    if (!json::parse(bytes, doc, err) || !doc.isObject() || doc.getString("plugin", "") != id_) {
        stateError_ = "not a " + name_ + " state";
        return false;
    }
    const json::Value *values = doc.get("values");
    if (!values || !values->isObject()) { stateError_ = "state has no values"; return false; }
    extra_.clear();
    for (const auto &[key, v] : values->object) {
        if (!v.isNumber() || !std::isfinite(v.number)) continue;
        char *end = nullptr;
        const unsigned long id = std::strtoul(key.c_str(), &end, 10);
        const Param *p = end && *end == 0 ? find(static_cast<uint32_t>(id)) : nullptr;
        if (!p) { extra_.emplace_back(key, v.number); continue; }
        setPlain(p->id, std::clamp(v.number, std::min(p->min, p->max), std::max(p->min, p->max)));
    }
    touched_.clear();
    return true;
}

} // namespace dalnok
