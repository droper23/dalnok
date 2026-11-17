# Project Format (version 4)

A single JSON file (`.dalnok`), written atomically: temp file, then `fsync`, then `rename`.
Media is **referenced**, not copied, by absolute path plus a path relative to the project file.
On load, the relative path is tried first, so moving a project folder together with its audio works.

```json
{
  "format": "dalnok-project", "version": 3, "sampleRate": 48000, "tempo": 120, "meter": [4, 4],
  "media":  [{ "id": 1, "path": "/abs/a.wav", "relativePath": "Audio/a.wav", "frames": 1152000, "channels": 2 }],
  "tracks": [{ "id": 1, "name": "Kick", "color": 0, "gainDb": 0, "pan": 0, "mute": false,
               "solo": false,
               "clips": [{ "id": 1, "media": 1, "start": 0, "offset": 0, "length": 1152000, "name": "Kick",
                           "fadeIn": 480, "fadeOut": 4800, "fadeCurve": "equalPower" }] },
             { "id": 2, "name": "Keys", "kind": "instrument", "instrument": "dalnok.poly", "armed": true,
               "clips": [{ "id": 2, "kind": "midi", "start": 0, "offset": 0, "length": 96000, "name": "MIDI",
                           "noteSource": 2, "notes": [[0, 24000, 60, 100]] }] }]
}
```

## Rules
- Positions are frames at `sampleRate`. Loading into an engine at another rate rescales them.
- `gainDb: null` means −∞. `solo`, `fadeIn`, `fadeOut`, and `fadeCurve` (`linear` or `equalPower`) are
  optional (defaults: false, 0, 0, linear), so version 1 files from before M4 still load.
- **Fades.** A clip covers what is beneath it on the same track with its fade envelope, so a fade over
  a lower clip is a crossfade. Fades longer than the clip are scaled down proportionally.
- **Copy on save.** With copy enabled, audio outside the project folder is copied into
  `Audio Files/` beside the project before the project file is written.
- A clip's place in its track's `clips` array is its z-order.
- **Version 2** adds `tempo`, `meter`, track `kind` (`audio` or `instrument`), `instrument`, `armed`, `input`
  (zero-based audio input channel), and MIDI clips (`"kind": "midi"`, no `media`). Each note is
  `[start, length, pitch, velocity]` in frames relative to the clip's source origin, so `offset` and `length`
  window the notes like an audio region. MIDI clips are only valid on instrument tracks. Version 1 files load
  unchanged; a version 1 reader rejects version 2 files instead of dropping MIDI silently.
- **Version 3** records a `noteSource` identity for MIDI clips sharing the same notes, so notes crossing a
  split continue without retriggering after reopen. Shared sources must contain identical note lists.
  Version 1 and 2 files still load; older readers reject version 3 rather than silently losing split continuity.
  Earlier files have no source identity, so their existing splits cannot be linked automatically.
- **Version 4** adds `tempoMap` (`[[beat, bpm], …]`, quarter-note beats, first at 0, strictly increasing) and
  `meterMap` (`[[bar, numerator, denominator], …]`, zero-based bars, first at 0). `tempo` and `meter` still hold the
  first values. Version 3 is still written when there are no changes, so older builds open constant-tempo projects;
  a version 3 reader rejects a project with changes instead of playing it at the wrong tempo. A damaged map is an
  error, not a silent fallback.
- **Versions 5–9** (routing, automation, take folders, plug-in automation, launcher slots) are described in the CHANGELOG.
- **Version 10** adds `"bypassed": true` on a plug-in. It is written only when a plug-in is bypassed, so older builds
  keep opening every other project; a version 9 reader rejects a project with a bypassed plug-in instead of playing
  the effect.
- MIDI is stored in frames. Any tempo edit remaps every MIDI clip and note frame → beat (old map) → frame (new map),
  so MIDI keeps its beats while audio stays time-locked. Clips sharing a note source and origin (split pieces) keep
  sharing it. Each tempo edit can round positions by up to one frame.
- **Missing media** loads as *offline*: the clip is kept and renders silence, and the reference is kept on
  the next save. `dalnok_project_load` reports the count.
- **Rejected files** (bad JSON, wrong format, a newer `version`, dangling references) leave the open project untouched.
- **Forward compatibility:** unknown fields are ignored. Bump `version` only for breaking changes, and keep a reader for every older version.

## Planned
Autosave and crash recovery (Phase 2), DAWproject export.
