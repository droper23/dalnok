---
created: 2026-11-17
status: research started
related: "[[Logic ProjectData Format]]", "[[Licensing]]"
---
# Logic Effect Parity

Owner goal (2026-11-17): imported Logic projects should sound exactly like Logic. Logic-only effects should become a suite of Dalnok plug-ins that sound the same as Apple's.

## Can Dalnok host Apple's effects directly?
No. Logic Pro Creator Studio 12.2 ships its effects inside the private `MADSP.framework`. They are not Audio Units, the app bundle contains no Audio Unit extensions (only Quick Look and thumbnail extensions), and MainStage is not installed. Loading the private framework would break Logic's license, would stop working on any Logic update, and could not ship with a GPL project. **Parity has to come from clean-room re-implementation.**

## Working rules (owner decisions, 2026-11-18)
- **Disassembling Logic is allowed when renders alone can't settle a question.** We use it to learn formulas, curves and parameter layouts, then re-express them in our own code. Apple's code and data tables are never copied verbatim into this GPL repository; where Logic uses a lookup table, we derive or regenerate it. Logic's licence agreement prohibits disassembly; the owner accepts that risk.
- **Apple sample content** (for example Drum Kit Designer) may be played at runtime from the owner's installed Logic library. It is never bundled or redistributed. Other systems, or Macs without the content, get a fallback kit.
- **The bar**: match Logic exactly (a null test) wherever that is feasible. Otherwise the result must be truly indistinguishable, verified by blind A/B listening and by statistical measures. "Close" is not enough.
- Use our own plug-in names. Say only that the plug-ins are "compatible with Logic projects"; never use Apple's names or artwork.

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
  | 32 | Master Gain |
  | 33–40 | Analyzer settings (no audio effect) |
  | 41 | Gain-Q Coupling (0 = off; any non-zero value = on) |
  | 42 | Gain-Q Couple Mode (see below) |
  | 43 | Oversampling (HQ), probably |
  | 44 | Channel Processing, probably |
  | 45–51 | Display settings |

  The order follows Logic's Controls view list; the slots marked "probably" still need a check by diff.

- **Each band is exactly one biquad.** A least-squares biquad fit leaves −140 dB residual for every variant, which is float precision. The centre frequency and peak gain are exact, with no frequency cramping of f0.
- **Exact model, Q-Couple off** (`tools/logic-parity/cheq_model.py`). It nulls against Logic at −132 to −148 dB on all 30 variants: boost and cut, Q 0.1–10, 100 Hz–20 kHz. That is identical to float precision.
  - **Q knob**: 128 steps, Q_i = 10^(−1 + 3i/127), displayed to 2 significant figures. A stored Q snaps to the nearest displayed value, with ties going to the lower one. Logic's own UI only ever stores displayed values.
  - **Effective Q**: Q_e = 10^(round(300·log10(Q_display))/300), a grid of 1/300 decade.
  - **Coefficients**: with w = 2πf/fs and A = 10^(|dB|/40), α = sin w · A / (2·Q_e·(w/2)/tan(w/2)).
    - Boost: b = [1 + αA, −2cos w, 1 − αA], a = [1 + α/A, −2cos w, 1 − α/A].
    - Cut: the same with A and 1/A swapped (symmetric, Zölzer-style).
    - Frequency and gain are used exactly as set.
  - **Logic's Controls view** (plug-in window View ▸ Controls) exposes every parameter through Accessibility, with its knob index (`ax/axparam.swift`):
    - Q: 0–127.
    - Gain: 0–480 in 0.1 dB steps.
    - Frequency: indexed; 20 Hz is 0, 100 Hz is 250 and 7500 Hz is 900. The frequency law is still to be mapped.
- **Gain-Q coupling on** (Logic's default) multiplies the effective Q by k(gain, mode):

  Q_rbj = Q_e · k / A · (w/2)/tan(w/2)

  - k does not depend on frequency (identical from 100 Hz to 20 kHz) or on Q.
  - 300·log10 k is always an integer, so k is also quantized to 1/300 decade.
  - **Mode (slot 42)**:
    - 0 Light, 1 Medium and 2 Strong are symmetric.
    - −1 Asymmetric Medium (Logic's default) and −2 Asymmetric Strong use the symmetric curve for boosts and a stronger curve for cuts.
    - 3–7 behave like Medium; −3 is probably Asymmetric Light (untested).
  - **Measured m = 300·log10 k at Q 1, 1 kHz**:

    | Mode | +0.5 | +1 | +3 | +6 | +9 | +12 | +15 | +18 | +24 |
    |---|---|---|---|---|---|---|---|---|---|
    | Medium boost | 4 | 8 | 27 | 58 | 90 | 121 | 150 | 177 | 226 |
    | Light boost | | | | | | 74 | | | |
    | Strong boost | | | | | | 183 | | | |

    | Mode | −0.5 | −1 | −3 | −6 | −9 | −12 | −18 | −24 |
    |---|---|---|---|---|---|---|---|---|
    | Asymmetric Medium cut | 12 | 23 | 69 | 129 | 180 | 224 | 296 | 353 |
    | Asymmetric Strong cut | | | | | | 302 | | |

  - **Closed form** (from MADSP's `GetQScaleFromGainAndStrength`):

    k = 1 + s·|g|·(0.06 + 0.005625·|g|)

    - s = strength for boosts and strength × asym for cuts.
    - Light = 0.5, Medium = 1, Strong = 2; the asymmetric modes use asym = 3.
    - Strength 10 is a special case: k = 10^(|g|/20).
    - The product Q_display·k is then rounded to the 1/300-decade grid.
    - `cheq_model.peak(..., couple=True, mode=...)` nulls at −132 to −147 dB on all 45 coupled renders, covering every mode, boost and cut, Q 1 and 4, and 100 Hz to 20 kHz.
- **Next**:
  2. Map how stored frequency and gain values snap to the knobs.
  3. Measure the shelves, the low and high cuts (slope codes), HQ mode, the master gain and the processing modes.
  4. Implement Dalnok Channel EQ in the engine with an offline-render test against generated fixtures.

## Open questions for the owner
- Decided 2026-11-18; see Working rules.
