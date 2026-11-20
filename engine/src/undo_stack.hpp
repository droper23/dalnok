// Undo and redo history for one engine (A-06): snapshot steps (structural edits), compact parameter steps
// (ADR-0012), groups, and snapshot steps below the top of each stack stored as clip deltas (A-03).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "dalnok/dalnok.h"

#include <memory>
#include <string>
#include <vector>

namespace dalnok {

struct Model;
struct ClipState;

enum class ParameterField { gain, pan, mute, solo, masterGain };
struct ParameterValue {
    DalnokTrackId track;
    ParameterField field;
    float value;
};
void setParameterInModel(Model &model, const ParameterValue &value);

class UndoStack {
public:
    static constexpr size_t kMaxSteps = 500;

    // A snapshot step below the top of its stack, stored against the state it will be applied to: everything but
    // the clips, the clips that differ from that state, and the clip order if it changed. Unchanged clips are taken
    // from the live model when the step is applied.
    struct ModelDelta;
    struct Step {
        std::string name;
        std::unique_ptr<Model> model;          // a snapshot step at the top of its stack
        std::vector<ParameterValue> parameters; // a parameter step (model and delta null)
        std::unique_ptr<ModelDelta> delta;     // a snapshot step once another is pushed above it
        Step();
        Step(std::string name, std::unique_ptr<Model> model, std::vector<ParameterValue> parameters);
        Step(Step &&) noexcept;
        Step &operator=(Step &&) noexcept;
        ~Step();
        bool snapshot() const { return model || delta; }
    };

    UndoStack();
    ~UndoStack();
    bool canUndo() const { return !undo_.empty(); }
    bool canRedo() const { return !redo_.empty(); }
    std::string undoName() const { return undo_.empty() ? "" : undo_.back().name; }
    std::string redoName() const { return redo_.empty() ? "" : redo_.back().name; }
    void clear();

    // Groups make one step of several edits; the outermost group's name is the step's name.
    void beginGroup(const std::string &name);
    void endGroup();
    void closeGroups() { depth_ = 0; } // undo and redo end any open group

    // A successful structural edit; `before` is the model before it.
    void recordSnapshot(const char *name, Model before);
    // A parameter edit about to be applied to `current`; `old` is its previous value.
    void recordParameter(const char *name, const ParameterValue &old, const Model &current);

    // Undo (or redo): takes the top step. A snapshot step's model is rebuilt against `current` (the live model).
    Step take(bool undo);
    static Model target(Step &step, const Model &current);
    // Pushes the step that reverses it onto the other stack; `current` is the live model before it changes.
    void pushInverse(bool undo, Step inverse, const Model &current);

private:
    static void compactTop(std::vector<Step> &stack, const Model &base);
    static void push(std::vector<Step> &stack, Step step, const Model &base);
    std::string stepName(const char *name) const { return depth_ && !groupName_.empty() ? groupName_ : name; }
    void trimAndClearRedo();

    std::vector<Step> undo_, redo_;
    int depth_ = 0;
    bool recorded_ = false;
    std::string groupName_;
};

} // namespace dalnok
