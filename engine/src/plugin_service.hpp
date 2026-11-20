// Plug-in instances for one engine (A-06): live instances and load errors by slot id, deferred and isolated
// activation (ADR-0013, ADR-0014), offline copies, the device workgroup for isolated hosts, and their health.
// Control thread only. The Engine owns the model and revisions and calls in with the model it holds.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "plugin_host.hpp"
#include "plugin_remote.hpp"

#include <chrono>
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace dalnok {

struct Model;
struct PluginSlot;

class PluginHostService {
public:
    using PluginMap = std::map<int32_t, std::shared_ptr<PluginProcessor>>;

    PluginHostService(); // reads DALNOK_PLUGIN_HOST and DALNOK_PLUGIN_LOAD_TIMEOUT_MS
    ~PluginHostService();
    void setSampleRate(double rate) { sampleRate_ = rate; }

    // Instances and errors by slot id.
    const PluginMap &instances() const { return instances_; }
    PluginProcessor *instance(int32_t id) const;
    bool loaded(int32_t id) const { return instances_.count(id) != 0; }
    void insert(int32_t id, std::shared_ptr<PluginProcessor> p) { instances_[id] = std::move(p); }
    void erase(int32_t id) { instances_.erase(id); }
    std::string error(int32_t id) const;
    void setError(int32_t id, std::string why) { errors_[id] = std::move(why); }
    void clear(); // a new project: drops instances, errors and queues (snapshots holding instances release them later)

    // Creating instances. Non-built-in plug-ins run in a host process when a host path is set (ADR-0014).
    std::shared_ptr<PluginProcessor> create(const std::string &format, const std::string &path, const std::string &classId,
                                            bool offline, std::string &err) const;
    bool instantiate(const PluginSlot &slot); // false: not loaded (reason in error())
    void instantiateMissing(const Model &m);  // every slot without an instance
    static std::string stateRejected(const std::string &detail);

    // State: the live instance's, or the saved state of an unloaded slot.
    bool state(const Model &m, int32_t id, std::string &bytes) const;
    void captureLiveState(Model &m) const;
    PluginMap offlineCopies(const Model &m) const; // fresh instances with the live state, for offline renders

    // Deferred activation (ADR-0013) with isolated plug-ins loading in parallel (ADR-0014 stage 2).
    void queue(int32_t id) { pending_.push_back(id); }
    size_t pendingCount() const { return pending_.size() + launching_.size(); }
    bool loading(int32_t id) const;
    // Handles the next queued slot. `slot` is the one finished in this call (0: none yet); returns how many remain,
    // or -1 if none were queued. `changed`: something finished, so the caller publishes it.
    int32_t activateNext(const Model &m, int32_t &slot, double &seconds, bool &changed);
    bool cancelPending(); // true if anything was cancelled
    // An unloaded or failed slot from its saved state (the caller publishes).
    bool reload(const Model &m, int32_t id, std::string &err);

    // Out-of-process hosting.
    void setHostPath(std::string path) { hostPath_ = std::move(path); }
    const std::string &hostPath() const { return hostPath_; }
    void setWorkgroupPort(uint32_t port); // takes the send right; 0 = none (the device stopped)

    // Health, from the control thread's garbage collection: slots whose editor changed a parameter since the last
    // call, and isolated slots whose host failed since then.
    std::vector<int32_t> poll();

private:
    static const PluginSlot *findSlot(const Model &m, int32_t id);
    bool isolates(const PluginSlot &slot) const;

    struct Launching {
        int32_t slot;
        std::unique_ptr<RemotePluginLaunch> launch;
        std::chrono::steady_clock::time_point started;
    };
    static constexpr size_t kMaxParallelLaunches = 4;

    double sampleRate_ = 48000;
    PluginMap instances_;
    std::map<int32_t, std::string> errors_;
    std::vector<int32_t> pending_; // queued for deferred activation, in track order
    std::vector<Launching> launching_;
    std::string hostPath_;         // dalnok-plughost; empty = plug-ins run in this process
    std::set<int32_t> failed_;     // isolated instances whose failure has been reported
    int loadTimeoutMs_ = 60'000;   // an isolated plug-in that takes longer to load is killed
    uint32_t workgroupPort_ = 0;   // send right for the running device's audio workgroup
    std::map<int32_t, uint64_t> editCounts_; // editor edit counts already seen
};

} // namespace dalnok
