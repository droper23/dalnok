---
status: accepted
date: 2026-11-16
---
# ADR-0003: C++20 engine, plain-C API, native Swift/AppKit UI
**Decision.** The engine is C++20. The only boundary is a C header. The macOS UI is Swift and AppKit,
with Metal for heavy views later. Other platforms get their own front ends on the same C API.
**Why C++ over Rust:** the VST3 SDK is C++, Signalsmith is C++, and Clang's `nonblocking` effect
analysis gives compile-time real-time guarantees.
**Why AppKit over SwiftUI for the main views:** a custom-drawn timeline needs precise control and
performance. SwiftUI may be used for inspectors and preferences.
**Why a C API over Swift–C++ interop:** a stable ABI, fast builds, and a deliberate surface.
**Rejected:** a JUCE or Qt cross-platform UI (not native enough), Electron (fails the performance goals).
