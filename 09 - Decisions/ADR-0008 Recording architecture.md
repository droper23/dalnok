---
status: accepted
date: 2026-11-16
---
# ADR-0008: Reliable audio capture

## Context
Recording must preserve captured audio even when the application, device, or disk fails. The output callback is nonblocking, the model belongs to the engine, and edits are undoable. Input and output can have different hardware clocks. Existing output is an AUHAL output unit; no capture implementation exists yet.

## Decision
- Start with one full-duplex hardware device and one clock. Enumerate input channels by stable device UID; obtain microphone permission before starting. Explicitly reject unsupported input/output combinations rather than silently running unsynchronized clocks. Independent devices, aggregate devices, and clock-drift correction are a later milestone. No implicit device or sample-rate changes during a take.
- Configure AUHAL and preallocate capture buffers before starting. A real-time callback copies timestamped input frames into a bounded single-producer/single-consumer ring. The callback performs no allocation, freeing, locks, disk access, UI calls, or model edits. Capture, monitoring, and output use the same clock; monitoring is opt-in and clearly indicated.
- A dedicated writer drains the ring into a uniquely named, uncompressed temporary recording in the project storage. The writer handles all filesystem operations. Size the ring for a measured worst-case disk stall, not as a substitute for adequate sustained throughput. Publish captured and written frame counts, overruns, device loss, and write errors to the control thread through atomics or bounded queues.
- A full ring, failed write, lost device, timestamp discontinuity, or unsupported format ends the take with an explicit error. Never overwrite unread audio, silently insert or remove frames, or report the take as complete. Preserve successfully written audio and enough metadata to locate and recover it; show the user the failure and recovered duration. Stop capture before draining the writer, and join it off the real-time thread.
- On normal stop, flush and close the audio file, finalize its container, then atomically rename it within the same filesystem. Durability requires flushing file contents and relevant directory metadata where supported. A small recoverable journal identifies in-progress takes, their format, frame counts, and destination. Recovery validates the file and repairs only the valid written prefix; malformed or ambiguous data is preserved for manual recovery. Do not claim crash safety until process-kill and power-loss behavior is tested.
- After successful finalization, import the media and create clips as one engine edit and catalog command. Undo removes the arrangement edit but does not delete the recording; file lifecycle and cleanup must never destroy audio referenced by undo or recovery. A failed or recovered take is presented separately until the user chooses how to use it.
- Align the take to the transport using device timestamps and calibrated input/output latency in the shared clock domain. Keep raw capture and offset metadata; do not pretend alignment is sample-accurate until loopback measurements prove it. Resampling, punch-in, multiple armed tracks, and latency compensation require explicit tests before being enabled.

## Verification gates
1. Deterministic ring tests: ordering, wraparound, full/empty, partial blocks, counter wrap assumptions, and producer/consumer stress under ThreadSanitizer. Compile-time nonblocking checks cover the callback path.
2. Writer tests with generated samples: long captures, frame counts and numeric sample tolerances, disk-full and write failures, delayed writer and ring overflow. Verify no silent success on dropped frames.
3. Kill the process at journal creation, during writes, and during finalization; recover the valid prefix without modifying the original. Check repeated recovery and truncated/corrupt metadata.
4. Device tests: permission denied, input unplug, stream format changes, start/stop races, and output-device changes. On a Scarlett, run a long capture and loopback latency measurement; report hardware and measured results.
5. End-to-end GUI self-test for arm, record, stop, undo, save and reopen, plus manual monitoring and permission checks.

## Consequences
The first recording release is intentionally limited to a single duplex device. File recovery and error reporting are part of recording, not later polish. Disk streaming for playback is independent. The exact ring size and container remain implementation choices to be justified by tests; no audio capture is enabled by this decision alone.

## Amendment (2026-11-21): separate input and output devices, Input Monitoring, measured latency

The milestone deferred above ("independent devices, aggregate devices, and clock-drift correction") is now built,
because the owner listens on one device and records from another (an interface's inputs, the Mac's speakers), and
switching the output to the interface for every take was wrong.

- **One clock still.** When the input and output devices differ, the engine creates a *private* aggregate device
  (`kAudioAggregateDeviceIsPrivateKey`, owned by the process, never listed to other apps) of the output (the main
  sub-device and clock) and the input (drift-corrected). The engine still runs one AUHAL duplex unit on one clock;
  only the hardware pairing changed. The input device is set to the engine rate if it differs (as other DAWs do);
  it is never changed during a take.
- **Input stays open while it is needed.** Input Monitoring (per track, saved) and armed-track monitoring open the
  duplex device and keep it open; a take attaches its capture writer to the running device (atomic publish) instead
  of restarting it, so starting a take doesn't glitch what you hear. Monitored input goes through the track's own
  inserts, fader, pan and routing, transport rolling or stopped.
- **Latency is measured, not assumed.** `dalnok_latency_measure_*` plays tone bursts and finds them on an input that
  hears the output (cable or loopback) by cross-correlation. The correction (measured − reported) is kept per
  input/output pair. On a Scarlett Solo 4th Gen loopback the measurement is exact (spread 0); with it, a take
  recorded back through the loopback lands on the sample it was played from (HardwareLoopback suite).
