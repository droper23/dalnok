// SPDX-License-Identifier: GPL-3.0-or-later
#include "plugin_service.hpp"
#include "engine.hpp"

#include <algorithm>
#include <cstdlib>

namespace dalnok {

PluginHostService::PluginHostService() {
    // Tests and the CLI can run every non-built-in plug-in isolated (ADR-0014); the app sets this explicitly.
    if (const char *host = std::getenv("DALNOK_PLUGIN_HOST"); host && *host) hostPath_ = host;
    if (const char *ms = std::getenv("DALNOK_PLUGIN_LOAD_TIMEOUT_MS"); ms && std::atoi(ms) > 0) loadTimeoutMs_ = std::atoi(ms);
}

PluginHostService::~PluginHostService() { releaseMachSendRight(workgroupPort_); }

PluginProcessor *PluginHostService::instance(int32_t id) const {
    auto it = instances_.find(id);
    return it == instances_.end() ? nullptr : it->second.get();
}

std::string PluginHostService::error(int32_t id) const {
    auto it = errors_.find(id);
    return it == errors_.end() ? "" : it->second;
}

void PluginHostService::clear() {
    editorStates_.clear();
    instances_.clear();
    errors_.clear();
    pending_.clear();
    launching_.clear();
}

bool PluginHostService::isolates(const PluginSlot &slot) const { return !hostPath_.empty() && slot.format != "dalnok"; }

std::shared_ptr<PluginProcessor> PluginHostService::create(const std::string &format, const std::string &path,
                                                           const std::string &classId, bool offline, std::string &err) const {
    // Built-in plug-ins are our own code and always run here; others run in a host process when enabled (ADR-0014).
    if (!hostPath_.empty() && format != "dalnok") {
        auto p = loadRemotePlugin(hostPath_, format, path, classId, sampleRate_, kMaxBlock, offline, loadTimeoutMs_, err);
        if (p && !offline && workgroupPort_) p->shareWorkgroup(workgroupPort_);
        return p;
    }
    return loadPlugin(format, path, classId, sampleRate_, kMaxBlock, offline, err);
}

std::string PluginHostService::stateRejected(const std::string &detail) {
    return "the saved state was not accepted" + (detail.empty() ? std::string{} : ": " + detail) + "; the original state was preserved";
}

bool PluginHostService::instantiate(const PluginSlot &slot) {
    std::string err;
    std::shared_ptr<PluginProcessor> p(create(slot.format, slot.path, slot.classId, false, err));
    if (!p) { errors_[slot.id] = err; return false; }
    if (!slot.state.empty() && !p->setStateFromDocument(slot.state.str())) {
        // Keep the original state intact instead of running and later saving a default instance.
        errors_[slot.id] = stateRejected(p->stateError());
        return false;
    }
    errors_.erase(slot.id);
    editCounts_[slot.id] = p->editCount(); // values a plug-in reports while loading are not edits
    instances_[slot.id] = std::move(p);
    return true;
}

void PluginHostService::instantiateMissing(const Model &m) {
    for (const auto &t : m.tracks)
        for (const auto &slot : t.plugins)
            if (!instances_.count(slot.id)) instantiate(slot);
}

const PluginSlot *PluginHostService::findSlot(const Model &m, int32_t id) {
    for (const auto &t : m.tracks)
        for (const auto &slot : t.plugins)
            if (slot.id == id) return &slot;
    return nullptr;
}

bool PluginHostService::state(const Model &m, int32_t id, std::string &bytes, bool forSnapshot) const {
    if (PluginProcessor *p = instance(id)) return forSnapshot ? p->getStateForSnapshot(bytes) : p->getState(bytes);
    if (const PluginSlot *slot = findSlot(m, id)) { bytes = slot->state.str(); return true; } // missing: keep the saved state
    return false;
}

void PluginHostService::captureLiveState(Model &m) const {
    for (auto &t : m.tracks)
        for (auto &slot : t.plugins) {
            std::string state;
            if (PluginProcessor *p = instance(slot.id); p && p->getState(state)) slot.state.assign(std::move(state));
        }
}

PluginHostService::PluginMap PluginHostService::offlineCopies(const Model &m) const {
    PluginMap out;
    for (const auto &t : m.tracks)
        for (const auto &slot : t.plugins) {
            PluginProcessor *live = instance(slot.id);
            if (!live || !live->failure().empty()) continue; // as heard live
            std::string err, state;
            std::shared_ptr<PluginProcessor> p(create(slot.format, slot.path, slot.classId, true, err));
            if (!p) continue;
            if (this->state(m, slot.id, state)) p->setState(state);
            // Parameters set since the state was captured may not be in it yet (the live processor applies
            // them on its next block), so replay them; the offline instance applies them before its first block.
            std::vector<std::pair<uint32_t, double>> touched;
            live->touchedParameters(touched);
            for (const auto &[id, v] : touched) p->setParameter(id, v);
            out[slot.id] = std::move(p);
        }
    return out;
}

int32_t PluginHostService::activateNext(const Model &m, int32_t &slot, double &seconds, bool &changed) {
    slot = 0;
    seconds = 0;
    changed = false;
    const auto remaining = [&] { return static_cast<int32_t>(pending_.size() + launching_.size()); };
    const auto finished = [&](int32_t id, std::chrono::steady_clock::time_point t0) {
        seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        slot = id;
        changed = true;
        return remaining();
    };
    // Isolated plug-ins load in their own processes (ADR-0014 stage 2): first collect one whose host has answered.
    for (auto it = launching_.begin(); it != launching_.end(); ++it) {
        std::string err;
        const auto status = it->launch->poll(err);
        if (status == RemotePluginLaunch::Status::loading) continue;
        const int32_t id = it->slot;
        const auto t0 = it->started;
        auto launch = std::move(it->launch);
        launching_.erase(it);
        if (!findSlot(m, id)) return finished(0, t0); // removed while loading
        if (status == RemotePluginLaunch::Status::failed) errors_[id] = err;
        else if (!launch->stateAccepted()) errors_[id] = stateRejected(launch->stateError());
        else {
            errors_.erase(id);
            instances_[id] = std::shared_ptr<PluginProcessor>(launch->take());
            editCounts_[id] = instances_[id]->editCount(); // values reported while loading are not edits
            if (workgroupPort_) instances_[id]->shareWorkgroup(workgroupPort_);
        }
        return finished(id, t0);
    }
    if (pending_.empty() && launching_.empty()) return -1;
    while (!pending_.empty()) {
        const int32_t id = pending_.front();
        const PluginSlot *s = findSlot(m, id);
        if (!s || instances_.count(id)) { pending_.erase(pending_.begin()); continue; } // removed or loaded meanwhile
        const auto t0 = std::chrono::steady_clock::now();
        if (isolates(*s)) {
            if (launching_.size() >= kMaxParallelLaunches) break;
            pending_.erase(pending_.begin());
            errors_.erase(id);
            std::string err;
            const std::string state = s->state.str();
            auto launch = launchRemotePlugin(hostPath_, s->format, s->path, s->classId, sampleRate_, kMaxBlock,
                                             loadTimeoutMs_, s->state.empty() ? nullptr : &state, true, err);
            if (!launch) { errors_[id] = err; return finished(id, t0); }
            launching_.push_back({id, std::move(launch), t0});
            continue; // start the next one too; none of them blocks this thread
        }
        pending_.erase(pending_.begin());
        errors_.erase(id);
        instantiate(*s); // third-party code runs here, on the caller's (main) thread
        return finished(id, t0);
    }
    return remaining() > 0 ? remaining() : -1; // slot 0: hosts are still loading
}

bool PluginHostService::loading(int32_t id) const {
    return std::find(pending_.begin(), pending_.end(), id) != pending_.end() ||
           std::any_of(launching_.begin(), launching_.end(), [&](const Launching &l) { return l.slot == id; });
}

bool PluginHostService::cancelPending() {
    if (pending_.empty() && launching_.empty()) return false;
    for (const auto &l : launching_) pending_.push_back(l.slot);
    launching_.clear(); // kills hosts still loading
    for (int32_t id : pending_)
        if (!instances_.count(id)) errors_[id] = "Not loaded: loading was cancelled; saved state preserved";
    pending_.clear();
    return true;
}

bool PluginHostService::reload(const Model &m, int32_t id, std::string &err) {
    const PluginSlot *s = findSlot(m, id);
    if (!s) { err = "no such plug-in slot"; return false; }
    if (auto it = instances_.find(id); it != instances_.end()) {
        if (!it->second || it->second->failure().empty()) return true;
        instances_.erase(it); // a failed isolated instance restarts from the last saved state; snapshots release the old one
        failed_.erase(id);
    }
    pending_.erase(std::remove(pending_.begin(), pending_.end(), id), pending_.end());
    std::erase_if(launching_, [&](const Launching &l) { return l.slot == id; });
    const bool ok = instantiate(*s);
    if (!ok) err = errors_[id];
    return ok;
}

void PluginHostService::setWorkgroupPort(uint32_t port) {
    if (port && port == workgroupPort_) { releaseMachSendRight(port); return; } // same workgroup (one name per port)
    releaseMachSendRight(workgroupPort_);
    workgroupPort_ = port;
    for (const auto &[id, p] : instances_)
        if (p && p->isolated()) p->shareWorkgroup(workgroupPort_);
}

// Returns the plug-ins edited in their editors; `failed` collects isolated ones whose host failed (not an edit).
std::vector<int32_t> PluginHostService::poll(std::vector<int32_t> *failed) {
    std::vector<int32_t> changed;
    // Edits made in plug-in editors change what the project will save.
    for (const auto &[id, p] : instances_) {
        const uint64_t count = p ? p->editCount() : 0;
        uint64_t &known = editCounts_[id];
        if (count == known) continue;
        known = count;
        changed.push_back(id);
    }
    // Isolated plug-ins (ADR-0014): a host that crashed or stopped answering is reported on its track.
    for (const auto &[id, p] : instances_) {
        if (!p || !p->isolated()) continue;
        p->poll();
        if (!p->failure().empty() && failed_.insert(id).second) {
            if (failed) failed->push_back(id);
            else changed.push_back(id);
        }
    }
    return changed;
}

bool PluginHostService::takeEditorKey(int32_t &slot, PluginProcessor::EditorKey &key) {
    for (const auto &[id, p] : instances_)
        if (p && p->isolated() && p->takeEditorKey(key)) { slot = id; return true; }
    return false;
}

static size_t stateHash(PluginProcessor *p) {
    std::string bytes;
    return p && p->getState(bytes) ? std::hash<std::string>{}(bytes) : 0;
}

void PluginHostService::noteEditorOpened(int32_t id) {
    if (!editorStates_.count(id)) editorStates_[id] = stateHash(instance(id));
}

void PluginHostService::rememberEditorStates() {
    for (auto &[id, hash] : editorStates_) hash = stateHash(instance(id));
}

bool PluginHostService::editorStatesChanged() const {
    for (const auto &[id, hash] : editorStates_)
        if (PluginProcessor *p = instance(id); p && stateHash(p) != hash) return true;
    return false;
}

} // namespace dalnok
