# Project Format (version 1)

A single JSON file (`.atrium`), written atomically: temp file, then `fsync`, then `rename`.
Media is **referenced**, not copied, by absolute path plus a path relative to the project file.
On load, the relative path is tried first, so moving a project folder together with its audio works.

```json
{
  "format": "atrium-project", "version": 1, "sampleRate": 48000,
  "media":  [{ "id": 1, "path": "/abs/a.wav", "relativePath": "Audio/a.wav", "frames": 1152000, "channels": 2 }],
  "tracks": [{ "id": 1, "name": "Kick", "color": 0, "gainDb": 0, "pan": 0, "mute": false,
               "clips": [{ "id": 1, "media": 1, "start": 0, "offset": 0, "length": 1152000, "name": "Kick" }] }]
}
```

## Rules
- Positions are frames at `sampleRate`. Loading into an engine at another rate rescales them.
- `gainDb: null` means −∞.
- A clip's place in its track's `clips` array is its z-order.
- **Missing media** loads as *offline*: the clip is kept and renders silence, and the reference is kept on
  the next save. `atrium_project_load` reports the count.
- **Rejected files** (bad JSON, wrong format, a newer `version`, dangling references) leave the open project untouched.
- **Forward compatibility:** unknown fields are ignored. Bump `version` only for breaking changes, and keep a reader for every older version.

## Planned
Copy-to-project-folder on import, autosave and crash recovery (Phase 2), relink UI, DAWproject export.
