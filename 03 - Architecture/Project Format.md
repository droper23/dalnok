# Project Format (version 1)

A single JSON file (`.dalnok`), written atomically: temp file, then `fsync`, then `rename`.
Media is **referenced**, not copied, by absolute path plus a path relative to the project file.
On load, the relative path is tried first, so moving a project folder together with its audio works.

```json
{
  "format": "dalnok-project", "version": 1, "sampleRate": 48000,
  "media":  [{ "id": 1, "path": "/abs/a.wav", "relativePath": "Audio/a.wav", "frames": 1152000, "channels": 2 }],
  "tracks": [{ "id": 1, "name": "Kick", "color": 0, "gainDb": 0, "pan": 0, "mute": false,
               "solo": false,
               "clips": [{ "id": 1, "media": 1, "start": 0, "offset": 0, "length": 1152000, "name": "Kick",
                           "fadeIn": 480, "fadeOut": 4800, "fadeCurve": "equalPower" }] }]
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
- **Missing media** loads as *offline*: the clip is kept and renders silence, and the reference is kept on
  the next save. `dalnok_project_load` reports the count.
- **Rejected files** (bad JSON, wrong format, a newer `version`, dangling references) leave the open project untouched.
- **Forward compatibility:** unknown fields are ignored. Bump `version` only for breaking changes, and keep a reader for every older version.

## Planned
Autosave and crash recovery (Phase 2), DAWproject export.
