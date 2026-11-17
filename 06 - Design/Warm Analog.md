# Warm Analog

The analog theme is a different instrument with the same controls. Every control keeps its position, label,
shortcut, accessibility text and colour meaning (mute blue, solo amber, record red, track colours); only its
rendering changes. Someone who knows Graphite can use Warm Analog without relearning anything.

| Element | Graphite | Warm Analog |
|---|---|---|
| R / M / S | Flat chips filled with the state colour | Dark machined caps with a real LED lens (glass, hot-spot, halo); the LED carries the state, the letter is engraved; armed tracks' LEDs breathe while recording |
| Knobs | Flat face that shrinks to reveal a glowing ring | Knurled aluminium cap with a pointer line, ringed by discrete LED dots that are always visible (brighter when touched) |
| Meters | Continuous bars | Segmented LED ladders (green, amber, red), dim unlit segments, held peak segment |
| Position display | Amber digits on black | Vacuum-fluorescent display: teal glowing digits over unlit "8" segments |
| Panels | Flat graphite | Brushed, grained faceplates with screws |
| Track names | Text | Handwritten on masking-tape scribble strips |
| Device panel | Cards | Rack units with ears, screws, a power LED, IN/OUT jacks, joined by patch cables that sag and plug in (animated) from the track's IN to its OUT |
| Track colours | Green-start OKLCH gradient | Amber-start, softer chroma (same lightness rules) |

Implementation: `Analog.swift` (surfaces, screws, LEDs, knob caps, jacks, cables); components branch on
`Analog.on`. The theme is chosen in Settings and applies on reopening. Motion follows `Motion.swift` and is off
with Reduce Motion (cables appear already plugged in).

Not done yet: tape-reel or console-style timeline surfaces, VU needles for the master meter, light leaks and
wear, and contrast checks of every lit and unlit state with real users.
