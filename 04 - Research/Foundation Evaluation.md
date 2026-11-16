---
status: accepted
date: 2026-11-16
decision-owner: project owner (accepted 2026-11-16)
tags: [research, architecture, licensing]
---

# Foundation Evaluation

Working name: **Atrium** (placeholder). Related: [[Licensing]], [[Technology Decisions]].

## Requirements that drive the choice

- Native macOS UI (Swift/AppKit/Metal), with a portable engine behind a stable API ([[System Overview]]).
- A unified track model: timeline lanes and clip-launcher slots on the same tracks.
- Logic parity targets: comping and take folders, Flex Time/Pitch-style editing, stock instruments and FX, stacks, and the mixer.
- VST3 hosted first, then AU and CLAP.
- Generic in-DAW parameter editing for every hosted plugin, Ableton-style.
- Scriptable command system from day one.
- Architectural independence plus a legally clean, redistributable product.

## Licensing facts (verified 2026-11-16)

| Component | License | Notes |
|---|---|---|
| JUCE (v8/9) | AGPLv3 or commercial | Commercial tiers: Starter free up to $20k revenue, Indie up to $300k, and Pro. [juce.com/get-juce](https://juce.com/get-juce/) |
| Tracktion Engine 3 | GPLv3 or commercial | It is a JUCE module, so it also needs a JUCE license. It has a clip launcher (ClipSlot/LaunchHandle). [GitHub](https://github.com/Tracktion/tracktion_engine) |
| Ardour | GPLv2+ | The engine (libardour) is tightly coupled to its session model and GTK UI, which makes it hard to extract. |
| Audacity 4.0 | GPLv3 | Released 2026-09-03 with a Qt6 rewrite. Shipped without MIDI tracks, a mixer, or macros. Editor-centric. [Phoronix](https://phoronix.com/news/Audacity-4.0-Released) |
| VST3 SDK 3.8+ | **MIT** (since Oct 2025) | It used to be GPLv3 or proprietary. This change is what makes an independent permissive engine practical. [Steinberg](https://steinbergmedia.github.io/vst3_dev_portal/pages/VST+3+Licensing/VST3+License) |
| CLAP | MIT | Open plugin standard with per-note modulation. |
| AU hosting | Apple system frameworks | AudioToolbox and AVFAudio. Needs no third-party code. |
| Signalsmith Stretch | MIT | High-quality time stretching and pitch shifting, the basis for Flex-style editing. [GitHub](https://github.com/Signalsmith-Audio/signalsmith-stretch) |
| Rubber Band | GPLv2+ or commercial | Only an option if the project is GPL. |
| DAWproject | MIT | Open interchange format. |

**Independent product vs. independent implementation.** A DAW with its own UI, branding, and project model is an independent *product*, even when it links GPL code. But if it links Tracktion Engine (GPLv3) and JUCE (AGPLv3), the shipped binary is a combined work under AGPL-compatible terms, its architecture is shaped by Tracktion's `Edit` and `ValueTree` model, and closed-source redistribution would need paid licenses from two vendors. "Independent" in that sense is cosmetic.

## Strategies compared

Each strategy is scored 1–5. The weights are performance 20, development time 20, maintainability 15, extensibility 15, licensing freedom 15, and independence 15.

| Strategy | Perf | Dev time | Maint | Extend | License | Indep | **Weighted** |
|---|---|---|---|---|---|---|---|
| A. Tracktion Engine + JUCE beneath a Swift UI | 4 | 5 | 3 | 3 | 2 | 1 | 3.15 |
| A′. JUCE only, for audio I/O and plugin hosting, with our own engine | 4 | 3 | 3 | 4 | 2 | 3 | 3.20 |
| B. Selective reuse from Ardour or Audacity (GPL) | 3 | 3 | 2 | 3 | 2 | 3 | 2.70 |
| **C. Independent engine in C++20 on permissive libraries** | 5 | 2 | 4 | 5 | 5 | 5 | **4.25** |
| C′. The same as C, written in Rust | 5 | 2 | 4 | 4 | 5 | 5 | 4.10 |

### Why A loses despite being fastest
Tracktion would get us to plugin hosting, delay compensation, and comping fastest. The cost is three things:
- **Ownership.** The project model, threading, and graph would belong to Tracktion. The unified arrangement and launcher model, along with our command system, would be built around its `Edit` model instead of being designed from scratch.
- **UI.** We'd carry all of JUCE even though the UI is Swift.
- **License.** We'd be locked into AGPL, with upstream coupling.

### Why B loses
Ardour and Audacity are monoliths. Extracting subsystems from them costs more than writing focused code, and the result is still GPL with someone else's architecture.

### Why C wins now
Before October 2025, hosting VST3 forced a project to be GPL or proprietary. Now every foundation layer is permissive or a system framework:
- Core Audio for audio I/O.
- MIT VST3 and CLAP, plus Apple AU, for plugin hosting.
- Signalsmith for time stretching.
- ExtAudioFile on macOS, and dr_libs or libsndfile elsewhere, for decoding audio files.

The engine work is ours: the audio graph, delay compensation, disk streaming, and scheduling. That cost is real, but it's the architecture the brief asks us to own, and Phase 1 needs only a small slice of it.

### C++20 vs Rust (C vs C′)
C++20 was chosen. Rust's compile-time safety is attractive, but the deciding factors favor C++:
1. VST3 is a C++ SDK. Hosting it from Rust needs immature bindings.
2. Swift 6 calls C++ directly, so a native UI needs no C shim on macOS. A C ABI is still added later for other front ends.
3. The DSP ecosystem we depend on, such as Signalsmith, is C++.
4. Real-time safety can be enforced with tooling: Clang's RealtimeSanitizer (`-fsanitize=realtime`), TSan and ASan in CI, and a no-allocation and no-lock rule in callback code.

Rust is still a good fit for isolated non-real-time components later, such as analysis or scripting sandboxes, if needed.

## Rejected
- **Forking Audacity 4:** it's editor-first, has no MIDI or mixer in 4.0, and would make us a reskin.
- **Ardour as a base:** GPL, a GTK-coupled monolith, and a reskin risk.
- **A Qt or JUCE cross-platform UI:** conflicts with the decision to build native macOS polish first.
- **An Electron or web UI:** fails the performance and binary-size goals.

## Recommendation
Strategy C: an independent C++20 engine on permissive libraries, a native Swift UI on macOS, and VST3 hosted first. **Accepted by the owner on 2026-11-16, with GPL-3.0-or-later** (see [[Licensing]]).
