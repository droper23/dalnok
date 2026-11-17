---
date: 2026-11-16
status: partial (settings and two themes implemented; further audit items open)
---
# UI audit: workflow, clarity, accessibility, and visual character

Reviewed the current arrangement and control headers from a system-audio self-test snapshot, the existing empty-state and command-palette screenshots, and the new Settings and Warm Analog snapshots. These are design reviews through different lenses, not interviews or usability studies.

## Recording musician
- The transport is easy to find, and gain and pan are separately named. The GAIN/PAN captions were too small, so they are now 10 pt rather than 9 pt. Real track arm, monitoring, input choice, and recording feedback remain missing; do not imply the experimental headless capture is a finished recording workflow.
- Small meters and fade handles deserve testing on a laptop screen while recording. Gain halo and meter convey related but different values; their behavior should be explained in context.

## First-time user
- The old empty-state headline emphasized a gesture instead of the goal. It now says “Start your session” and explains that dropping audio or opening a project are both valid starts.
- The command palette surfaces menu paths and shortcuts, but hidden drag gestures, snap bypass, and stretch remain difficult to discover. Add contextual help without covering the waveform.

## Accessibility and keyboard
- The Graphite faint text token was approximately 2.77:1 against the raised track panel. Raising it to #898E97 produces approximately 5.01:1 on that background. Warm Analog's primary, secondary, and faint text tokens are approximately 12.91:1, 7.14:1, and 4.64:1 against its raised track panel. These are token calculations, not a full contrast audit of blended clips, disabled controls, or every state.
- The settings popup and checkbox use native labeled controls, and the self-test exercises their actions. VoiceOver, full keyboard navigation, reduced motion, color-vision simulation, and high-contrast modes have not been tested.

## Visual design
- Graphite has a disciplined timeline and useful track colors but its cool neutrals make the window feel austere. Warm Analog adds brown-charcoal surfaces, warm off-white type, and amber accents while retaining track-color and mute/solo semantics. The appearance is chosen in Settings and applies when the app reopens; a live switch is not implemented.
- The waveform colors still carry most visual hierarchy. Selected clip and active controls need broader contrast checks in both themes; avoid relying on color alone.

## Engineer and maintainer
- Theme colors now use central tokens for major surfaces and knob faces. Several hard-coded colors and auxiliary windows remain; the warm theme has not been verified across every panel or system appearance.
- Settings exposes appearance and the existing copy-audio preference. More settings should be added only when backed by working engine behavior.
- Visual snapshots and app self-tests are useful regression evidence, but they do not replace testing with musicians, VoiceOver, different displays, large sessions, or actual recording workflows.
