// Self-test steps (Motion), split out of SelfTest.swift (A-18). The harness (check, perform, mouse) lives there.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import DalnokEngine

extension SelfTest {
    /// Animations run when motion is allowed and are skipped with Reduce Motion.
    func motion() async {
        let e = s.engine
        guard let track = s.tracks.first?.id, let row = w.headers.row(track) else { return check(false, "a track for motion checks") }
        let clipReads = s.clipReads
        s.setGain(track, db: -1)
        check(!s.refresh() && !s.refresh(), "parameter refresh waits for the display tick")
        s.refresh(onDisplayTick: true)
        check(s.clipReads == clipReads && abs((s.track(track)?.gainDb ?? 0) + 1) < 1e-6,
              "parameter refresh updates gain without reading clips")
        e.undo(); s.refresh(onDisplayTick: true)
        check(s.clipReads == clipReads, "parameter undo refresh does not read clips")
        if let other = s.tracks.first(where: { $0.id != track }) {
            s.setPan(other.id, 0.25)
            s.refresh(onDisplayTick: true)
            check(s.clipReads == clipReads && abs((s.track(other.id)?.pan ?? 0) - 0.25) < 1e-6,
                  "another track's parameter change does not read clips")
            e.undo(); s.refresh(onDisplayTick: true)
        }
        _ = dalnok_track_set_gain_db(s.h, track, -9)
        s.refresh(onDisplayTick: true)
        check(s.clipReads == clipReads && abs((s.track(track)?.gainDb ?? 0) + 9) < 1e-6,
              "scripted gain edit refreshes without reading clips")
        e.undo(); s.refresh(onDisplayTick: true)
        // A-05: a structural edit to one track re-reads only that track's clips.
        if let edited = s.allTracks.first(where: { !$0.clips.isEmpty }), let clip = edited.clips.first {
            s.refresh() // settle anything pending from the checks above
            var info = DalnokTrackInfo(); _ = dalnok_track_info(s.h, edited.id, &info)
            let before = s.clipReads
            var ids = [clip.id]
            _ = dalnok_clips_nudge(s.h, &ids, 1, 480)
            s.refresh()
            check(s.clipReads - before == Int(info.clip_count) && s.clip(clip.id)?.start == clip.start + 480,
                  "an edit to one track re-reads only its \(info.clip_count) clip(s) (read \(s.clipReads - before) of \(s.allTracks.reduce(0) { $0 + $1.clips.count }))")
            let afterEdit = s.clipReads
            e.undo(); s.refresh()
            check(s.clipReads - afterEdit == Int(info.clip_count) && s.clip(clip.id)?.start == clip.start,
                  "undo re-reads only the track it changed")
        } else { check(false, "a track with clips for the per-track refresh check") }
        Motion.override = true
        defer { Motion.override = false }
        // FL-style clip motion (ClipMotion.swift): a dragged clip lifts off the lane and follows the pointer while a
        // ghost shows where it lands; dropped, it settles onto that place. New clips pop in, deleted ones poof.
        if let c = s.tracks.first(where: { !$0.clips.isEmpty })?.clips.first, let p = w.timeline.windowPoint(ofClip: c.id, zone: "body") {
            let dx = CGFloat(Double(c.length) / w.timeline.framesPerPoint) * 0.5
            w.timeline.mouseDown(with: mouse(.leftMouseDown, p))
            check(w.timeline.lift == nil, "a click alone lifts nothing")
            for k in 1...6 { w.timeline.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: p.x + dx * CGFloat(k) / 6, y: p.y))) }
            weak var lifted = w.timeline.lift // weak: the test must not keep the picture alive (that hid a bug)
            check(lifted != nil && w.timeline.lifted == [c.id], "dragging a clip lifts it off the lane")
            try? await Task.sleep(for: .milliseconds(250)) // the follow spring catches up
            if let l = lifted, let host = w.timeline.layer {
                // Grid snapping: the picture settles where the clip now sits on the grid, not under the pointer.
                let landing = s.clip(c.id).flatMap { m in s.tracks.firstIndex { $0.id == m.track }.map { w.timeline.clipRect(m, laneY: w.timeline.laneY($0)) } }
                check(landing.map { abs(l.position.x - $0.midX) < 2 && abs(l.target.x - $0.midX) < 1.5 } == true,
                      String(format: "the lifted clip springs to its snapped place (at %.1f, landing %.1f)", l.position.x, landing?.midX ?? -1))
                let grownBy = (l.layer.transform.m11 - 1) * l.layer.bounds.width, grownH = (l.layer.transform.m22 - 1) * l.layer.bounds.height
                check(l.layer.superlayer === host && abs(grownBy - ClipLift.liftPoints) < 0.5 && abs(grownH - ClipLift.liftPoints) < 0.5,
                      String(format: "it is drawn above the lanes, a few points larger whatever its length (%.1f x %.1f pt, clip %.0f pt wide)", grownBy, grownH, l.layer.bounds.width))
                if let view = w.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: workdir.appendingPathComponent("clip-lift.png"))
                }
            }
            let picture = lifted?.layer
            w.timeline.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: p.x + dx, y: p.y)))
            check(w.timeline.lift == nil && w.timeline.lifted == [c.id], "dropped, the picture settles onto the clip's new place")
            try? await Task.sleep(for: .milliseconds(500))
            check(w.timeline.lifted.isEmpty && picture?.superlayer == nil, "after settling the picture is gone and the real clip is drawn again")
            check((s.clip(c.id)?.start ?? 0) > c.start && e.undoName == "Move Clip", "the drag still moved the clip, one undo step")
            do { // the bug the owner found: after a move, scrolling showed a frozen copy of the clip
                let leftovers = (w.timeline.layer?.sublayers ?? []).filter { $0.contents != nil && $0.zPosition >= 400 }
                check(leftovers.isEmpty, "no clip picture is left over the lanes after the drop (\(leftovers.count))")
            }
            do { // Settings ▸ Appearance ▸ Clip bounce
                let saved = ClipLift.bounce
                let slider = w.settings.clipBounce
                slider.doubleValue = 0; _ = slider.target.map { NSApp.sendAction(slider.action!, to: $0, from: slider) }
                check(ClipLift.bounce == 0 && ClipLift.liftPoints == 0, "Clip bounce at Calm: no lift growth")
                slider.doubleValue = 1; _ = slider.target.map { NSApp.sendAction(slider.action!, to: $0, from: slider) }
                check(ClipLift.bounce == 1 && ClipLift.liftPoints == 10, "Clip bounce at Bouncy: a 10 pt lift")
                ClipLift.bounce = saved
            }
            _ = perform("Undo")
            w.timeline.selectClips([c.id])
            let active = ClipFlourish.active
            _ = perform("Duplicate", exact: true)
            check(ClipFlourish.active > active, "a duplicated clip pops in")
            _ = perform("Delete")
            check(ClipFlourish.active > active, "a deleted clip poofs")
            try? await Task.sleep(for: .milliseconds(450))
            check(ClipFlourish.active == active, "the flourishes clean up after themselves")
            _ = perform("Undo"); _ = perform("Undo")
            Motion.override = false
            w.timeline.mouseDown(with: mouse(.leftMouseDown, p))
            for k in 1...6 { w.timeline.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: p.x + dx * CGFloat(k) / 6, y: p.y))) }
            check(w.timeline.lift == nil, "with Reduce Motion the clip just moves (nothing lifts)")
            w.timeline.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: p.x + dx, y: p.y)))
            _ = perform("Undo")
            Motion.override = true
        } else { check(false, "a clip on screen for the clip-motion checks") }
        // Knob glide: an undone volume change animates instead of jumping.
        s.setGain(track, db: -12)
        try? await Task.sleep(for: .milliseconds(400))
        _ = perform("Undo")
        let target = GainKnob.position(for: s.track(track)?.gainDb ?? 0)
        let mid = row.gain.value
        try? await Task.sleep(for: .milliseconds(400))
        check(abs(mid - target) > 0.01 && abs(row.gain.value - target) < 1e-6,
              String(format: "undo glides the gain knob (%.3f → %.3f)", mid, row.gain.value))
        // Recording indicators pulse.
        w.transport.setRecording(true)
        check(w.transport.recordButton.layer?.animation(forKey: "pulse") != nil, "record button pulses while recording")
        w.transport.setRecording(false)
        check(w.transport.recordButton.layer?.animation(forKey: "pulse") == nil, "pulse stops when recording stops")
        if (Theme.activeStyle == .warmAnalog), let content = w.window?.contentView {
            let lamp = ToggleChip("M", on: Theme.muteOn, onText: .white, help: "Motion test")
            lamp.frame = NSRect(x: 0, y: 0, width: 24, height: 18)
            content.addSubview(lamp)
            defer { lamp.removeFromSuperview() }
            if let glow = lamp.layer?.sublayers?.first {
                lamp.isOn = true
                let rising = glow.animation(forKey: "filament") as? CAKeyframeAnimation
                check(rising?.duration == 0.18 && abs(glow.shadowOpacity - 0.85) < 1e-5,
                      "analog lamp warms up toward its lit brightness")
                try? await Task.sleep(for: .milliseconds(70))
                let before = glow.presentation()?.shadowOpacity ?? glow.shadowOpacity
                lamp.isOn = false
                let falling = glow.animation(forKey: "filament") as? CAKeyframeAnimation
                let start = (falling?.values?.first as? NSNumber)?.floatValue ?? -1
                check(falling?.duration == 0.38 && abs(start - before) < 0.05 && glow.shadowOpacity == 0,
                      "analog lamp cools from its visible brightness when switched off")
                lamp.isOn = true
                let reversed = glow.animation(forKey: "filament") as? CAKeyframeAnimation
                check(reversed?.duration == 0.18 && abs(glow.shadowOpacity - 0.85) < 1e-5,
                      "rapid lamp reversal restores the lit state")
                Motion.override = false
                lamp.isOn = false
                check(glow.animation(forKey: "filament") == nil && glow.shadowOpacity == 0,
                      "with Reduce Motion the lamp switches off instantly")
                lamp.isOn = true
                check(glow.animation(forKey: "filament") == nil && abs(glow.shadowOpacity - 0.85) < 1e-5,
                      "with Reduce Motion the lamp switches on instantly")
                Motion.override = true
            } else { check(false, "analog lamp has a glow layer") }
        }
        // New patch cables draw, settle, and seat once; Reduce Motion suppresses all three.
        let cable = CAShapeLayer(), plug = CALayer()
        let cablePaths = [12, 37, 27, 31, 30].map {
            Analog.cablePath(from: .zero, to: CGPoint(x: 60, y: 0), sag: CGFloat($0))
        }
        Motion.connectCable(cable, plug: plug, paths: cablePaths)
        let settling = cable.animation(forKey: "settle") as? CAKeyframeAnimation
        check(cable.animation(forKey: "plug") != nil && settling?.values?.count == 5 &&
              abs((settling?.duration ?? 0) - 0.65) < 1e-6 && plug.animation(forKey: "seat") != nil,
              "new patch cable draws, settles and seats")
        Motion.override = false
        let stillCable = CAShapeLayer(), stillPlug = CALayer()
        Motion.connectCable(stillCable, plug: stillPlug, paths: cablePaths)
        check(stillCable.animationKeys()?.isEmpty != false && stillPlug.animationKeys()?.isEmpty != false,
              "with Reduce Motion patch cables do not animate")
        Motion.override = true
        // Palette fades in.
        w.palette.show(over: w.window!)
        check(w.palette.panel.alphaValue < 1, "command palette fades in (alpha \(w.palette.panel.alphaValue))")
        w.palette.close()
        try? await Task.sleep(for: .milliseconds(300))
        check(!w.palette.isVisible, "command palette fades out and closes")
        // Reduce Motion: the same changes are instant.
        Motion.override = false
        s.setGain(track, db: -6)
        _ = perform("Undo")
        check(abs(row.gain.value - GainKnob.position(for: s.track(track)?.gainDb ?? 0)) < 1e-6, "with Reduce Motion the knob jumps instantly")
        w.transport.setRecording(true)
        check(w.transport.recordButton.layer?.animation(forKey: "pulse") == nil, "with Reduce Motion nothing pulses")
        w.transport.setRecording(false)
        _ = e
    }
}
