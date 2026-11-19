---
status: accepted
date: 2026-11-18
---
# ADR-0012: Compact undo for scalar mixer edits

**Context.** ADR-0005 uses a full model copy for every undoable edit. A mixer fader edit touches one
scalar, yet retaining hundreds of these edits copies every clip and consumes memory proportional to the
entire project. Profiling exposed a significant cost at 4,096 clips.

**Decision.** Gain, pan, mute, solo, and master gain edits validate their input before changing the model,
record the prior scalar value, and publish the corresponding runtime atomic. Undo and redo exchange scalar
values. Grouped edits record the first value of each affected scalar. If a group contains any other edit,
its compact entry is promoted to a model snapshot representing the start of the group. All other edits
retain ADR-0005's transactional model copy and snapshot-based undo. The undo limit and command surface
remain unchanged.

**Consequences.** Scalar-only undo memory scales with the number of changed fields rather than the project
size. Validation and scalar restoration must stay paired with each supported field; tests cover failed
edits, mixed groups, and randomized undo back to the serialized baseline. This decision supersedes only
the whole-model requirement for those scalar edits in ADR-0005.
