---
updated: 2026-11-21
---
# New project screen and first launch (2026-11-21)

Owner brief: take the keyboard shortcuts off the new project screen. At first launch, let people pick an app whose
shortcuts they know, and then trust them. Research how other DAWs do the new project screen and build on that.
Earlier passes are in [[First Run and Motion 2026-11-21]].

## How other DAWs start a project

| App | Project basics before the first track | Audio device on the same screen | Recent projects | Templates |
|---|---|---|---|---|
| Logic Pro: Project Chooser, Details pane | Tempo (field or tap), key, time signature, sample rate. Apple: set tempo and sample rate at creation, because they affect recordings. | Input and output menus | Yes | Yes |
| Studio One: Start page | Song name, sample rate, bit depth, tempo, time signature, length | Shows the current device and links to set it up | Yes | Yes (Empty Song first) |
| Pro Tools: Dashboard | Sample rate and bit depth. The sample rate can't change once the session is created. | I/O settings | Yes | Yes |
| Cubase: Hub | (from the template) | Stereo output menu. Users found a connections button that later settings override confusing. | Yes, sectioned | Yes, by category |
| Bitwig: Dashboard | (in Settings) | Audio page: interface, sample rate, block size | Yes (Recent, My Projects) | Quick Start and demos |
| Ableton Live | None: opens the default Set | Preferences | Browser | Default Set |

Empty-state guidance (NN/g and others): say what the screen is, give one clear way forward, keep actions few, use a helpful tone.

## Decisions
- **Project basics first:** tempo, time signature, and the output and input devices with the sample rate. They share
  the control bar's edit path, so each change is one undo step and range checked. Dalnok runs at the device's rate,
  so the rate is shown rather than chosen here. "Audio Settings…" opens Settings ▸ Audio & MIDI.
- **One focused way forward:** "Add your first track": Audio Track or Instrument Track.
- **Recent projects** in a right-hand column (every DAW above has them), with Open, Import Audio and Bring in a
  Logic/Ableton/REAPER project below them. Automated runs (snapshot, screenshots, self-test, UI walk, tour, perf)
  never list recent projects, and captures name no devices, so nothing personal lands in a picture.
- **No templates** (the owner turned them down earlier) and **no shortcut teaching**.
- **First launch:** "Which keyboard shortcuts do you know?"
  - The choices are Logic Pro, Ableton Live, Pro Tools, Cubase, Studio One and REAPER, or Dalnok's own.
  - One click applies the preset and closes the window: no tour and no project finder.
  - Logic, Ableton and REAPER also set the palette's and concept guide's vocabulary.
  - The presets are approximations, and the window says so.
  - Help ▸ Migration Assistant still brings projects over.

## Evidence
- Self-test passes in both configurations: 621 checks at 48 kHz in Graphite, 606 at 44.1 kHz in Warm Analog.
- The new checks cover:
  - no ⌘/⌥ text on the screen;
  - every button has an action;
  - no recent projects listed in automated runs;
  - output and input are shown;
  - tempo and time signature set the project's values, and both undo;
  - leaving the tempo field unchanged adds no undo step (a bug the self-test caught);
  - the chooser opens centered with 6 apps, and choosing Pro Tools or Logic applies that preset and closes it.
- Snapshot of the screen; UI walk frame of the chooser.

Sources: Apple Logic Pro User Guide (Create projects); PreSonus Knowledge Base (Studio One Start Page; Creating a
song from an Empty Template); Avid Pro Tools User Guide (Starting a new session; Changing sample rate and bit
depth); Sound On Sound (Cubase 15 Hub; Pro Tools Dashboard); Steinberg forums (Hub audio connections); Bitwig
user guide (The Dashboard); NN/g (Empty-state interface design).
