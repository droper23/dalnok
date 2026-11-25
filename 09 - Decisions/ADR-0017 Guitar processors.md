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
  The shifting heads vary around that latency while a shift is under way; once none is (within a cent) the output
  fades to a single tap at exactly the reported latency and the heads are parked there (review, 2026-11-25: left
  straddling, the two heads formed a comb). Detection runs at ~24 kHz over a 32 ms window, its lags spread over the
  following samples so no callback carries the whole search; the latency's span is even at every rate.
  The bend control releases correction outside the specified distance from a scale target; it does
  not identify musical intent. It is not chord separation, formant preservation or note editing.
- `dalnok:guitar-studio` (Guitar Studio), revised 2026-11-25 into a modular rig so a guitar track needs no
  separate effect plug-ins: eight slots in series, each holding any of 20 modules (Noise Gate, Compressor, Boost,
  Overdrive, Distortion, Fuzz, Amp Clean/Crunch/Lead, Cabinet, EQ, Wah, Chorus, Flanger, Phaser, Tremolo, Vibrato,
  Delay, Reverb, Spring) in any order (`fx/guitar_modules.*`). The module set lives in ordinary parameters
  (per slot: module, switch, six knobs) so state, automation, presets and the C API need nothing new; titles, text,
  defaults and visibility follow the chosen module, and choosing a module resets its slot to that module's defaults.
  Slots crossfade over 10 ms when switched or swapped, so edits while playing don't click. Drives and amps clip at
  4x oversampling (8th-order Chebyshev I, zero latency) with first-order antiderivative anti-aliasing. Cabinet
  labels describe voicings; these are not captured cabinets, IR convolution, or reproductions of commercial amplifiers.
  A stereo delay may use 2 x 2.05 s of buffer per slot, so each slot preallocates that pool (about 0.8 MB at 48 kHz).
  States from the first, fixed-chain Studio (parameters 0-22, saved 2026-11-24) load as the equivalent rig (gate,
  compressor, amp voice, cabinet, then chorus/tremolo/echo/room where in use); its Output Mix has no equivalent.
  A slot strip in the device (every look) shows the rig in order: drag to reorder, click a light to switch, + to add.
- Native themed device controls and a real input-pitch/error/confidence display, plus factory
  starting presets (Device ▸ Factory Presets: three for Tune, eight complete rigs for Studio; Studio's modules
  are edited from Device ▸ Add Module and ▸ Modules). Like knob moves, a preset or module edit changes plug-in parameters, which sit
  outside the undoable model, so it is not an undo step. Both remain independently insertable, with Tune before Studio recommended.
- No external dependency, proprietary asset, importer translation or project-format change.

Verification is recorded in GuitarTuneTests, GuitarStudioTests and SelfTest+Guitar. Numerical checks
establish defined behavior, not listening preference or parity with premium commercial products.

## Addendum (2026-11-25): editors
Both plug-ins get native editors in the plug-in window instead of the generic parameter list. They talk to the engine only
through the plug-in parameter API, poll it (Studio 10 Hz, Tune 30 Hz), and show only measured telemetry. All hardware is
drawn procedurally from shapes and seeded noise; names, colours and layouts are Dalnok's own, with no product's trade dress.
Revised the same day at the owner's request: the hardware-rig look was replaced by the "space" style (pale matte modules on a
black chassis, raised black controls, orange and blue light). It emulates the lighting and materials of Baby Audio's Spaced Out
but not its layout, controls or branding. Guitar Studio gained read-only level meters (input, and after each slot) so the
screens react to real audio.
