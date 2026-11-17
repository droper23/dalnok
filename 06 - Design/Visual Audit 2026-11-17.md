# Visual audit: Graphite and Warm Analog

Reviewed generated demo, band and states projects in both themes, including the arrangement, mixer, device panel, command palette and secondary windows. Three independent reviewers contributed; this is a design review, not a user study.

## Changes

- Both themes: aligned mixer pan and fader positions across channels with different inserts and sends; routing controls scroll within each strip. Added pan and track-column labels, a framed device-chain empty state and a continuous mixer surface.
- Warm Analog: inactive lamp caps are neutral so active states read clearly, and muted track names remain legible. Lamps warm up and cool down with smooth reversals; new patch cables sag and settle as they connect. Motion respects Reduce Motion.
- Plug-in manager status can wrap rather than truncating at the window edge.

## Remaining observations

- The command palette can leave unused space for short result lists, and its selection treatment could better reflect Warm Analog.
- Some long plug-in parameter names truncate; tooltips and the full parameter editor remain important.
- Concept Guide descriptions include stale feature status and need a separate content review.
- Animation timing has automated state checks, but has not been evaluated by a person watching the running app. VoiceOver and smaller display sizes need a dedicated review.
