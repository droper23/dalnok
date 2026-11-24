---
status: accepted
date: 2026-11-24
---
# ADR-0017: Native guitar processors

The owner requested guitar intonation correction and a guitar effects suite, and specified recorded
single-note pitch correction. Extend ADR-0011's built-in scope with two original guitar processors,
using the existing parameter, automation, state, undo, render and discovery interfaces. No new C API.

- `dalnok:guitar-tune` (Guitar Tune): clean monophonic input before distortion, 65–1400 Hz;
  chromatic/major/minor targets, reference tuning, amount, retune speed and correction-range tolerance.
  YIN-style bounded periodicity detection drives complementary windowed delay heads. Stereo shares
  the correction trajectory. Nominal latency is 25 ms + 8 samples, reported to host compensation.
  The shifting heads vary around that latency; this is not phase-coherent parallel processing.
  The bend control releases correction outside the specified distance from a scale target; it does
  not identify musical intent. It is not chord separation, formant preservation or note editing.
- `dalnok:guitar-studio` (Guitar Studio): linked gate/compression, oversampled nonlinear drive,
  tone and original cabinet filters, chorus/tremolo, echo and room. Cabinet labels describe voicings;
  these are not captured cabinets, IR convolution, or reproductions of commercial amplifiers.
- Native themed device controls and a real input-pitch/error/confidence display, plus factory
  starting presets (Device ▸ Factory Presets). Like knob moves, a preset changes plug-in parameters, which sit
  outside the undoable model, so it is not an undo step. Both remain independently insertable, with Tune before Studio recommended.
- No external dependency, proprietary asset, importer translation or project-format change.

Verification is recorded in GuitarTuneTests, GuitarStudioTests and SelfTest+Guitar. Numerical checks
establish defined behavior, not listening preference or parity with premium commercial products.
