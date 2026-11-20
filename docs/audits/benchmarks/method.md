# Benchmark method

Everything in `results.json` was produced on the audit machine with the commands below. Nothing is
estimated; where a measurement was impossible it is listed under `notMeasured` instead of being guessed.

## Environment

- Apple M3 Max, 16 cores, 64 GB, macOS 27.3 (26C5035r).
- Apple Swift 6.4.2 / clang 2100.4.1.1, `swift build -c release`.
- Engine rate 48 kHz, internal block 512 frames, stereo out.
- Revision `b15410a`, branch `audit/2026-11-codebase`.
- A desktop GUI session was running; no other heavy work was performed during runs.

## Commands

```sh
# Deterministic projects (never owner material)
.build/release/dalnok-cli make-test-project .audit/proj-band --preset band
.build/release/dalnok-cli make-test-project .audit/proj-large64 --preset large --tracks 64 --seconds 30
.build/release/dalnok-cli make-test-project .audit/proj-large256 --preset large --tracks 256 --seconds 10
.build/release/dalnok-cli make-test-project .audit/proj-states --preset states

# Real-time render cost (no device)
.build/release/dalnok-cli bench --tracks 8 --seconds 20      # repeated for 64, 256, 512
.build/release/dalnok-cli bench --tracks 64 --seconds 20     # three repeats for variability

# Model/edit/undo cost at a given project size
.build/release/dalnok-cli audit-scale --tracks 32 --clips 32 # 64, 128 too

# The same measurements on real saved projects
.build/release/dalnok-cli audit-bench .audit/proj-large64/large.dalnok --edits 200

# Load time and peak RSS
/usr/bin/time -l .build/release/dalnok-cli command .audit/proj-large256/large.dalnok undo

# Offline render throughput and RSS
/usr/bin/time -l .build/release/dalnok-cli render-project .audit/proj-large64/large.dalnok out.wav

# App launch + window + snapshot, without the fixed 0.4 s wait
DALNOK_SNAPSHOT_DELAY=0 .build/release/Dalnok .audit/proj-band/band.dalnok --snapshot out.png

# Build timings, fresh scratch directory each time
swift build --scratch-path .audit/build2-debug
swift build -c release --scratch-path .audit/build2-release
```

Raw command output is in `raw/`.

## Instrumentation added for this audit

Two subcommands were added to `tools/dalnok-cli/main.swift`, and nothing else in the product changed:

- `audit-bench <project>` measures one `Session.refresh()`-equivalent read pass, a parameter edit, a
  structural edit (nudge, which recompiles), an undo, and RSS growth from 200 undoable edits.
- `audit-scale [--tracks T] [--clips C]` builds a model in memory and measures the same operations at
  64 to 4,096 clips.

Both call only the public C API. They are additive and can be removed without touching the engine or app.

## What each metric means

- **Live path avg/worst**: time for `dalnok_engine_pump` to render one 512-frame block through the real
  render path, averaged over 1,875 blocks. Budget is 512/48000 s = 10.67 ms.
- **Load percent**: average block time divided by the 10.67 ms budget.
- **Offline multiple**: seconds of audio rendered per second of wall time.
- **Model read**: one pass over every track, clip, note list, plug-in slot, send and automation lane
  through the C API - exactly what `Session.refresh()` does.
- **Structural edit**: one undoable clip nudge, which copies the model and recompiles the snapshot.
- **Parameter edit**: one undoable gain change, which also copies the model today.
- **Undo**: one whole-model restore plus recompile.
- **RSS**: maximum resident set size reported by `/usr/bin/time -l`, or `task_info` for `audit-bench`.

## Limitations

- `bench` and `audit-scale` measure the engine without a Core Audio device; they exclude driver and
  device callback overhead, which is small compared with the render work at these track counts.
- The generated projects are synthetic and contain no third-party plug-ins; real plug-in cost is
  outside this measurement.
- Snapshot timings include process launch and PNG encoding, so they are an upper bound on window
  construction, not a frame-time measurement.
- Timeline scroll/zoom frame cost is not measured: no instrumented harness exists and a UI session
  could not be driven reliably during the audit. This is marked as not measured rather than inferred.
- Repeatability: 64-track average varied by 0.4%, 256-track average by 6%; worst-case block times
  varied more (up to 1.37 ms) because of scheduler noise. Treat worst-case as an upper envelope.
