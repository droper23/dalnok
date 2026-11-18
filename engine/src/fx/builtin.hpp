// Built-in Dalnok plug-ins (ADR-0011): portable processors hosted through the PluginProcessor interface.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "plugin_host.hpp"
#include "rt.hpp"

#include <memory>
#include <string>
#include <vector>

namespace dalnok {

struct BuiltinInfo { const char *id, *name, *category; };
// Plug-ins this build provides. Their slot path is "dalnok:<id>".
const std::vector<BuiltinInfo> &builtinPlugins();
std::unique_ptr<PluginProcessor> loadBuiltin(const std::string &id, double sampleRate, int maxBlock, std::string &err);

// Shared machinery: a fixed parameter table, JSON state, and lock-free parameter delivery.
class BuiltinProcessor : public PluginProcessor {
public:
    struct Param {
        uint32_t id;
        const char *title, *units;
        double min, max, def;
        enum Scale { Linear, Log, Toggle, Choice } scale = Linear;
        const char *const *choices = nullptr; // Choice: labels for min..max (integers)
    };
    BuiltinProcessor(const char *id, const char *name, std::vector<Param> params);

    bool instrument() const override { return false; }
    uint32_t latency() const override { return 0; }
    const std::string &name() const override { return name_; }
    const std::string &vendor() const override { return vendor_; }
    const std::string &classId() const override { return id_; }
    bool getState(std::string &bytes) override;
    bool setState(const std::string &bytes) override;
    std::string stateError() const override { return stateError_; }
    int32_t parameterCount() override { return static_cast<int32_t>(params_.size()); }
    bool parameter(int32_t index, PluginParameter &out) override;
    bool setParameter(uint32_t id, double normalized) override;
    void touchedParameters(std::vector<std::pair<uint32_t, double>> &out) override;
    uint64_t editCount() const override { return 0; }
    bool automationRange(uint32_t id, double &lo, double &hi) override;
    bool hasEditor() override { return false; }
    bool openEditor(void *, int32_t &, int32_t &, void (*)(void *, int32_t, int32_t), void *, std::string &err) override {
        err = "built-in plug-ins use the generic parameter view";
        return false;
    }
    void closeEditor() override {}

    // Plain (unnormalized) value of a parameter as seen by the control thread.
    double value(uint32_t id) const;

protected:
    // Audio thread: applies queued changes and automation, then calls `changed` once if anything moved.
    void applyPending() DALNOK_NONBLOCKING;
    virtual void changed() DALNOK_NONBLOCKING = 0;
    double rt(uint32_t id) const DALNOK_NONBLOCKING { return id < rtValues_.size() ? rtValues_[id] : 0.0; }
    // Values a saved state or an import may carry beyond the parameter table (for example from a newer version).
    std::vector<std::pair<std::string, double>> extra_;

private:
    const Param *find(uint32_t id) const;
    double toPlain(const Param &p, double normalized) const;
    double toNormalized(const Param &p, double plain) const;
    void setPlain(uint32_t id, double plain);

    std::string id_, name_, vendor_ = "Dalnok", stateError_;
    std::vector<Param> params_;
    std::vector<double> values_;   // control thread, indexed by parameter id
    std::vector<double> rtValues_; // audio thread copy
    std::vector<std::pair<uint32_t, double>> touched_;
    struct Change { uint32_t id; double plain; };
    SpscQueue<Change, 1024> changes_;
    bool primed_ = false;
};

} // namespace dalnok
