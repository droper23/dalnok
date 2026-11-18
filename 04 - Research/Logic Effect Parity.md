---
created: 2026-11-17
status: research started
related: "[[Logic ProjectData Format]]", "[[Licensing]]"
---
# Logic Effect Parity

Owner goal (2026-11-17): imported Logic projects should sound exactly like Logic. Logic-only effects should become a suite of Dalnok plug-ins that sound the same as Apple's.

## Can Dalnok host Apple's effects directly?
No. Logic Pro Creator Studio 12.2 ships its effects inside the private `MADSP.framework`. They are not Audio Units, the app bundle contains no Audio Unit extensions (only Quick Look and thumbnail extensions), and MainStage is not installed. Loading the private framework would break Logic's license, would stop working on any Logic update, and could not ship with a GPL project. **Parity has to come from clean-room re-implementation.**

## Clean-room rules (proposed; owner and a lawyer should confirm)
- Learn behavior **only from audio Logic renders** and from **project files the owner saves**. Do not disassemble, decompile or `strings`-mine Logic binaries or resources for DSP or parameter tables.
- Use our own names (e.g. "Dalnok Channel EQ"). Say only that the plug-ins are "compatible with Logic projects"; do not use Apple's names or artwork.
- Drum Kit Designer depends on Apple's sample content. Whether Dalnok may play the samples installed on the owner's Mac needs a separate licence decision; we will not copy or redistribute them.

## Settings are readable
Each Logic-native plug-in in an `AuCU` record (tag 0x1a8, manufacturer `GAME`, `CLEM` for Drum Kit) has a body that starts with a header followed by a flat float32 parameter array:

| Offset | Content |
|---|---|
| +0 | block size (bytes) |
| +8 | parameter count |
| +12 | `GAMETSPP` |
| +20 | subtype (matches the record) |
| +28 | `count` × float32 parameters, in plug-in parameter order |

| Plug-in | Subtype | Params |
|---|---|---|
| Chorus | 0x91 | 5 |
| Limiter | 0xc7 | 13 |
| Channel EQ | 0xec | 52 (repeating per-band blocks: on, frequency, gain, Q) |
| ChromaGlow | 0x141 | 26 |
| ChromaVerb | 0x11f | 81 |
| Drum Kit | `ANML`/`CLEM` | different layout; names the kit's .exs file |

One Channel EQ instance uses a different, 12 KB layout (no `GAMETSPP` header). It may also store analyzer or curve data; this needs a sample. The last float in some arrays is uninitialized memory, so treat it as padding until a diff shows it matters.

Slot meanings must come from **diffs**: change one control in Logic, save, and diff the array. This takes a few minutes per plug-in with OS-level input.

## What "exact" can mean, per plug-in
Before any comparison, **render the same Logic project twice and null the two renders**. That measures Logic's own repeatability, which is the best match anyone can reach.

| Plug-in | Behavior | Realistic target | Method |
|---|---|---|---|
| Channel EQ | Linear and time-invariant (LTI) for each setting | **Bit-near null (−100 dB or better)** | Impulse and log-sweep renders; fit the exact filter coefficients from the impulse response; solve for the design formulas (frequency, gain and Q to coefficients, plus any oversampling or cramping fix) across a sweep of settings |
| Limiter | Deterministic, nonlinear | Null −60 to −90 dB | Step, burst and two-tone renders; identify the look-ahead, attack shape, release law, knee and ceiling |
| Chorus | Modulated delay | Close null if the LFO phase resets on play; otherwise spectral match | Impulse train under modulation; identify the LFO shape and rate law, base delay, depth law and interpolation |
| ChromaVerb | Algorithmic reverb, probably with random modulation | Perceptual or statistical match: energy decay per band, echo density, spectrum. Exact only if Logic is deterministic | First test Logic against itself. Then fit decay, density and colour per room type |
| ChromaGlow | Apple describes it as machine-learning saturation models | Perceptual match | Black-box neural modelling (as NAM does) per style, conditioned on drive, trained on Logic renders of noise, sweeps and music |
| Drum Kit (Drum Kit Designer) | Sample instrument | Needs a licence decision first | Owner's own drum instrument, or the installed Apple samples at runtime if that is allowed |

The order follows payoff per effort and how often each effect appears in the owner's projects: **Channel EQ → Limiter → Chorus → ChromaVerb → ChromaGlow**.

## Measurement harness (next build step)
1. **Template**: a Logic project the owner saves once. It has one audio track per variant and Dalnok-generated test signals: an impulse, log sweeps at −40/−20/−6/0 dBFS, multitone, noise bursts and silence.
2. **Variants**: Dalnok's importer already parses ProjectData. A writer patches the parameter floats in place (same length, no structural change) to make N variants per batch.
3. **Render**: Logic ▸ Export All Tracks as Audio Files (float WAV), driven by OS-level input. Check that the screen is unlocked first, per AGENTS.md.
4. **Compare**: `tools/` gets a null/fit tool: per-variant null depth, coefficient fits for LTI effects, and reports in `08 - Testing and Benchmarks`.
5. **Regression**: the measured renders become fixtures, and the Dalnok plug-ins must null against them in CI. CI keeps only small renders, or hashes plus the owner's local corpus.

### Findings (2026-11-17)
- **Logic accepts in-place edits to ProjectData**: replacing a referenced WAV's samples (same format and length) and changing values inside a record loaded without complaint. Logic keeps no checksum on either.
- **Moving an `AuCU` record to another strip by changing its header channel field (+14) and slot order (+18) does not work.** Logic loaded the project but showed the target strips empty. Insert linkage is held elsewhere, so the template must be laid out in Logic itself. Variants then patch only parameter floats inside existing records.
- **Test signal** (44.1 kHz, both channels unless noted). Each event is followed by silence for the tail:
  - impulse at 1 s;
  - 8 s exponential sweeps, 10 Hz to 22 kHz, at −30/−18/−6/−1 dBFS;
  - 1 kHz level staircase from −40 to 0 dBFS and back, 0.5 s steps;
  - 440 Hz bursts: 0 dBFS for 1 s, then −30 dBFS for 2 s, repeated four times;
  - independent L/R white noise at −12 dBFS;
  - left-only and right-only impulses.
- Logic exposes channel strips, slots and track headers through Accessibility. Their descriptions identify each control, so slot contents can be verified without screen capture.

### Measurement loop working (2026-11-17, `tools/logic-parity/`)
- **Template**: 10 stereo audio tracks at 44.1 kHz with the test signal. Effects inserted in Logic: Channel EQ on tracks 1 and 6–9, Limiter on 2, Chorus on 3, ChromaVerb on 4, ChromaGlow on 5. Track 10 has no plug-in and serves as the reference.
- **Variant loop**: `batch.sh` closes the project, restores the base ProjectData, patches the floats, reopens the project, runs Export All Tracks (32-bit float), and checks through Accessibility that Bypass is off. One batch of 5 Channel EQ variants takes about 2.5 minutes, unattended.
- **Gotchas**:
  - Export applies a common "Overload Protection" gain when any track exceeds 0 dBFS; the Normalize menu can't be changed for float output. The plug-in-free reference track recovers that gain exactly: the residual is −148 dB.
  - Exporting with Bypass Effect Plug-ins gives the exact per-track input, including region gain and offsets.
  - Pressing menu-bar items through Accessibility left a menu stuck, and the open panels died with it; use keyboard shortcuts instead.
  - The Audio Device alert appears off-screen when Logic is in the background and silently blocks all input.
- **Logic renders are deterministic.** Repeated exports give the same Channel EQ fit; a full bit-compare is still to do.
- **Default settings:**
  - Channel EQ at its defaults is bit-transparent (−148.7 dB, float precision).
  - Limiter at its defaults lowers a −3.3 dBFS-peak input by about 1 dB.
  - ChromaGlow (Modern Tube, Clean, 0 % drive) is not transparent, and its output is 657 samples late in the export (no delay compensation in Export All Tracks).

### Channel EQ: parametric band (bands 3–6), findings so far
- **Parameter block layout**: 52 floats.

  | Indices | Content |
  |---|---|
  | 0–3 | Low cut: on, Hz, slope code, Q |
  | 4–7 | Low shelf: on, Hz, dB, Q |
  | 8–11, 12–15, 16–19, 20–23 | Bands 3–6: on, Hz, dB, Q |
  | 24–27 | High shelf |
  | 28–31 | High cut: on, Hz, slope code, Q |
  | 41 | Gain-Q coupling switch (0 = off; any non-zero value = on) |
  | 32–51 | Remaining slots: other flags, not yet mapped |

- **Each band is exactly one biquad.** A least-squares biquad fit leaves −140 dB residual for every variant, which is float precision. The centre frequency and peak gain are exact, with no frequency cramping of f0.
- **In RBJ form** (b = [1 + αA, −2cos w, 1 − αA], a = [1 + α/A, −2cos w, 1 − α/A], A = 10^(dB/40)), the effective α corresponds to:

  Q_rbj = Q_eff(Q) / A × c(w), where c(w) ≈ (w/2)/tan(w/2)

  The c(w) approximation holds within 0.1 % up to 3 kHz, and within about 1 % at 6–20 kHz (not exact yet).
- **The 1/A term**: boost and cut are symmetric. With coupling off it holds from +3 to +24 dB.
- **Q_eff lies on a grid of exactly 1/300 decade**: log10(Q_eff) × 300 is an integer for all 21 Q values tested. Most stored Q values round to the nearest step. Q = 0.4, 0.5, 0.7, 0.8, 3.0 and 3.5 land 1–4 steps away from that, so the mapping from stored value to grid index is still unknown.
- **Gain-Q coupling on** (Logic's default) adds a further Q factor that depends on gain and is asymmetric between boost and cut. At Q 1 and 1 kHz, Q_rbj is 1.103 at +6 dB, 1.266 at +12 dB and 2.792 at −12 dB. The coupling strength probably sits in another slot among 40–43.
- **Next**:
  1. Pin down the Q index mapping with a dense sweep. Four bands per instance would give four times the throughput.
  2. Find the exact c(w).
  3. Model the coupling law.
  4. Measure the shelves, the low and high cuts (slope codes 0–?), HQ mode and the master gain.
  5. Implement Dalnok Channel EQ and require a −120 dB null against these renders.

## Open questions for the owner
- Confirm the clean-room rules above, and decide whether Drum Kit may use the installed Apple samples.
- Accept that "exact" is a measured target per plug-in (table above), not a promise for ChromaVerb and ChromaGlow.
