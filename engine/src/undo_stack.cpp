// SPDX-License-Identifier: GPL-3.0-or-later
#include "undo_stack.hpp"
#include "engine.hpp"

#include <unordered_map>

namespace dalnok {

struct UndoStack::ModelDelta {
    Model rest;                      // the target model without its clips
    bool sameOrder = true;           // target clip ids are the base's, in the same order
    std::vector<DalnokClipId> order; // otherwise the target's clip ids in order
    std::vector<ClipState> changed;  // target clips that are absent from or different in the base
};

UndoStack::Step::Step() = default;
UndoStack::Step::Step(std::string n, std::unique_ptr<Model> m, std::vector<ParameterValue> p)
    : name(std::move(n)), model(std::move(m)), parameters(std::move(p)) {}
UndoStack::Step::Step(Step &&) noexcept = default;
UndoStack::Step &UndoStack::Step::operator=(Step &&) noexcept = default;
UndoStack::Step::~Step() = default;
UndoStack::UndoStack() = default;
UndoStack::~UndoStack() = default;

void setParameterInModel(Model &model, const ParameterValue &v) {
    if (v.field == ParameterField::masterGain) { model.masterGainDb = v.value; return; }
    TrackState *track = model.track(v.track);
    if (!track) return;
    switch (v.field) {
        case ParameterField::gain: track->gainDb = v.value; break;
        case ParameterField::pan: track->pan = v.value; break;
        case ParameterField::mute: track->muted = v.value != 0; break;
        case ParameterField::solo: track->solo = v.value != 0; break;
        case ParameterField::masterGain: break;
    }
}

namespace {
std::unique_ptr<UndoStack::ModelDelta> makeDelta(Model target, const Model &base);
Model applyDelta(UndoStack::ModelDelta d, const Model &base);
} // namespace

void UndoStack::clear() {
    undo_.clear();
    redo_.clear();
    depth_ = 0;
}

void UndoStack::beginGroup(const std::string &name) {
    if (depth_++ == 0) {
        groupName_ = name;
        recorded_ = false;
    }
}

void UndoStack::endGroup() {
    if (depth_ > 0) --depth_;
}

void UndoStack::trimAndClearRedo() {
    if (undo_.size() > kMaxSteps) undo_.erase(undo_.begin());
    redo_.clear();
}

void UndoStack::recordSnapshot(const char *name, Model before) {
    if (depth_ == 0 || !recorded_) {
        // The previous step will next be applied to the state before this edit: compact it against that state.
        compactTop(undo_, before);
        undo_.emplace_back(stepName(name), std::make_unique<Model>(std::move(before)), std::vector<ParameterValue>{});
        if (depth_) recorded_ = true;
    } else if (!undo_.back().model) {
        // Promote the parameter group to a snapshot of its original state.
        for (const auto &value : undo_.back().parameters) setParameterInModel(before, value);
        undo_.back().model = std::make_unique<Model>(std::move(before));
        undo_.back().parameters.clear();
    }
    trimAndClearRedo();
}

void UndoStack::recordParameter(const char *name, const ParameterValue &old, const Model &current) {
    if (depth_ == 0 || !recorded_) {
        push(undo_, Step(stepName(name), nullptr, {old}), current);
        if (depth_) recorded_ = true;
    } else if (!undo_.back().model) {
        auto &values = undo_.back().parameters;
        if (std::none_of(values.begin(), values.end(), [&](const auto &v) { return v.track == old.track && v.field == old.field; }))
            values.push_back(old);
    }
    trimAndClearRedo();
}

UndoStack::Step UndoStack::take(bool undo) {
    auto &from = undo ? undo_ : redo_;
    Step step = std::move(from.back());
    from.pop_back();
    return step;
}

Model UndoStack::target(Step &step, const Model &current) {
    return step.model ? std::move(*step.model) : applyDelta(std::move(*step.delta), current);
}

void UndoStack::pushInverse(bool undo, Step inverse, const Model &current) {
    push(undo ? redo_ : undo_, std::move(inverse), current);
}

void UndoStack::compactTop(std::vector<Step> &stack, const Model &base) {
    if (stack.empty() || !stack.back().model) return;
    stack.back().delta = makeDelta(std::move(*stack.back().model), base);
    stack.back().model.reset();
}

void UndoStack::push(std::vector<Step> &stack, Step step, const Model &base) {
    compactTop(stack, base);
    stack.push_back(std::move(step));
}

namespace {

std::unique_ptr<UndoStack::ModelDelta> makeDelta(Model target, const Model &base) {
    auto d = std::make_unique<UndoStack::ModelDelta>();
    // Usually the clips line up by index (an edit changed a few in place); look ids up only when they don't.
    std::unordered_map<DalnokClipId, size_t> at;
    const auto find = [&](DalnokClipId id) -> const ClipState * {
        if (at.empty() && !base.clips.empty()) {
            at.reserve(base.clips.size());
            for (size_t i = 0; i < base.clips.size(); ++i) at.emplace(base.clips[i].id, i);
        }
        const auto it = at.find(id);
        return it == at.end() ? nullptr : &base.clips[it->second];
    };
    d->sameOrder = target.clips.size() == base.clips.size();
    for (size_t i = 0; i < target.clips.size(); ++i) {
        const ClipState &c = target.clips[i];
        const ClipState *b = i < base.clips.size() && base.clips[i].id == c.id ? &base.clips[i] : nullptr;
        if (!b) { d->sameOrder = false; b = find(c.id); }
        if (!b || !(*b == c)) d->changed.push_back(c);
    }
    if (!d->sameOrder) {
        d->order.reserve(target.clips.size());
        for (const auto &c : target.clips) d->order.push_back(c.id);
    }
    target.clips.clear();
    target.clips.shrink_to_fit();
    d->rest = std::move(target);
    return d;
}

Model applyDelta(UndoStack::ModelDelta d, const Model &base) {
    Model m = std::move(d.rest);
    std::unordered_map<DalnokClipId, ClipState *> changed;
    changed.reserve(d.changed.size());
    for (auto &c : d.changed) changed.emplace(c.id, &c);
    if (d.sameOrder) {
        m.clips = base.clips;
        if (!changed.empty())
            for (auto &c : m.clips)
                if (auto it = changed.find(c.id); it != changed.end()) c = std::move(*it->second);
        return m;
    }
    std::unordered_map<DalnokClipId, size_t> at;
    at.reserve(base.clips.size());
    for (size_t i = 0; i < base.clips.size(); ++i) at.emplace(base.clips[i].id, i);
    m.clips.reserve(d.order.size());
    for (DalnokClipId id : d.order) {
        if (auto it = changed.find(id); it != changed.end()) m.clips.push_back(std::move(*it->second));
        else if (auto b = at.find(id); b != at.end()) m.clips.push_back(base.clips[b->second]);
    }
    return m;
}

} // namespace
} // namespace dalnok
