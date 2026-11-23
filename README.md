# Dalnok

> **dal·nok** /ˈdɒlnok/ · *noun* (Hungarian)<br>
> bard; a singer-poet.

An open-source digital audio workstation for macOS (and later Windows and Linux). The goal is pro-grade
recording, editing, and mixing in a fast, focused native app, in the look you work best in.

> **Feature parity tracker:** https://droper23.github.io/dalnok-status/
>
> **Status: 0.3.0, preview release (pre-alpha).** Expect rough edges and save often.
> What works and what doesn't is in [CURRENT_STATE.md](CURRENT_STATE.md); changes are in [CHANGELOG.md](CHANGELOG.md).

![Dalnok in the Prism theme: the arrangement playing, with the mixer and a device chain of plug-ins open](assets/screenshots/prism-dark.png)

<p align="center">
<a href="#four-themes-six-looks">Themes</a> ·
<a href="#plug-ins">Plug-ins</a> ·
<a href="#whats-in-dalnok">Features</a> ·
<a href="#more-screens">More screens</a> ·
<a href="#install-preview-build">Install</a> ·
<a href="#build--run-macos-14-apple-silicon">Build</a> ·
<a href="#project-documentation">Docs</a>
</p>

## Highlights
- **Records like a studio, plays it safe.** Multi-track recording with cycle, punch, count-in, take folders and swipe
  comping. Every take is written crash-safe, and latency compensation is measured on your own interface, so a take
  lands on the exact sample it was played to.
- **Plug-ins can't take it down.** VST3, CLAP and Audio Units are validated in a separate scanner and, by default, run
  in their own processes. A crashing plug-in is reported on its track while the music keeps playing.
- **A device chain you can see working.** Every plug-in gets a faceplate with a display that suits it: a VU meter for
  dynamics, an EQ screen with draggable bands, a transfer curve, a goniometer.
- **Four themes, six looks**, from a flat digital workstation to a pedalboard, a room of glass and a drafting table.
  All of them share every command, shortcut and control.
- **Bring your projects.** Dalnok imports Logic Pro, Ableton Live, REAPER and Final Cut XML projects, or a folder of
  stems, and reports what came across. On first launch, pick the keyboard shortcuts you already know (Logic, Ableton,
  Pro Tools, Cubase, Studio One or REAPER).

## New since 0.3.0 (unreleased)
- **Two new themes, Prism and Atelier**, each with a light and a dark version (View ▸ Theme, Settings ▸ Appearance;
  Match System follows macOS).
- **Dalnok Compressor**, a built-in compressor with a sidechain: key it from another track for ducking, with a
  side-chain filter, Listen and a gain-reduction meter.
- **Composition Overview** (View ▸ Composition Overview, ⌥⌘O): the whole project as a roadmap of its sections, showing
  which tracks play in each, with their volume automation. Click a section, or use the arrow keys, to jump there.

## Four themes, six looks
Themes change how everything is drawn, not what it does. Switch any time from View ▸ Theme (⌥⌘A steps through them);
the project, undo history and zoom stay where they were.

| | |
|:---:|:---:|
| <img src="assets/screenshots/graphite.png" alt="Graphite: a flat, dark digital workstation" width="100%"><br>**Graphite**: a modern digital workstation, built for clarity | <img src="assets/screenshots/warm-analog.png" alt="Warm Analog: tape transport, console mixer and plug-ins as pedals patched with cables" width="100%"><br>**Warm Analog**: a tape deck, a console and a pedalboard |
| <img src="assets/screenshots/prism-dark.png" alt="Prism Dark: panes of glass floating over a field of coloured light" width="100%"><br>**Prism Dark**: panes of glass over a field of light | <img src="assets/screenshots/prism-light.png" alt="Prism Light: milky glass panes over a pale field of light" width="100%"><br>**Prism Light** |
| <img src="assets/screenshots/atelier-light.png" alt="Atelier Light: a codex of engraved plates, sepia on parchment" width="100%"><br>**Atelier Light**: an engraved codex, sepia on parchment | <img src="assets/screenshots/atelier-dark.png" alt="Atelier Dark: cream and gold engraving on dark umber" width="100%"><br>**Atelier Dark**: cream and gold engraving on umber |

### See them move
Each tour plays the same generated project: the mixer opens and closes, a plug-in is switched off and on, and the
device chain follows the selected track.

<table>
<tr><td align="center"><img src="assets/screenshots/tour-graphite.gif" alt="Graphite tour" width="100%"><br><sub>Graphite · <a href="assets/videos/tour-graphite.mp4">video</a></sub></td>
<td align="center"><img src="assets/screenshots/tour-warm-analog.gif" alt="Warm Analog tour" width="100%"><br><sub>Warm Analog · <a href="assets/videos/tour-warm-analog.mp4">video</a></sub></td></tr>
<tr><td align="center"><img src="assets/screenshots/tour-prism-dark.gif" alt="Prism Dark tour" width="100%"><br><sub>Prism Dark · <a href="assets/videos/tour-prism-dark.mp4">video</a></sub></td>
<td align="center"><img src="assets/screenshots/tour-prism-light.gif" alt="Prism Light tour" width="100%"><br><sub>Prism Light · <a href="assets/videos/tour-prism-light.mp4">video</a></sub></td></tr>
<tr><td align="center"><img src="assets/screenshots/tour-atelier-light.gif" alt="Atelier Light tour" width="100%"><br><sub>Atelier Light (before the Codex redesign) · <a href="assets/videos/tour-atelier-light.mp4">video</a></sub></td>
<td align="center"><img src="assets/screenshots/tour-atelier-dark.gif" alt="Atelier Dark tour" width="100%"><br><sub>Atelier Dark (before the Codex redesign) · <a href="assets/videos/tour-atelier-dark.mp4">video</a></sub></td></tr>
</table>

### What makes each theme
- **Graphite**: flat, quiet surfaces; plug-ins as rack units with lit displays. Built for long sessions.
- **Warm Analog**: tape reels that hold as much tape as the project has sound, a glowing VFD clock, a console with VU
  meters, and every plug-in as a pedal patched in order from the track's input to its output.
- **Prism**: everything is glass. Surfaces float over a field of soft coloured light, bending and catching it at
  their rims (in the spirit of Apple's Liquid Glass, drawn by Dalnok so it looks the same on every platform).
  - Selected items rise.
  - Meters are pipes of light.
  - The playhead's small prism casts a spectrum over the ruler.
- **Atelier**: a codex: the studio as engraved plates from an old book of natural philosophy; plug-in displays are numbered, captioned figures (a Frequency Atlas, an instrument dial, a vaulted Acoustic Chamber), set in Source Serif 4 and IBM Plex.
  - Bars are ruled, heavier every four.
  - Markers become "§ Verse" headings.
  - Selection is a pair of crop marks.
  - Faders have graduated scales.
  - Plug-in screens become plots on graph paper.

Design notes: [Theme System](<06 - Design/Theme System.md>), [Prism](<06 - Design/Prism.md>),
[Atelier](<06 - Design/Atelier.md>).

## Plug-ins
Add a plug-in and it appears in the track's device chain with its own display. These clips run the same steps in every
theme, while a 4-bar loop plays:
1. Add Dalnok Channel EQ, switch on a band and sweep it.
2. Add Dalnok Compressor and pull the threshold down until the VU needle moves.
3. Key the compressor from the kick drum (sidechain ducking).
4. Bypass the compressor and turn it back on, then fold the EQ and unfold it.
5. Add Apple's AUDelay and move it to the front of the chain.
6. Remove all three.

<table>
<tr><td align="center"><img src="assets/screenshots/plugins-graphite.gif" alt="Graphite: adding, adjusting, keying, bypassing, folding, reordering and removing plug-ins" width="100%"><br><sub>Graphite · <a href="assets/videos/plugins-graphite.mp4">video</a></sub></td></tr>
<tr><td align="center"><img src="assets/screenshots/plugins-warm-analog.gif" alt="Warm Analog: the same steps with pedals and patch cables" width="100%"><br><sub>Warm Analog: pedals and patch cables · <a href="assets/videos/plugins-warm-analog.mp4">video</a></sub></td></tr>
<tr><td align="center"><img src="assets/screenshots/plugins-prism-dark.gif" alt="Prism Dark: glass cards on a beam of light" width="100%"><br><sub>Prism Dark: glass cards on a beam of light · <a href="assets/videos/plugins-prism-dark.mp4">video</a></sub></td></tr>
<tr><td align="center"><img src="assets/screenshots/plugins-prism-light.gif" alt="Prism Light: the same steps on milky glass" width="100%"><br><sub>Prism Light · <a href="assets/videos/plugins-prism-light.mp4">video</a></sub></td></tr>
<tr><td align="center"><img src="assets/screenshots/plugins-atelier-light.gif" alt="Atelier Light plug-ins, before the Codex redesign" width="100%"><br><sub>Atelier Light (recorded before the Codex redesign; retaken at the next release) · <a href="assets/videos/plugins-atelier-light.mp4">video</a></sub></td></tr>
<tr><td align="center"><img src="assets/screenshots/plugins-atelier-dark.gif" alt="Atelier Dark plug-ins, before the Codex redesign" width="100%"><br><sub>Atelier Dark (before the Codex redesign) · <a href="assets/videos/plugins-atelier-dark.mp4">video</a></sub></td></tr>
</table>

In Atelier the chain is one engraving: each plug-in is a station on the drawn signal line, and its figure is an
instrument you drag by its lettered parts: a flyball governor for dynamics, the vaulted acoustic chamber for reverbs,
a pendulum for delays, a sine through its clipping curve for distortion, a crank and disc for modulation. Every
parameter in the key is drawn as the instrument for its unit (slide rule, vernier, stopwatch, protractor, balance).

<p align="center"><img src="assets/screenshots/figures-atelier-dark.png" alt="Atelier's plug-in figures: governor, acoustic chamber, pendulum, clipped wave, crank and disc (Atelier Dark)" width="100%"><br>
<img src="assets/screenshots/figures-atelier-light.png" alt="The same figures in Atelier Light" width="100%"><br><sub>Atelier's plug-in figures, dark and light</sub></p>

Third-party plug-ins get the same treatment. The display is chosen from what a plug-in declares, its name and its
parameters, and any unit can be switched to another display. Settings ▸ Plug-ins ▸ Safety runs each third-party
plug-in in its own process (on by default).

<p align="center"><img src="assets/screenshots/plugin-browser.png" alt="The plug-in browser, sorted by what each plug-in does (Atelier Light)" width="80%"><br><sub>The plug-in browser sorts by what each plug-in does (Atelier Light)</sub></p>

## What's in Dalnok
- **Recording and editing:**
  - Multi-track audio recording with cycle, punch and count-in.
  - Input Monitoring per track.
  - Take folders with swipe comping, and crash-safe capture with recovery.
  - Clip fades and gain; time-stretch and pitch.
  - Recording keeps your output: record from an interface while you listen on another device.
- **Latency:** compensation is measured on your hardware (Audio ▸ Recording Input ▸ Measure Recording Latency) and
  used for every take. Plug-in delay compensation covers the whole mix.
- **MIDI:**
  - MIDI clips and a piano roll with velocity and quantize.
  - Live MIDI input and recording.
  - The built-in Dalnok Poly synth.
  - Tempo and meter maps, and a metronome.
- **Mixing:**
  - Buses and sends; a mixer with a master strip and inserts.
  - Volume, pan and plug-in automation (Touch/Latch).
  - Sidechains, track stacks, and track groups with a clutch.
- **Plug-ins:** VST3, CLAP and Audio Units, each validated in a separate scanner process before use, and run
  out-of-process by default.
- **Built-in effects:** Dalnok Channel EQ, modelled on Logic's Channel EQ, and Dalnok Compressor with a sidechain key.
- **Moving from another DAW:** imports Logic Pro, Ableton Live, REAPER and Final Cut XML projects, or a folder of
  stems, with a report of what came across. Choose your old DAW's keyboard shortcuts at first launch.
- **Clip launcher** with scenes on the same tracks as the arrangement.
- **Composition Overview:** the project as sections, with each track's part and its volume automation.
- **One Settings window** for every preference, keyboard shortcuts included, and a command palette for every action.

## More screens
### Composition Overview
<table>
<tr><td align="center"><img src="assets/screenshots/overview-atelier-light.png" alt="Composition Overview in Atelier Light" width="100%"><br><sub>Atelier Light</sub></td>
<td align="center"><img src="assets/screenshots/overview-prism-dark.png" alt="Composition Overview in Prism Dark" width="100%"><br><sub>Prism Dark</sub></td></tr>
</table>

### Piano roll
<table>
<tr><td align="center"><img src="assets/screenshots/piano-roll-graphite.png" alt="Piano roll, Graphite" width="100%"><br><sub>Graphite</sub></td>
<td align="center"><img src="assets/screenshots/piano-roll-warm-analog.png" alt="Piano roll, Warm Analog: lit pins" width="100%"><br><sub>Warm Analog</sub></td></tr>
<tr><td align="center"><img src="assets/screenshots/piano-roll-prism-dark.png" alt="Piano roll, Prism Dark: glass notes, velocities as pillars of light" width="100%"><br><sub>Prism Dark</sub></td>
<td align="center"><img src="assets/screenshots/piano-roll-atelier-light.png" alt="Piano roll, Atelier Light: engraved notes whose weight is their velocity" width="100%"><br><sub>Atelier Light</sub></td></tr>
</table>

### Mixer
<table>
<tr><td align="center"><img src="assets/screenshots/mixer-warm-analog.png" alt="Mixer, Warm Analog" width="100%"><br><sub>Warm Analog</sub></td>
<td align="center"><img src="assets/screenshots/mixer-prism-light.png" alt="Mixer, Prism Light" width="100%"><br><sub>Prism Light</sub></td></tr>
<tr><td align="center"><img src="assets/screenshots/mixer-atelier-light.png" alt="Mixer, Atelier Light: graduated scales and slide-rule faders" width="100%"><br><sub>Atelier Light</sub></td>
<td align="center"><img src="assets/screenshots/mixer-graphite.png" alt="Mixer, Graphite" width="100%"><br><sub>Graphite</sub></td></tr>
</table>

<details>
<summary>Every theme's mixer, piano roll and overview</summary>

| Theme | Mixer | Piano roll | Composition Overview |
|---|---|---|---|
| Graphite | <img src="assets/screenshots/mixer-graphite.png" width="260"> | <img src="assets/screenshots/piano-roll-graphite.png" width="260"> | <img src="assets/screenshots/overview-graphite.png" width="260"> |
| Warm Analog | <img src="assets/screenshots/mixer-warm-analog.png" width="260"> | <img src="assets/screenshots/piano-roll-warm-analog.png" width="260"> | <img src="assets/screenshots/overview-warm-analog.png" width="260"> |
| Prism Dark | <img src="assets/screenshots/mixer-prism-dark.png" width="260"> | <img src="assets/screenshots/piano-roll-prism-dark.png" width="260"> | <img src="assets/screenshots/overview-prism-dark.png" width="260"> |
| Prism Light | <img src="assets/screenshots/mixer-prism-light.png" width="260"> | <img src="assets/screenshots/piano-roll-prism-light.png" width="260"> | <img src="assets/screenshots/overview-prism-light.png" width="260"> |
| Atelier Light | <img src="assets/screenshots/mixer-atelier-light.png" width="260"> | <img src="assets/screenshots/piano-roll-atelier-light.png" width="260"> | <img src="assets/screenshots/overview-atelier-light.png" width="260"> |
| Atelier Dark | <img src="assets/screenshots/mixer-atelier-dark.png" width="260"> | <img src="assets/screenshots/piano-roll-atelier-dark.png" width="260"> | <img src="assets/screenshots/overview-atelier-dark.png" width="260"> |

</details>

### Settings and the command palette
<table>
<tr><td align="center"><img src="assets/screenshots/settings.png" alt="Settings: every preference in one window, keyboard shortcuts included (Prism Dark)" width="100%"><br><sub>Settings (Prism Dark)</sub></td>
<td align="center"><img src="assets/screenshots/palette.png" alt="The command palette: every action by name (Prism Light)" width="100%"><br><sub>Command palette (Prism Light)</sub></td></tr>
</table>

All screenshots and screen recordings come from the real app with a generated project and Dalnok's own and Apple's
built-in plug-ins (`scripts/dev/readme-media.sh` regenerates every one of them).

## Install (preview build)
Download the latest `Dalnok-<version>.zip` from the [Releases](https://github.com/droper23/dalnok/releases) page, unzip it and move
`Dalnok.app` to Applications. Requires macOS 14 or later on Apple Silicon.

The preview build is not notarized yet. The first time, right-click `Dalnok.app` and choose **Open**, then confirm.
(Or run `xattr -dr com.apple.quarantine /Applications/Dalnok.app`.)

## Build & run (macOS 14+, Apple Silicon)
```sh
xcode-select --install        # or a full Xcode 16+ install
swift build                   # engine + app + CLI
swift run Dalnok              # launch; drop audio files on the window or press ⌘I
swift test                    # engine test suite
scripts/check.sh              # build + tests + live audio smoke test
scripts/bundle.sh             # dist/Dalnok.app
```
No third-party dependencies are needed to build. The bundled fonts (Sora, Geist Mono, IBM Plex, Source Serif 4) are
under the SIL Open Font License.

### Trying it without your own material
```sh
scripts/make-test-project.sh ~/Desktop/dalnok-demo band --open   # a generated 8-track project with MIDI and audio
DALNOK_THEME=atelier DALNOK_VARIANT=dark swift run Dalnok         # launch in a given theme and version
```

## Architecture in one paragraph
A C++20 engine (`engine/`) owns the real-time audio path, media decoding, and offline rendering, and
exposes a small C API (`engine/include/dalnok/dalnok.h`). The macOS UI (`app/macos/`) is native AppKit.
The audio callback is checked for real-time safety at compile time (`[[clang::nonblocking]]`). Third-party plug-ins
can run in a separate host process (`tools/dalnok-plughost`). Details are in
[`03 - Architecture/System Overview.md`](<03 - Architecture/System Overview.md>).

## How it's tested
- An engine test suite (Swift Testing, through the C API) with explicit numeric tolerances. Every audio change gets an
  offline-render test.
- An app self-test that drives real menus, clicks and drags end to end, in every theme and at 44.1 and 48 kHz.
- AddressSanitizer and ThreadSanitizer, a real-time-safety analysis of every effect, and fuzzing of the project reader
  and every importer, all on CI.
- Hardware loopback tests on a real audio interface for recording and latency.

## Project documentation
This repository is also the project's [Obsidian](https://obsidian.md) vault:
- [CURRENT_STATE.md](CURRENT_STATE.md): what works, what doesn't, and what's next.
- [Master Roadmap](<02 - Master Roadmap.md>), with the [public parity tracker](https://droper23.github.io/dalnok-status/).
- [Architecture](<03 - Architecture/>), [Decisions (ADRs)](<09 - Decisions/>), [Design notes](<06 - Design/>),
  [Development Journal](<10 - Development Journal/>).
- [AGENTS.md](AGENTS.md): how to work on the code base (people and coding agents alike).

## License
GPL-3.0-or-later. See [LICENSE](LICENSE) and [`04 - Research/Licensing.md`](<04 - Research/Licensing.md>).
