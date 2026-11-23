---
created: 2026-11-22
status: released 2026-11-23 (v0.4.0); open items below were stated in the release notes or moved to the UI audit's open list
related: "[[Release Checklist]]", "[[Atelier Audit 2026-11-22]]", "[[02 - Master Roadmap]]"
---
# Release 0.4.0 plan

0.3.0 closed Phase 4 (professional production). Since then `main` has gained a group of user-facing features large
enough for a MINOR release (Release Checklist §1): four themes with light and dark versions, the Library (now with a
file browser) and the Inspector, phase invert, the Composition Overview, Dalnok Compressor with a sidechain, the
clip launcher's Phase 5 work, the redrawn Atelier with moving instrument figures, the resizable device panel, and the
first-launch look chooser. Project format 14 (0.3.0 builds can't open projects that use phase invert).

Proposed name: **0.4.0 "Looks and panels"**: the four themes, the Library and Inspector, and the clip launcher.

## What has to happen first (in order)

### 1. Finish what is half done
- [x] **Settings restructured** (2026-11-23: nine pages and search; per-page self-test steps for the pages and search). Today Settings is a flat list of sections that grew one feature at a
      time. Group it into a sidebar of clear pages (General, Appearance, Audio, MIDI, Recording, Plug-ins, Shortcuts,
      Files and Library, Advanced), one control style per theme, search across settings, and a self-test step per page.
      Move Library preferences (Preview audio, added folders) and the device panel's height into it.
- [x] **Graphite, Warm Analog and Prism brought up to Atelier's level** (2026-11-23, rounds 1 and 2 of `06 - Design/UI Audit 2026-11-23.md`; round 3 items listed there): each theme's plug-in family figures
      (moving where it helps, linked to their parameter rows, drag directions shown), their own master-meter drawing,
      Library and Inspector drawn in the idiom, the first-launch cards. Atelier's audit is the template: write one audit
      note per theme (reviewers + owner answers), then fix in the audit's order.
- [ ] Atelier audit leftovers: C7 (selected strip's wash to the divider, Master's rule), C12 (title block and the
      section marker on the centreline), A6/D5 re-check on the dark plate, VoiceOver by ear.
- [ ] Graphite's README tour and plug-in clip (needs Screen Recording for the terminal), then every look's (they predate
      the moving figures and the resizable panel).

### 2. Full bug and edge-case pass (owner: "ready for the next release")
Run as a checklist, each item with a self-test step, engine test or recorded manual result:
- [ ] **Keyboard focus everywhere:** after using each panel (Library, Inspector, mixer, device panel, piano roll,
      launcher, Composition Overview, palette, Settings), Space plays and stops and bare shortcuts work; text fields
      still own their keys. (The window-level fix landed 2026-11-22; check every surface with real keys via
      `scripts/dev/drive.swift`, which needs Accessibility access for the terminal.)
- [ ] **Theme switching under load:** switch looks while playing, recording (refused), with plug-in editors open, with
      the first-launch window open, with Settings open; undo history and selection kept.
- [ ] **Library ▸ Files:** unreadable folders, removed or renamed added folders, network volumes, very large folders
      (10k files), files that fail to decode, previews of long files, preview while the transport plays, privacy
      prompts (Desktop, Downloads) answered No.
- [ ] **Device panel:** height at its limits on a small window (13" at 1280×800), fold and unfold at every height,
      Warm Analog's pedals when tall, plug-ins with 1, 8, 20 and 2,800 parameters.
- [ ] **Figures:** every family with bypass, while automation plays, with Reduce Motion, CPU while idle (FigureClock
      runs only while figures are on screen; measure with `--perf`).
- [ ] **Projects:** open 0.3.0 projects, save, reopen in 0.3.0 (format 14 refusal message), crash recovery after a
      kill during each new feature, the fuzzers (`scripts/ci/fuzz.sh 120`).
- [ ] **Sample rates and devices:** 44.1 / 48 / 96 kHz, device change mid-session, AirPods (Bluetooth) output.
- [ ] **Accessibility:** the 42-check audit in all six looks with both panels open, plus VoiceOver by ear (owner).
- [x] **Performance:** `--perf 20` in every look on the large project (Prism Dark and Light repeated 2026-11-23: 0 overloads, 0 missed, main p99 8 ms).

### 3. Quality gate (Release Checklist §2), on the release commit
- [ ] `scripts/gen-api.py --check`; `DALNOK_SANITIZE=1 scripts/check.sh`; plug-in host, isolation, recovery and scan
      suites; record-crash and recovery smoke; duplex probe; rt-effects; fuzz 120 s + 1,000 round trips.
- [ ] Self-test matrix: six looks × 48 and 44.1 kHz, all PASS (machine SKIPs only).
- [ ] Hardware: the Scarlett loopback test and an input self-test (owner's hardware: ask first).
- [ ] CI green.

### 4. Package and publish (Release Checklist §3 and §4)
- [ ] README: feature list (Library ▸ Files, Inspector, looks, moving figures), stills, tours and plug-in clips for
      every look from the release build; first-launch look pictures regenerated (`readme-media.sh` does both).
- [ ] CHANGELOG Unreleased → `## [0.4.0] - <date>`; CURRENT_STATE, roadmap, parity, journal.
- [ ] Bump `CFBundleShortVersionString`/`CFBundleVersion` to 0.4.0 in `scripts/bundle.sh`; `scripts/release.sh`.
- [ ] Tag `v0.4.0`, GitHub release with the zip and SHA-256; site screenshots and `publish-site.sh` only with the
      owner's go-ahead.

## Known gaps to state in the release notes (unless fixed first)
- MIDI files can't be imported yet (the Library lists audio and projects only).
- Library files drop onto new tracks at the start; dropping at the pointer's time and track is not done.
- Power-loss recording test (Phase 2) not run.
- The app is ad-hoc signed, not notarized.
