---
created: 2026-11-22
related: "[[Theme System]]", "[[Prism]]", "[[Atelier]]"
---
# Theme performance: Prism and Atelier vs Graphite (2026-11-22)

`Dalnok <project> --perf 20`, release build, on this Mac's default output (silent), generated `large` project
(64 tracks, 64 clips, `scripts/make-test-project.sh … large`). Prism renders its screens offscreen (glass pass);
Atelier draws every mark by hand (pen outlines, hatching) since the sketchbook redo. Two runs each for Graphite,
Prism Dark and Atelier Light, one for Prism Light.

| Look | Main thread p50 | p99 | max | > 50 ms | Display tick p50 / p99 | Overloads | Missed blocks | Worst render |
|---|---|---|---|---|---|---|---|---|
| Graphite | 1.72 / 1.68 ms | 3.09 / 3.01 | 16.2 / 14.3 | 0 | 0.28 / 0.48 | 0 | 0 | 0.54 / 0.36 ms |
| Prism Dark | 2.28 / 2.22 ms | 3.80 / 3.85 | 13.8 / 14.1 | 0 | 0.25 / 0.42 | 0 | 0 | 0.53 / 0.44 ms |
| Prism Light | 2.26 ms | 3.75 | 20.4 | 0 | 0.26 / 0.44 | 0 | 0 | 0.40 ms |
| Atelier Light | 2.14 / 2.03 ms | 4.44 / 4.37 | 15.9 / 16.2 | 0 | 0.24 / 0.38 | 0 | 0 | 0.30 / 0.46 ms |

- Prism costs about 0.55 ms more per main-thread pass at the median than Graphite (+32 %) and 0.8 ms at p99; no pass
  came near a frame's 16.7 ms budget except the first-draw maxima, which all themes share (14–20 ms).
- Atelier's hand-drawn marks cost about 0.4 ms at the median and 1.4 ms at p99 over Graphite.
- Audio is unaffected by the theme: no overloads or missed blocks, worst render under 0.6 ms of a 10.67 ms period.
- Conclusion: both new looks are within budget on this project; nothing to optimise now. Re-measure on a 128-track
  project with plug-ins if a theme change touches the device panel or mixer drawing.

## Re-measure: the Codex, the side panels and the engraved controls (2026-11-22, late)
Same command and generated `large` project, release build of `feat/inspector-library` (ab9d03e). One run each.

| Look | Side panels | Main p50 | p99 | max | > 50 ms | Display tick p50 / p99 | Overloads | Missed | Worst render |
|---|---|---|---|---|---|---|---|---|---|
| Graphite | open | 0.20 ms | 7.91 | 18.6 | 0 | 0.31 / 1.09 | 0 | 0 | 0.30 ms |
| Graphite | closed | 0.19 ms | 7.84 | 22.5 | 0 | 0.30 / 1.17 | 0 | 0 | 0.34 ms |
| Prism Dark | open | 0.20 ms | 7.81 | 279 | 1 | 0.23 / 1.06 | 0 | 0 | 0.29 ms |
| Atelier Light (Codex) | open | 0.20 ms | 7.99 | 17.8 | 0 | 0.25 / 1.19 | 0 | 0 | 0.28 ms |
| Atelier Light (Codex) | closed | 0.15 ms | 8.03 | 21.2 | 0 | 0.22 / 0.97 | 0 | 0 | 0.32 ms |
| Atelier Dark (Codex) | open | 0.02 ms | 8.57 | 12.1 | 0 | 0.22 / 0.99 | 0 | 0 | 0.33 ms |

- The main-thread figures are much lower than this morning's table in every look, Graphite included (p50 0.2 ms vs
  1.7 ms), so they are compared only within this run: the side panels add nothing measurable (Graphite 0.20 / 7.91 open
  vs 0.19 / 7.84 closed), and the Codex with its engraved controls costs about 0.1 ms at p99 over Graphite (0.7 ms in
  Dark). The cause of the overall drop is not established (the machine's load and the PerfProbe build are candidates).
- Prism had one 279 ms main-thread pass (a single stall, not repeated); the panels don't touch Prism's drawing paths,
  but it is worth a repeat run before the next release.
- Audio: no overloads, no missed blocks, worst render ≤ 0.34 ms of a 11.6 ms budget in every look.
