---
status: accepted
date: 2026-11-16
---
# ADR-0001: Independent engine on permissive libraries

**Context.** We need a foundation that's legally redistributable, architecturally ours, and fast.
**Decision.** Strategy C. We write our own C++20 engine on system frameworks and permissive
libraries. No JUCE (AGPLv3 or commercial) and no Tracktion Engine (GPLv3 or commercial).
**Consequences.** Slower to reach plugin hosting, delay compensation, and comping, but we get full
control of threading, the model, and the unified clip/timeline design.
**Rejected:** Tracktion + JUCE (3.15), JUCE-only (3.20), reuse from Ardour or Audacity (2.70), Rust engine (4.10). See [[Foundation Evaluation]].
