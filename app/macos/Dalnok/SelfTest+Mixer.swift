// Self-test steps (Mixer), split out of SelfTest.swift (A-18). The harness (check, perform, mouse) lives there.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import DalnokEngine

extension SelfTest {
    /// Clip launcher: View ▸ Clip Launcher, copy a selected clip into a slot, launch it on the bar, stop it.
    func launcherSteps() async {
        guard let (row, track) = s.tracks.enumerated().first(where: { !$0.element.isBus && !$0.element.clips.isEmpty }),
              let clip = track.clips.first else { return check(false, "a clip for the launcher (\(s.tracks.map { ($0.name, $0.clips.count) }))") }
        let e = s.engine
        let was = MainWindowController.showLauncher
        if !was {
            check(perform("Clip Launcher"), "View > Clip Launcher")
            w.window?.contentView?.layoutSubtreeIfNeeded()
            check(!w.launcher.isHidden && w.launcher.frame.width > 400, "the launcher shows its slots (\(w.launcher.frame.width) pt)")
        }
        w.timeline.selectedClip = clip.id
        let lv = w.launcher
        func click(_ r: CGRect) {
            let at = lv.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
            lv.mouseDown(with: mouse(.leftMouseDown, at))
            lv.mouseUp(with: mouse(.leftMouseUp, at))
        }
        click(lv.slotRect(row: row, slot: 0))
        check(s.slotClip(track.id, 0) != nil && s.track(track.id)?.clips.count == track.clips.count,
              "clicking an empty slot copies the selected clip there (the arrangement keeps it)")
        e.seek(0); await wait(0.1)
        click(lv.slotRect(row: row, slot: 0))
        check(e.isPlaying, "clicking a slot clip launches it (starting the transport)")
        await wait(0.3)
        check(dalnok_launcher_playing(e.handle, track.id) == 0, "the slot is playing")
        try? w.snapshot(to: workdir.appendingPathComponent("launcher.png"))
        click(lv.slotRect(row: row, slot: 0))
        await wait(2.3) // the stop lands on the next bar (2 s at 120 BPM)
        check(dalnok_launcher_playing(e.handle, track.id) == -1, "clicking it again goes back to the arrangement on the bar")
        e.pause()
        if Analog.on { // tape reels: the take-up pack follows the playhead
            e.seek(0); await wait(0.15)
            let start = w.transport.reels.tapeFraction
            e.seek(Int64(e.sampleRate * 20)); await wait(0.15)
            check(w.transport.reels.superview != nil && start < 0.01 && w.transport.reels.tapeFraction > 0.05,
                  "the tape reels wind with the playhead (\(start) → \(w.transport.reels.tapeFraction))")
            e.seek(0)
        }
        do { // reel physics (any theme): ω = v / r; a second of play turns the reels at a visible, real-deck rate
            let saved = Motion.override; Motion.override = true; defer { Motion.override = saved }
            let reels = TapeReels(); reels.length = 120
            reels.update(seconds: 0)
            reels.update(seconds: 0.5); reels.update(seconds: 1.0) // one second of playback in steps
            let (supply, takeUp) = reels.reelAngles
            check(supply > 2 && takeUp > supply, "reels turn at deck speed, the near-empty take-up reel faster (\(supply), \(takeUp) rad/s)")
            reels.update(seconds: 0.5)
            check(reels.reelAngles.1 < takeUp, "rewinding turns the reels backwards")
            let h = TapeReels.thickness(length: 120), r0 = TapeReels.hub
            let exact = 2 * CGFloat.pi * (sqrt(r0 * r0 + TapeReels.speed * 0.5 * h / .pi) - r0) / h
            check(abs(reels.reelAngles.1 - exact) < 1e-3, "the take-up angle matches the spiral model at 0.5 s (\(reels.reelAngles.1) vs \(exact))")
            // Only as much tape as there is sound: past the end the reels spin on but no tape moves.
            let short = TapeReels(); short.length = 2
            short.update(seconds: 0); short.update(seconds: 0.6); short.update(seconds: 1.2); short.update(seconds: 1.8); short.update(seconds: 2.0)
            let full = short.tapeFraction, a0 = short.reelAngles.1
            short.update(seconds: 2.6); short.update(seconds: 3.2)
            check(full == 1 && short.tapeFraction == 1 && short.reelAngles.1 > a0 + 1, "past the last sound the reels keep turning without transferring tape (\(short.tapeFraction))")
        }
        // Follow action from the slot's menu, then drag the slot clip out onto the timeline.
        if let slotClip = s.slotClip(track.id, 0) {
            let item = NSMenuItem(); item.representedObject = [Int(slotClip.id), 1, 2]
            lv.followChosen(item)
            check(s.slotClip(track.id, 0)?.follow == 1 && s.slotClip(track.id, 0)?.followLoops == 2, "the slot menu sets a follow action")
            let from = lv.convert(CGPoint(x: lv.slotRect(row: row, slot: 0).midX, y: lv.slotRect(row: row, slot: 0).midY), to: nil)
            let x = w.timeline.bounds.midX
            let to = w.timeline.convert(CGPoint(x: x, y: w.timeline.laneY(row) + 20), to: nil)
            let before = s.track(track.id)?.clips.count ?? 0
            lv.mouseDown(with: mouse(.leftMouseDown, from))
            lv.mouseDragged(with: mouse(.leftMouseDragged, to))
            lv.mouseUp(with: mouse(.leftMouseUp, to))
            check(s.track(track.id)?.clips.count == before + 1 && e.undoName == "Place Copy", "dragging a slot onto the timeline places a copy (\(before)→\(s.track(track.id)?.clips.count ?? -1), \(e.undoName), \(w.lastFlashText))")
            _ = perform("Undo"); _ = perform("Undo")
        }
        // VoiceOver: the slot is a button with its clip and state; the arrangement lists clips as buttons.
        let slotItems = (lv.accessibilityChildren() ?? []).compactMap { $0 as? AXItem }
        let slotItem = slotItems.first { ($0.accessibilityLabel() ?? "").hasPrefix("Slot 1 on \(track.name)") }
        check(slotItem != nil && slotItems.filter { ($0.accessibilityLabel() ?? "").hasPrefix("Launch scene") }.count == Int(s.scenes),
              "VoiceOver finds the launcher's scenes and the filled slot (\(slotItem?.accessibilityLabel() ?? "none"))")
        w.timeline.selectedClip = nil
        let clipItems = (w.timeline.accessibilityChildren() ?? []).compactMap { $0 as? AXItem }
        let clipItem = clipItems.first { ($0.accessibilityLabel() ?? "").contains("on \(track.name), at ") }
        check(clipItem?.accessibilityPerformPress() == true && w.timeline.selectedClip != nil && clipItem?.accessibilityFrame().width ?? 0 > 0,
              "VoiceOver presses an arrangement clip to select it (\(clipItem?.accessibilityLabel() ?? "none"))")
        w.timeline.selectedClip = clip.id
        // Drag an arrangement clip left into an empty slot on its own row: the slot gets a copy, the clip stays.
        if let from = w.timeline.windowPoint(ofClip: clip.id), let start = s.clip(clip.id)?.start {
            let r = lv.slotRect(row: row, slot: 1)
            let to = lv.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
            let before = s.track(track.id)?.clips.count ?? 0
            w.timeline.mouseDown(with: mouse(.leftMouseDown, from))
            w.timeline.mouseDragged(with: mouse(.leftMouseDragged, to))
            w.timeline.mouseUp(with: mouse(.leftMouseUp, to))
            check(s.slotClip(track.id, 1) != nil && s.track(track.id)?.clips.count == before && s.clip(clip.id)?.start == start,
                  "dragging a timeline clip into a slot copies it there and leaves the clip in place (\(w.lastFlashText))")
            _ = perform("Undo")
            check(s.slotClip(track.id, 1) == nil, "undo removes the dragged slot copy")
        }
        // An empty slot's menu sets where takes go; choosing it again goes back to the arrangement.
        do {
            let r = lv.slotRect(row: row, slot: 3)
            let at = lv.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
            let item = lv.menu(for: mouse(.rightMouseDown, at))?.items.first
            check(item?.title == "Record Takes into Slot 4", "an empty slot's menu offers recording into it (\(item?.title ?? "none"))")
            if let item { lv.recordSlotChosen(item) }
            check(dalnok_record_slot(e.handle) == 3, "choosing it makes slot 4 the record target")
            let back = lv.menu(for: mouse(.rightMouseDown, at))?.items.first
            check(back?.title == "Record Takes into the Arrangement", "the menu then offers going back")
            if let back { lv.recordSlotChosen(back) }
            check(dalnok_record_slot(e.handle) == -1, "takes go to the arrangement again")
        }
        check(perform("Record Launcher to Arrangement") && dalnok_launcher_recording(e.handle), "Transport > Record Launcher to Arrangement")
        _ = perform("Record Launcher to Arrangement")
        check(perform("Undo") && s.slotClip(track.id, 0) == nil, "undo removes the slot copy")
        if !was { _ = perform("Clip Launcher") }
    }

    /// Mixer and routing: View ▸ Mixer, Track ▸ New Bus, output and send through the strip controls, fader drag.
    func mixerAndRouting() async {
        guard let src = s.tracks.first(where: { !$0.isBus })?.id else { return check(false, "a track for routing") }
        let wasShown = MainWindowController.showMixer
        if !wasShown { check(perform("Mixer", exact: true) && MainWindowController.showMixer, "View > Mixer shows the mixer") }
        await wait(0.1)
        check(!w.mixer.isHidden && w.mixer.frame.height > 300 && w.mixer.strips.count == s.tracks.count,
              "the mixer has a strip per track (\(w.mixer.strips.count))")
        check(perform("New Bus") && s.tracks.last?.isBus == true, "Track > New Bus adds a bus")
        guard let bus = s.tracks.last?.id, let strip = w.mixer.strips.first(where: { $0.trackId == src }) else { return }
        await wait(0.05)
        check(w.mixer.strips.count == s.tracks.count, "the mixer adds the bus's strip")
        strip.output.selectItem(withTag: Int(bus))
        strip.outputChosen()
        check(s.track(src)?.output == bus, "the strip's output menu routes the track to the bus")
        strip.output.selectItem(withTag: 0); strip.outputChosen()
        check(s.track(src)?.output == 0, "output back to the master")
        if let item = strip.addSend.itemArray.first(where: { $0.tag == Int(bus) }) {
            strip.addSendChosen(item)
            check(s.track(src)?.sends.first?.bus == bus, "+ Send adds a send to the bus")
        } else { check(false, "+ Send lists the bus") }
        // Drag the fader down: one undo step.
        let f = strip.fader
        let a = f.convert(CGPoint(x: f.bounds.midX, y: f.bounds.height * 0.25), to: nil), b = f.convert(CGPoint(x: f.bounds.midX, y: f.bounds.height * 0.6), to: nil)
        let before = s.track(src)?.gainDb ?? 0
        f.mouseDown(with: mouse(.leftMouseDown, a))
        for k in 1...6 { f.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x, y: a.y + (b.y - a.y) * CGFloat(k) / 6))) }
        f.mouseUp(with: mouse(.leftMouseUp, b))
        s.refresh(onDisplayTick: true)
        let after = s.track(src)?.gainDb ?? 0
        check(after < before - 3, "dragging the strip fader down lowers the volume (\(before) → \(after) dB)")
        check(s.engine.undoName == "Volume" && perform("Undo") && abs((s.track(src)?.gainDb ?? 0) - before) < 0.01, "the fader drag is one undo step")
        // Automation: View ▸ Show Automation, click to add, drag to move, ⌥-click to delete, each one undo step.
        let tl = w.timeline
        check(perform("Show Automation") && tl.showAutomation, "View > Show Automation shows the curves")
        if let i = s.tracks.firstIndex(where: { $0.id == src }) {
            let y = tl.laneY(i)
            let x = tl.xPos(forFrame: s.beatToFrame(s.barToBeat(2)))
            let click = tl.convert(CGPoint(x: x, y: tl.autoY(-12, laneY: y)), to: nil)
            tl.mouseDown(with: mouse(.leftMouseDown, click)); tl.mouseUp(with: mouse(.leftMouseUp, click))
            let pts = s.track(src)?.volumeAuto ?? []
            check(pts.count == 2 && pts[0].frame == 0 && abs(pts[1].value - (-12)) < 0.8,
                  "clicking a lane adds a point (and one at the start holding the fader value): \(pts.map { ($0.frame, $0.value) })")
            check(s.engine.undoName == "Volume Automation", "adding a point is one undo step")
            let to = tl.convert(CGPoint(x: x + 40, y: tl.autoY(0, laneY: y)), to: nil)
            tl.mouseDown(with: mouse(.leftMouseDown, click))
            for k in 1...5 { tl.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: click.x + (to.x - click.x) * CGFloat(k) / 5, y: click.y + (to.y - click.y) * CGFloat(k) / 5))) }
            tl.mouseUp(with: mouse(.leftMouseUp, to))
            let moved = s.track(src)?.volumeAuto.last
            check(moved.map { $0.frame > pts[1].frame && abs($0.value) < 0.8 } == true, "dragging a point moves it in time and value")
            if let moved, let at = s.track(src)?.volumeAuto.last.map({ tl.convert(CGPoint(x: tl.xPos(forFrame: Double($0.frame)), y: tl.autoY($0.value, laneY: y)), to: nil) }) {
                tl.mouseDown(with: mouse(.leftMouseDown, at, .option)); tl.mouseUp(with: mouse(.leftMouseUp, at, .option))
                check(s.track(src)?.volumeAuto.count == 1, "⌥-click deletes a point")
                check(perform("Undo") && s.track(src)?.volumeAuto.last?.frame == moved.frame, "undo restores the deleted point")
            }
            w.headers.select(src)
            check(perform("Clear Automation") && s.track(src)?.volumeAuto.isEmpty == true, "Track > Clear Automation removes the lane")
        }
        // A backward seek (including a cycle wrap) starts a new pass without releasing the live override.
        do {
            let previousWriter = AutomationWriter.shared, previousMode = AutomationWriter.mode
            let engine = Engine(), session = Session(engine: engine), writer = AutomationWriter(session: session)
            defer { writer.commitAll(); AutomationWriter.shared = previousWriter; AutomationWriter.mode = previousMode; engine.shutdown() }
            let track = dalnok_track_add(engine.handle, "Automation loop test")
            let samples = [Float](repeating: 0.5, count: 100_000)
            let media = samples.withUnsafeBufferPointer { buffer in
                var channels: [UnsafePointer<Float>?] = [buffer.baseAddress]
                return dalnok_media_from_samples(&channels, 1, Int64(samples.count), engine.sampleRate)
            }
            if let media {
                let pool = dalnok_pool_add(engine.handle, media, nil)
                _ = dalnok_clip_add(engine.handle, track, pool, 0, 0, 0)
                dalnok_media_release(media)
                session.refresh(onDisplayTick: true)
                _ = session.setAutomation(track, 0, [DalnokAutoPoint(frame: 0, value: -200), DalnokAutoPoint(frame: 90_000, value: -200)])
                AutomationWriter.mode = .touch
                var l = [Float](repeating: 0, count: 512), r = l
                func pump(_ count: Int) { for _ in 0..<count { _ = dalnok_engine_pump(engine.handle, &l, &r, 512) } }
                engine.play(); pump(12)
                writer.touch(track, 0, true)
                session.setGain(track, db: -6)
                writer.touch(track, 0, false)
                check(session.track(track)?.volumeAuto.contains(where: { $0.frame == engine.position && abs($0.value + 6) < 1e-6 }) == true,
                      "same-frame Touch records the final engine gain")
                session.setGain(track, db: 0)
                _ = session.setAutomation(track, 0, [DalnokAutoPoint(frame: 0, value: -200), DalnokAutoPoint(frame: 90_000, value: -200)])
                writer.touch(track, 0, true); pump(4); writer.tick()
                engine.seek(0); pump(3); writer.tick()
                pump(4)
                check(abs(l[400] - 0.5) < 0.001, "automation override remains active after a backward transport jump (\(l[400]))")
                writer.touch(track, 0, false)
                check(!writer.isWriting, "releasing Touch after the jump finishes the new pass")
                _ = session.setAutomation(track, 0, [DalnokAutoPoint(frame: 0, value: -200), DalnokAutoPoint(frame: 90_000, value: -200)])
                AutomationWriter.mode = .latch
                engine.seek(10_000); pump(3)
                writer.touch(track, 0, true); pump(4); writer.touch(track, 0, false); writer.tick()
                engine.seek(0); pump(3); writer.tick(); pump(4)
                check(writer.isWriting && abs(l[400] - 0.5) < 0.001, "Latch remains active across a backward transport jump (\(l[400]))")
                writer.commitAll()
            } else { check(false, "create generated audio for automation loop test") }
        }
        // Touch writing: hold the header gain knob while playing; the moves become the lane.
        if let row = w.headers.row(src) {
            check(perform("Automation: Touch") && AutomationWriter.mode == .touch, "Track > Automation: Touch")
            s.engine.seek(0); await wait(0.1)
            s.engine.play(); await wait(0.25)
            let g = row.gain
            let a = g.convert(CGPoint(x: g.bounds.midX, y: g.bounds.midY), to: nil)
            g.mouseDown(with: mouse(.leftMouseDown, a))
            for k in 1...8 {
                g.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x, y: a.y - CGFloat(k) * 6)))
                await wait(0.06)
            }
            g.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: a.x, y: a.y - 48)))
            await wait(0.05)
            s.engine.pause()
            let lane = s.track(src)?.volumeAuto ?? []
            check(lane.count >= 3 && s.engine.undoName == "Write Automation", "Touch writes the knob's moves into the volume lane (\(lane.count) points)")
            check(perform("Undo") && (s.track(src)?.volumeAuto.isEmpty ?? false), "undo removes the written automation")
            _ = perform("Automation: Read")
        }
        check(perform("Automate Pan") && TimelineView.automationTarget == 1, "View > Automate Pan switches the shown parameter")
        TimelineView.automationTarget = 0
        _ = perform("Show Automation")
        // Master strip: dragging its fader sets the master volume as one undo step.
        let mf = w.mixer.master.fader
        let m0 = mf.convert(CGPoint(x: mf.bounds.midX, y: mf.bounds.height * 0.2), to: nil), m1 = mf.convert(CGPoint(x: mf.bounds.midX, y: mf.bounds.height * 0.55), to: nil)
        mf.mouseDown(with: mouse(.leftMouseDown, m0))
        for k in 1...4 { mf.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: m0.x, y: m0.y + (m1.y - m0.y) * CGFloat(k) / 4))) }
        mf.mouseUp(with: mouse(.leftMouseUp, m1))
        check(s.masterGainDb < -3 && s.engine.undoName == "Master Volume", "the master strip's fader sets the master volume (\(s.masterGainDb) dB)")
        check(perform("Undo") && s.masterGainDb == 0, "undo restores the master volume")
        check(strip.insertsStack.arrangedSubviews.contains { ($0 as? NSButton)?.title == "+ Insert" }, "strips offer + Insert")
        // A long send list scrolls without shifting the pan or fader relative to other channels.
        let extraBuses = (0..<4).map { s.addBus("Test Send \($0)") }
        for id in extraBuses { _ = s.setSend(src, id, db: -12, pre: false) }
        if let longStrip = w.mixer.strips.first(where: { $0.trackId == src }),
           let otherStrip = w.mixer.strips.first(where: { $0.trackId != src }),
           let doc = longStrip.routingScroll.documentView {
            w.mixer.layoutSubtreeIfNeeded()
            let a = longStrip.fader.convert(longStrip.fader.bounds, to: w.mixer)
            let b = otherStrip.fader.convert(otherStrip.fader.bounds, to: w.mixer)
            check(abs(a.minY - b.minY) < 0.5 && abs(a.height - b.height) < 0.5,
                  "mixer faders align with different send counts")
            let scroll = longStrip.routingScroll
            let overflow = doc.bounds.height - scroll.contentView.bounds.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, overflow)))
            scroll.reflectScrolledClipView(scroll.contentView)
            check(overflow > 0 && scroll.contentView.bounds.minY > 0,
                  "long mixer insert and send lists scroll without overlapping the fader")
        } else { check(false, "mixer strips and routing list exist") }
        for id in extraBuses { s.removeTrack(id) }
        // Removing the bus clears the send.
        w.headers.select(bus)
        check(perform("Delete Track") && s.track(src)?.sends.isEmpty == true, "deleting the bus removes sends to it")
        // Track stacks: Track ▸ Create Track Stack, close and open with the disclosure arrow, ungroup.
        let plain = s.tracks.filter { !$0.isBus && !$0.isStack && $0.stack == 0 }
        if plain.count >= 2 {
            w.headers.select(plain[0].id)
            w.timeline.selectedClip = plain[1].clips.first?.id
            let before = s.tracks.count
            check(perform("Create Track Stack"), "Track > Create Track Stack")
            let stack = s.tracks.first { $0.isStack }
            check(stack != nil && s.tracks.count == before + 1 && s.members(of: stack!.id).count == (plain[1].clips.isEmpty ? 1 : 2),
                  "the stack holds the selected track and the selected clip's track")
            if let stack, let row = w.headers.row(stack.id) {
                check(s.track(plain[0].id)?.output == stack.id, "members are routed into the stack")
                let arrow = row.subviewsDeep.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("toggleStack") }
                arrow?.performClick(nil)
                check(s.track(stack.id)?.collapsed == true && !s.tracks.contains { $0.id == plain[0].id } && w.headers.row(plain[0].id) == nil,
                      "the disclosure arrow closes the stack and hides its tracks")
                w.headers.row(stack.id)?.subviewsDeep.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("toggleStack") }?.performClick(nil)
                check(s.tracks.contains { $0.id == plain[0].id }, "opening the stack shows its tracks again")
                // Nesting: stack the stack; closing the outer one hides everything inside it.
                w.headers.select(stack.id); w.timeline.selectedClip = nil
                let created = perform("Create Track Stack")
                check(created, "Track > Create Track Stack on a stack")
                if let outer = s.tracks.first(where: { $0.isStack && $0.id != stack.id }) {
                    if let strip = w.mixer.strips.first(where: { $0.trackId == plain[0].id }) {
                        check(strip.output.itemArray.filter { $0.title == "Stack" }.count == 2 &&
                              Set(strip.output.itemArray.map(\.tag)).isSuperset(of: [Int(stack.id), Int(outer.id)]),
                              "mixer output menu keeps both identically named stacks")
                    } else { check(false, "mixer strip exists for nested track") }
                    check(s.track(stack.id)?.stack == outer.id && s.nesting(s.track(plain[0].id)!) == 2,
                          "a stack nests inside another (\(s.track(stack.id)?.stack ?? 0) vs \(outer.id))")
                    s.setStackCollapsed(outer.id, true)
                    check(!s.tracks.contains { $0.id == stack.id || $0.id == plain[0].id }, "closing the outer stack hides the inner stack and its tracks")
                    s.setStackCollapsed(outer.id, false)
                    _ = perform("Undo"); _ = perform("Undo"); _ = perform("Undo") // open, close, then create
                    check(s.track(stack.id)?.stack == 0 && s.tracks.filter(\.isStack).count == 1, "undo removes the outer stack")
                }
                w.headers.select(stack.id)
                check(perform("Ungroup Track Stack") && !s.tracks.contains { $0.isStack } && s.track(plain[0].id)?.output == 0, "Track > Ungroup Track Stack")
                check(perform("Undo") && s.tracks.contains { $0.isStack }, "undo brings the stack back")
                _ = perform("Undo") // remove the stack again
            } else { check(false, "the stack has a header") }
        }
        if !wasShown { _ = perform("Mixer", exact: true) }
    }

    /// Cycle: Transport menu, drawing and moving it in the ruler, looping playback, and exporting its range.
    func cycle() async {
        let e = s.engine, tl = w.timeline
        _ = s.setCycle(false, 0, 0) // start without a region
        tl.selectedClip = nil // with clips selected, Cycle uses their span instead
        e.seek(0); await wait(0.1)
        check(perform("Cycle", exact: true) && s.cycle.on && s.cycle.end > s.cycle.start, "Transport > Cycle turns on a 4-bar cycle at the playhead")
        check(abs(Double(s.cycle.end) - s.beatToFrame(s.barToBeat(4))) < 1, "the default cycle is 4 bars (\(s.cycle.start)–\(s.cycle.end))")
        check(perform("Cycle", exact: true) && !s.cycle.on, "Cycle toggles off and keeps the region")
        // Draw a new region in the upper ruler (starting outside any existing region), then move it.
        _ = s.setCycle(false, 0, 0)
        let x1 = tl.xPos(forFrame: s.beatToFrame(s.barToBeat(1))), x2 = tl.xPos(forFrame: s.beatToFrame(s.barToBeat(2)))
        let y = Theme.rulerHeight / 4
        let a = tl.convert(CGPoint(x: x1 + 2, y: y), to: nil), b = tl.convert(CGPoint(x: x2 + 2, y: y), to: nil)
        tl.mouseDown(with: mouse(.leftMouseDown, a))
        for k in 1...6 { tl.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / 6, y: a.y))) }
        tl.mouseUp(with: mouse(.leftMouseUp, b))
        let bar1 = Int64(s.beatToFrame(s.barToBeat(1)).rounded()), bar2 = Int64(s.beatToFrame(s.barToBeat(2)).rounded())
        check(s.cycle.on && abs(s.cycle.start - bar1) <= 1 && abs(s.cycle.end - bar2) <= 1,
              "dragging in the upper ruler draws a snapped cycle (\(s.cycle.start)–\(s.cycle.end), bar 2–3 = \(bar1)–\(bar2))")
        let mid = tl.convert(CGPoint(x: (x1 + x2) / 2, y: y), to: nil), right = tl.convert(CGPoint(x: (x1 + x2) / 2 + (x2 - x1), y: y), to: nil)
        tl.mouseDown(with: mouse(.leftMouseDown, mid))
        for k in 1...6 { tl.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: mid.x + (right.x - mid.x) * CGFloat(k) / 6, y: mid.y))) }
        tl.mouseUp(with: mouse(.leftMouseUp, right))
        check(abs(s.cycle.start - bar2) <= 1 && s.cycle.end - s.cycle.start == bar2 - bar1, "dragging the band moves the cycle by a bar")
        // Playback loops inside it.
        e.seek(s.cycle.start); await wait(0.1)
        e.play()
        await wait(Double(s.cycle.end - s.cycle.start) / e.sampleRate * 1.6)
        let pos = e.position
        e.pause()
        check(pos >= s.cycle.start && pos < s.cycle.end, "playback loops inside the cycle (\(pos))")
        // Export uses the cycle range.
        let url = workdir.appendingPathComponent("cycle-export.wav")
        if w.exportMix(to: url), let f = try? AVAudioFile(forReading: url) {
            check(abs(f.length - (s.cycle.end - s.cycle.start)) <= 1, "Export Mix exports the cycle range (\(f.length) frames)")
        } else { check(false, "Export Mix with cycle on") }
        _ = s.setCycle(false, s.cycle.start, s.cycle.end)
    }

    /// Tempo field, meter popup, ruler mode, and metronome through the real controls and menus.
    func tempoAndMetronome() async {
        let e = s.engine
        w.transport.tempoField.stringValue = "96"
        w.tempoEdited(nil)
        check(abs(s.bpm - 96) < 1e-9 && e.undoName == "Tempo", "tempo field sets 96 BPM as an undo step")
        w.transport.tempoField.stringValue = "1000"
        w.tempoEdited(nil)
        check(abs(s.bpm - 96) < 1e-9 && w.transport.tempoField.stringValue == "96", "invalid tempo is rejected and the field restored")
        check(TempoFormatter.valid("128.5") && !TempoFormatter.valid("12a") && !TempoFormatter.valid("1.2.3") && !TempoFormatter.valid("-5"),
              "the tempo field accepts only numbers")
        // Dragging the tempo readout changes the tempo as one undo step.
        w.tempoDragged(100); w.tempoDragged(104); w.tempoDragged(nil)
        check(abs(s.bpm - 104) < 1e-9 && e.undoName == "Change Tempo", "dragging the tempo sets it as one undo step (\(s.bpm), \(e.undoName))")
        _ = perform("Undo")
        check(abs(s.bpm - 96) < 1e-9, "one undo restores the tempo from before the drag (\(s.bpm))")
        w.transport.meterPopup.selectItem(withTitle: "3/4")
        w.meterChosen(nil)
        check(s.meter == (3, 4), "meter popup sets 3/4")
        let wasBars = TimelineView.barsAndBeats
        if !wasBars { _ = perform("Bars and Beats Ruler") }
        e.seek(Int64((e.sampleRate * 60 / 96 * 4).rounded())) // bar 2, beat 2 (the nearest frame: 110,250 at 44.1 kHz)
        for _ in 0..<10 where !w.transport.timeLabel.stringValue.hasPrefix("2.2.1.") { try? await Task.sleep(for: .milliseconds(100)) } // the display updates on the next frame
        check(w.transport.timeLabel.stringValue.hasPrefix("2.2.1."), "LCD shows bars and beats (\(w.transport.timeLabel.stringValue), \(e.isPlaying ? "playing" : "stopped"))")
        check(w.timeline.barsLabel(e.sampleRate * 60 / 96 * 3, wholeBars: false) == "2", "ruler labels bar 2 at its downbeat")
        _ = s.setTempo(96, 3, 8)
        let eighth = e.sampleRate * 60 / 96 / 2
        check(w.timeline.positionText(Int64(eighth * 2)) == "1.3.1.000" &&
              w.timeline.barsLabel(eighth * 2, wholeBars: false) == "1.3", "3/8 ruler and LCD count eighth-note beats")
        check(abs(s.barToBeat(1) - 1.5) < 1e-9, "3/8 bar is three eighth notes")
        _ = s.setTempo(96, 3, 4)
        // Tempo and meter changes through the Transport menu, the tempo field and the meter popup.
        let beat96 = e.sampleRate * 60 / 96
        e.seek(Int64(beat96 * 6)) // bar 3 (3/4)
        try? await Task.sleep(for: .milliseconds(50))
        check(perform("Add Tempo Change at Playhead") && s.tempoPoints.count == 2 && s.tempoPoints[1].beat == 6,
              "Transport > Add Tempo Change adds a change at the playhead")
        w.window?.makeFirstResponder(nil)
        w.transport.tempoField.stringValue = "144"
        w.tempoEdited(nil)
        check(s.tempoPoints.map(\.bpm) == [96, 144] && abs(s.bpm - 96) < 1e-9, "tempo field edits the change under the playhead only")
        check(abs(s.beatToFrame(9) - (beat96 * 6 + e.sampleRate * 60 / 144 * 3)) < 1e-6 &&
              w.timeline.barsLabel(beat96 * 6 + e.sampleRate * 60 / 144 * 3, wholeBars: false) == "4",
              "ruler places bar 4 at the faster tempo")
        check(perform("Add Time Signature Change at Playhead") && s.meterPoints.count == 2 && s.meterPoints[1].bar == 2,
              "Transport > Add Time Signature Change adds a change at the bar")
        w.transport.meterPopup.selectItem(withTitle: "7/8")
        w.meterChosen(nil)
        check(s.meterPoints.last?.numerator == 7 && s.meter == (3, 4), "meter popup edits the change under the playhead only")
        check(abs(s.barToBeat(4) - (6 + 3.5 * 2)) < 1e-9, "bars after the change are 7/8 long")
        e.seek(Int64(s.beatToFrame(9.5)))
        try? await Task.sleep(for: .milliseconds(150))
        check(w.transport.timeLabel.stringValue.hasPrefix("4.1.") && w.transport.tempoField.stringValue == "144" &&
              w.transport.meterPopup.titleOfSelectedItem == "7/8", "LCD, tempo and meter follow the playhead (\(w.transport.timeLabel.stringValue))")
        e.seek(Int64(beat96))
        try? await Task.sleep(for: .milliseconds(150))
        check(w.transport.tempoField.stringValue == "96" && w.transport.meterPopup.titleOfSelectedItem == "3/4",
              "control bar shows the first tempo before the change")
        try? w.snapshot(to: workdir.appendingPathComponent("tempo-map.png"))
        e.seek(Int64(s.beatToFrame(7)))
        try? await Task.sleep(for: .milliseconds(50))
        check(perform("Remove Time Signature Change at Playhead") && s.meterPoints.count == 1, "removing the time signature change")
        check(perform("Remove Tempo Change at Playhead") && s.tempoPoints.count == 1, "removing the tempo change")
        check(perform("Undo") && s.tempoPoints.count == 2 && perform("Undo") && s.meterPoints.count == 2, "undo restores removed changes")
        _ = s.setTempoMap([DalnokTempoPoint(beat: 0, bpm: 96)], [DalnokMeterPoint(bar: 0, numerator: 3, denominator: 4)])
        check(perform("Bars and Beats Ruler") && !TimelineView.barsAndBeats, "View > Bars and Beats Ruler toggles to time")
        try? await Task.sleep(for: .milliseconds(100))
        check(w.transport.timeLabel.stringValue.contains(":"), "LCD shows minutes and seconds (\(w.transport.timeLabel.stringValue))")
        _ = perform("Bars and Beats Ruler")
        let wasOn = MainWindowController.metronomeOn
        check(perform("Metronome", exact: true) && dalnok_metronome_enabled(e.handle) != wasOn, "Transport > Metronome toggles the click")
        if MainWindowController.metronomeOn {
            // Past the end of the session only the click can make sound.
            e.seek(s.length + Int64(e.sampleRate * 600))
            try? await Task.sleep(for: .milliseconds(100))
            e.play()
            var loudest: Float = -120
            for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(25)); loudest = max(loudest, w.transport.masterMeter.levelDb.0) }
            e.pause()
            check(loudest > -30, String(format: "metronome reaches the output past the session end (%.1f dBFS)", loudest))
        }
        _ = perform("Metronome", exact: true)
        check(dalnok_metronome_enabled(e.handle) == wasOn, "metronome restored")
    }
}
