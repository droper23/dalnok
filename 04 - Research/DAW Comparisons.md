---
status: initial (from domain knowledge; each row is verified when its phase starts)
---
# DAW Comparisons: feature matrix

Priority: P0 = parity needed for the owner to switch from Logic · P1 = clear differentiator · P2 = later.

| Feature | Who has it | Why users value it | Limitations today | Our improvement | Complexity | Depends on | Priority |
|---|---|---|---|---|---|---|---|
| Swipe comping and take folders | Logic, Pro Tools, Cubase, Studio One | Fastest way to build a vocal | Logic: tied to the track, awkward with Flex | Comp lanes on any track, keyboard comping, comp history | High | Recording, crossfades | P0 |
| Flex Time and Flex Pitch | Logic (Melodyne in others) | In-place timing and pitch fixes | Logic: per-track mode switching, artifacts | Always-available, per-clip, non-destructive | Very high | Time stretching, transient detection | P0 |
| Stock instruments and FX | Logic (Alchemy, Sampler, ChromaVerb) | Complete toolkit, no purchases | Closed | Open, modular, generic UI plus custom UI | Very high | Plugin and graph API | P0 (incremental) |
| Track stacks / groups | Logic, Bitwig groups, Ableton groups | Organization and summing | Two stack types confuse users | One "group" with an optional sum bus | Medium | Routing graph | P0 |
| Generic plugin parameter panel | Ableton, Bitwig, REAPER | Edit without floating windows | Logic lacks it | Inline, searchable, automatable, mappable | Medium | VST3 hosting | P1 |
| Action system and scripting | REAPER (ReaScript, SWS) | Unlimited customization | REAPER's API is powerful but dated | Command bus with stable C API, scripting, and palette | Medium–high | Command system (M2) | P1 |
| Command palette and discoverability | Bitwig (partial), editors | Find any feature | Logic's hidden menus | Every action searchable with its shortcut | Low | Command system | P1 |
| Clip launching + arrangement | Ableton, Bitwig, Logic Live Loops | Sketching and performance | Ableton: separate views. Logic: bolted on | Unified track model | High | Model, quantized launch | P1 |
| Racks and modulation | Ableton racks, Bitwig modulators | Sound design | Plugin parameters not universally modulatable | Universal modulation on any parameter | High | Parameter system | P1 |
| Spectral editing | Audacity, RX | Repair | Separate apps | In-timeline spectral view | High | FFT, rendering | P2 |
| Fast startup and low CPU | REAPER | Snappy | — | Measured budgets in CI | Ongoing | Benchmarks | P0 |
