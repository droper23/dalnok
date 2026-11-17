---
date: 2026-11-17
status: plan; first items in progress
---
# Theme critique and personality plan (Graphite and Warm Analog)

Four independent reviews (Sonnet agents) from fresh `--uiwalk` screenshots of both themes: a visual designer,
an industrial designer and studio-gear enthusiast, a working producer (Logic user), and a motion and delight
designer. These are design reviews, not user studies. Merged and ranked below; agreement across reviewers is noted.

## What everyone agreed on
- **Warm Analog is Graphite tinted brown plus tiny details.** Hardware vocabulary sits on 3-pixel parts, while
  large surfaces (headers, mixer, arrangement) are flat dark brown. It needs material and structure at large scale.
- **Its LED R/M/S buttons are a readability problem** (the producer calls it a deal-breaker): a muted, soloed and
  armed track reads as three dim dots. A missed arm loses a take.
- **The mixer is Graphite's mixer with a tint**: generic white fader caps, hairline meters, no scale, no channel
  modules. The master's amber is the only distinctive element.
- **Palette is muddy**: olive and brown tracks sink into the brown canvas; teal (VFD) is the loudest colour and
  fights the browns; the amber that should be the signature barely appears.
- **The VFD and the rack with patch cables are the two genuinely distinctive ideas**; build on them.
- **Graphite is ready to work in but anonymous**: saturated clip bodies outshout the controls; headers carry
  colour only in a 3 pt edge; off-state chips all look alike.

## Warm Analog plan (ranked by impact for effort)
| # | Idea | Effort | Source |
|---|---|---|---|
| 1 | **Lit-cap buttons**: R/M/S light the whole cap like a lamp (red, mute amber, solo yellow) with bloom; dim housing when off | S | producer, designer |
| 2 | **Lamp physics**: lamps snap on (40 ms, slight overshoot) and decay off (~220 ms); armed lamps breathe slowly; instant with Reduce Motion | S | motion, gear |
| 3 | **Channel modules in the mixer**: fader caps in the track colour with a centre groove, a printed dB scale, a recessed segmented LED ladder, screws, faceplate | S–M | all |
| 4 | **One hero accent**: amber for every "powered" state; teal only for the VFD; a vintage clip set with steadier lightness so tracks separate from the canvas | S | designer, producer |
| 5 | **Ballistic VU needle on the master** (averaged level, overshoot, peak lamp; LED ladder stays for exact peaks) | M | gear, designer (signature item) |
| 6 | **Count-in countdown in the VFD** (4 3 2 1) and a metronome lamp that kicks on downbeats | S | gear |
| 7 | **Faceplate material**: brushed grain and bevel on headers and strips, darker recessed glass for the arrangement, wood end cheeks | M | designer, gear |
| 8 | **Power-on**: VFD segment sweep and meter lamp-test once per window open (skipped for big projects) | S–M | motion, gear |
| 9 | **Knobs with a pointer line, printed scale arc and centre detents**; bigger in the mixer | S–M | gear, producer |
| 10 | **Tape reels beside the VFD** (spin with playback, wind fast on jumps; static ticks with Reduce Motion) | M | gear |
| 11 | **Takes window as a splice bay** (cut line on swipe), **piano roll as lit pins** on ledger paper | M | gear |
| 12 | Patch cables with real sag and settle; bypassed units with slack grey cables | M | gear, motion |
| — | Optional, off by default: very quiet switch ticks, never while recording or playing | S | motion |

Rejected: tape-style name labels (the owner removed them on 2026-11-17).

## Graphite plan
1. Tint each track header with ~8–10% of its colour (findability at 60 tracks). S
2. Quieter off-state chips (hairline only) so lit ones pop. S
3. Calmer clip bodies (lower saturation; header strip keeps full colour). S
4. Tabular figures for numbers (BPM, dB, bars). S
5. Fatter meters with peak hold in the mixer. S

## Performance rules (from the motion review)
No repeating animations beyond the record button and armed lamps on visible tracks; meters update without implicit
animations; glow is a layer whose opacity changes, never an animated shadow radius; nothing ornamental animates
during playback of large sessions; everything honours Reduce Motion.
