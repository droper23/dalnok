# Dalnok

> **dal·nok** /ˈdɒlnok/ · *noun* (Hungarian)<br>
> bard; a singer-poet.

An open-source digital audio workstation for macOS (and later Windows and Linux). The goal is pro-grade
recording, editing, and mixing in a fast, focused native app.

> **Feature parity tracker:** https://droper23.github.io/dalnok-status/
>
> **Status: 0.2.0, preview release (pre-alpha).** Expect rough edges and save often.
> What works and what doesn't is in [CURRENT_STATE.md](CURRENT_STATE.md); changes are in [CHANGELOG.md](CHANGELOG.md).

![Dalnok in the Graphite appearance: arrangement, mixer and the device panel with plug-in faceplates](assets/screenshots/graphite.png)

## New in 0.2.0
- **Safety on by default:** third-party plug-ins run in their own processes, so a crash or hang is reported on its
  track instead of taking Dalnok down. Isolated plug-ins on different tracks process in parallel, and opening a project
  never blocks the window for more than a few milliseconds. Settings ▸ Plug-ins ▸ Safety turns it off.
- **Folding plug-ins:** fold a unit to a slim strip (Graphite) or tip a pedal onto its side (Warm Analog); on/off still
  works folded. Plug-ins animate in and out of the chain.
- **Pedals show more:** a backlit readout window (the control being turned, gain reduction, response or output trace)
  and signal LEDs.
- **Livelier clips:** a dragged clip lifts and follows the pointer, a ghost shows where it lands, and it settles when
  dropped; new clips pop in and deleted ones shrink away.
- One Open button per plug-in, with Controls in the plug-in window's title bar.

## What's in Dalnok
- **Recording and editing:** multi-track audio recording with cycle, punch and count-in, take folders with swipe
  comping, crash-safe capture and recovery, clip fades and gain, time-stretch and pitch.
- **MIDI:** MIDI clips, a piano roll with velocity and quantize, live MIDI input and recording, the built-in Dalnok Poly
  synth, tempo and meter maps, a metronome.
- **Mixing:** buses, sends, a mixer with a master strip and inserts, volume, pan and plug-in automation (Touch/Latch),
  plug-in delay compensation, track stacks.
- **Plug-ins:** VST3, CLAP and Audio Units, each validated in a separate scanner process before use; a plug-in browser
  sorted by what each plug-in declares, its name and its parameters; sidechains. In the Graphite appearance every
  plug-in gets a hardware-style faceplate with a display that suits it (VU gain reduction, an EQ screen with draggable
  bands, transfer curve, goniometer and more).
- **Built-in effects:** Dalnok Channel EQ, matching Logic's Channel EQ.
- **Moving from another DAW:** imports Logic Pro, Ableton Live, REAPER and Final Cut XML projects, or a folder of stems,
  with a report of what came across.
- **Clip launcher** with scenes on the same tracks as the arrangement.
- Two appearances: **Graphite** and **Warm Analog**, resizable tracks, and one Settings window for every preference
  (keyboard shortcuts included).

## Screenshots
Two appearances, the same app. **Graphite** draws every plug-in as a hardware unit with a display that suits it;
**Warm Analog** turns them into pedals patched with cables, beside a tape transport.

<table>
<tr><td align="center"><img src="assets/screenshots/tour-graphite.gif" alt="Graphite: playing a project with plug-ins, showing and hiding the mixer, bypassing a unit and switching tracks" width="100%"><br><sub>Graphite · <a href="assets/videos/tour-graphite.mp4">video</a></sub></td>
<td align="center"><img src="assets/screenshots/tour-warm-analog.gif" alt="Warm Analog: the same project as pedals, with the mixer shown and hidden" width="100%"><br><sub>Warm Analog · <a href="assets/videos/tour-warm-analog.mp4">video</a></sub></td></tr>
</table>

### Plug-in faceplates (Graphite)
Each unit gets a display that suits it: an EQ screen with draggable bands, a VU gain-reduction meter for dynamics, a
goniometer for stereo, a transfer curve for distortion and more. Bypassed units sit back with their lights off, and
Settings can age them with scratches and dust.

![An EQ, a multiband compressor and a reverb on a mix bus: the EQ screen, the VU needle and the goniometer moving with the music](assets/screenshots/plugins-graphite.gif)
<sub><a href="assets/videos/plugins-graphite.mp4">video</a></sub>

### Warm Analog
![Dalnok in the Warm Analog appearance](assets/screenshots/warm-analog.png)

A tape transport with reels that hold as much tape as the project has sound, and a glowing VFD position display
(here with the second, real-time clock under it):

![Warm Analog tape transport and VFD position display](assets/screenshots/analog-transport.png)

Every plug-in becomes a pedal with its own look, patched in order from the track's input to its output:

![Warm Analog pedals: an EQ, a multiband compressor and a reverb](assets/screenshots/plugins-warm-analog.gif)
<sub><a href="assets/videos/plugins-warm-analog.mp4">video</a></sub>

### MIDI and settings
<table>
<tr><td align="center"><img src="assets/screenshots/piano-roll.png" alt="Piano roll (Graphite)" width="100%"><br><sub>Piano roll, Graphite</sub></td>
<td align="center"><img src="assets/screenshots/piano-roll-analog.png" alt="Piano roll (Warm Analog)" width="100%"><br><sub>Piano roll, Warm Analog</sub></td></tr>
<tr><td colspan="2" align="center"><img src="assets/screenshots/settings.png" alt="Settings: every preference in one window, keyboard shortcuts included" width="70%"><br><sub>Settings</sub></td></tr>
</table>

All screenshots and screen recordings come from the real app with generated projects (`scripts/make-test-project.sh`,
`Dalnok <project> --tour <dir>`), using Dalnok's own and Apple's built-in plug-ins.

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
No third-party dependencies are needed for the current build.

## Architecture in one paragraph
A C++20 engine (`engine/`) owns the real-time audio path, media decoding, and offline rendering, and
exposes a small C API (`engine/include/dalnok/dalnok.h`). The macOS UI (`app/macos/`) is native AppKit.
The audio callback is checked for real-time safety at compile time (`[[clang::nonblocking]]`). Details are
in [`03 - Architecture/System Overview.md`](<03 - Architecture/System Overview.md>).

## License
GPL-3.0-or-later. See [LICENSE](LICENSE) and [`04 - Research/Licensing.md`](<04 - Research/Licensing.md>).
