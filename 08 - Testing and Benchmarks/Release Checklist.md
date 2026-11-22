# Release Checklist

What a Dalnok release has to meet before it is tagged. Versions are `0.MINOR.PATCH` until 1.0:
- **MINOR** (0.2.0, 0.3.0): a roadmap phase or a group of user-facing features is complete and verified.
- **PATCH** (0.2.1): fixes only, no new features and no project-format change that older builds of the same minor can't read.

Written down for 0.3.0 from what gated 0.2.0 (see CURRENT_STATE, 2026-11-20).

## 1. Scope (MINOR releases)
- The phase or feature set the release names is done on the roadmap, and every step marked `verified` in
  `site/parity.json` has a test, self-test or measurement behind it.
- Anything that needs the owner's hardware or ears is either checked on the hardware or listed as not verified in the
  release notes. Nothing is described as working without evidence.

## 2. Quality gate (every release)
Run on the release commit, on this Mac (real devices attached) unless noted.

| Check | Command |
|---|---|
| Generated API is current | `python3 scripts/gen-api.py --check` |
| Engine tests, ASan, TSan, live smoke, self-test | `DALNOK_SANITIZE=1 scripts/check.sh` |
| Plug-in hosting (test VST3, CLAP, AU) | `scripts/ci/plugin-host.sh` |
| Isolated hosting, crash/hang containment | `scripts/ci/plugin-isolation.sh`, `scripts/ci/plugin-recovery.sh` |
| Plug-in scan containment | `scripts/ci/plugin-scan.sh` |
| Recording crash recovery | `scripts/ci/record-crash.sh`, `scripts/ci/recovery-smoke.sh` |
| Duplex device validation | `scripts/ci/duplex-probe.sh` |
| Audio-thread effect analysis | `scripts/ci/rt-effects.sh` |
| Parsers and importers | `scripts/ci/fuzz.sh 120` (then 1,000 save/load round trips) |
| Self-test, both themes, both rates | Graphite at 48 kHz and Warm Analog at 44.1 kHz (`DALNOK_SAMPLE_RATE=44100`), with the test plug-ins |
| Real hardware (when attached) | self-test with `DALNOK_TEST_AUDIO_INPUT=<interface>`; `DALNOK_TEST_LOOPBACK=<interface>:<loopback input> swift test --filter HardwareLoopback` |
| CI | every job green on the release commit on GitHub |

A failure blocks the release until it is fixed, or understood and recorded as a known issue that doesn't affect
users' projects or audio.

## 3. Package and publish
1. Update `CHANGELOG.md` (move Unreleased under the version and date), `CURRENT_STATE.md`, the roadmap and
   `site/parity.json`; write the development journal entry.
2. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `scripts/bundle.sh`.
3. Merge to `main` (merge commits; history isn't rewritten, so earlier tags stay valid).
4. `scripts/release.sh` builds `dist/Dalnok-<version>.zip` and prints its SHA-256. Launch the bundled app once.
5. Tag `v<version>` on `main` and publish the GitHub release with the zip and its SHA-256
   (`gh release create v<version> dist/Dalnok-<version>.zip --notes-file …`).
6. The status site is published separately and only with the owner's go-ahead (`scripts/publish-site.sh`).

## 4. Screenshots, videos and documentation (every release; owner rule, 2026-11-21)
Every release retakes the README's screenshots and videos from the release build, to the same standard as the
previous ones, and updates the README and all documentation that describes what changed. Rules:
- Generated projects only (`scripts/make-test-project.sh`), built-in or Apple plug-ins only, the audio device name
  hidden (captures do this), never the owner's material.
- **Stills** per theme and version (Graphite; Warm Analog; Prism dark and light; Atelier light and dark):
  `DALNOK_THEME=<theme> DALNOK_VARIANT=<dark|light> Dalnok <project> --gallery <dir>` writes the hero frame
  (arrangement playing with the mixer and the device chain open, `00-hero.png`) and the eleven review frames. README
  stills are the hero frame scaled to 1800 px wide (`sips -Z 1800`), plus the piano roll and Settings.
- **One command does all of it:** `scripts/dev/readme-media.sh` (unlocked screen, Screen Recording allowed, ffmpeg,
  no other Dalnok running). For each of the six looks it writes the hero, mixer, piano roll and Composition Overview
  stills, a window tour and a plug-in clip (GIF in `assets/screenshots/`, MP4 in `assets/videos/`), and restores the
  preferences it changed.
- **Tours** (per theme and version): real screen recordings of `Dalnok <project> --tour` with `DALNOK_TOUR_FRAMES=0`,
  cropped to the window it prints, with the pointer parked off-window so no tooltip shows.
- **Plug-in clips** (per theme and version): `DALNOK_TOUR_MODE=plugin-ops` adds Channel EQ and Compressor to an empty
  track, turns them, keys the compressor from the kick, bypasses, folds, adds and reorders Apple's AUDelay and
  removes them all, over a 4-bar loop. The recording is cropped to the device panel it prints.
- Update the README's feature list and theme section, `06 - Design/` notes that changed, and the site screenshots
  (`--screenshots site/screenshots`; publishing the site still needs the owner's go-ahead).

## 0.3.0
Scope: Phase 4 (professional production) complete: VST3, AU and CLAP hosting with sidechains (AU now verified),
mixer, buses, sends, automation, delay compensation (cycle wrap fixed), comping, stacks and track groups. Plus the
recording work: separate input and output devices, Input Monitoring, a live waveform while recording, and measured
latency compensation, all checked on a Scarlett Solo 4th Gen.
