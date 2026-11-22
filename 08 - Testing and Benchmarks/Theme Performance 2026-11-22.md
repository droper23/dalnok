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
