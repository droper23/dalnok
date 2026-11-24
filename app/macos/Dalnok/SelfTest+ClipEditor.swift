// Self-test: the docked clip editor (double-click to open, Clip / Devices switch), MIDI clip resize and creation in
// the lanes, notes drawn by double-click-drag, note and plug-in copy/paste, Q on MIDI and audio, the hover playhead
// and Play from a selection.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

extension SelfTest {
    private func click(_ v: NSView, _ windowPoint: CGPoint, clicks: Int = 1, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.window!.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    private func ev(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.window!.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    /// A window point in a track's lane at a timeline frame.
    private func lanePoint(_ track: DalnokTrackId, frame: Double) -> CGPoint? {
        guard let i = s.tracks.firstIndex(where: { $0.id == track }) else { return nil }
        let tl = w.timeline
        let y = tl.laneY(i) + s.laneHeight(i) / 2
        return tl.convert(CGPoint(x: tl.xPos(forFrame: frame), y: y), to: nil)
    }

    /// Edit commands as key presses (the menu path the app takes even while another app is active).
    private func key(_ chars: String, _ code: UInt16) -> Bool {
        NSApp.mainMenu?.performKeyEquivalent(with: keyEvent(chars, code: code, .command)) ?? false
    }

    func clipEditorSteps() async {
        let e = s.engine
        e.pause()
        let savedMode = MainWindowController.bottomMode, savedShown = MainWindowController.showDevicePanel
        let savedStrength = QuantizeSetting.strength, savedGrid = QuantizeSetting.grid
        QuantizeSetting.strength = 1; QuantizeSetting.grid = 0.25
        defer {
            QuantizeSetting.strength = savedStrength; QuantizeSetting.grid = savedGrid
            MainWindowController.bottomMode = savedMode
            if MainWindowController.showDevicePanel != savedShown { w.toggleDevicePanel(nil) }
            w.applyBottomMode()
            DevicePanel.copied = nil
            w.clipEditor.focused = false
        }
        w.window?.makeKeyAndOrderFront(nil)
        let tracksBefore = s.tracks.map(\.id)
        let bar = Double(s.framesPerBeat * 4)

        // An empty audio track: double-clicking its lane makes a one-bar MIDI clip (the track becomes an instrument
        // track) and opens it in the docked editor.
        let fresh = s.addTrack("Selftest Empty")
        w.timeline.layoutSubtreeIfNeeded()
        if let i = s.tracks.firstIndex(where: { $0.id == fresh }) { w.timeline.revealTrack(at: i) }
        guard let p = lanePoint(fresh, frame: bar * 1.5) else { return check(false, "the new track's lane is on screen") }
        w.timeline.mouseDown(with: click(w.timeline, p, clicks: 2))
        w.timeline.mouseUp(with: ev(.leftMouseUp, p, clicks: 2))
        let made = s.track(fresh)?.clips.first
        check(made?.isMidi == true && s.track(fresh)?.isInstrument == true, "double-clicking an empty lane makes a MIDI clip (the track becomes an instrument track)")
        check(made.map { abs(Double($0.start) - bar) < 2 && abs(Double($0.length) - bar) < 2 } == true,
              "the new clip fills the bar that was clicked (\(made?.start ?? -1), \(made?.length ?? -1))")
        check(MainWindowController.bottomMode == .clip && !w.clipEditor.isHidden && w.clipEditor.clipId == made?.id && w.devicePanel.isHidden,
              "the new clip opens in the clip editor at the bottom, in place of the devices")
        guard let midi = made?.id else { return }

        // Resizing a MIDI clip from its right edge lengthens it (it used to collapse to one frame).
        w.timeline.selectClips([midi])
        let len0 = s.clip(midi)?.length ?? 0
        dragClip(midi, zone: "right", fraction: 1)
        let len1 = s.clip(midi)?.length ?? 0
        check(len1 > len0 + Int64(bar / 2), "dragging a MIDI clip's right edge lengthens it (\(len0) → \(len1))")
        dragClip(midi, zone: "right", fraction: -0.25)
        check((s.clip(midi)?.length ?? 0) > len0 / 2 && (s.clip(midi)?.length ?? 0) < len1, "and shortens it without it disappearing")

        // Notes: double-click and drag draws a note as long as the drag.
        w.openInClipEditor(midi)
        let roll = w.clipEditor.roll
        w.clipEditor.layoutSubtreeIfNeeded()
        roll.fitToClip()
        guard let c = s.clip(midi) else { return }
        let beat = Double(s.framesPerBeat)
        let a = roll.convert(CGPoint(x: roll.x(Double(c.start) + 0.1 * roll.snapFrames), y: roll.y(64) + roll.rowHeight / 2), to: nil)
        let b = roll.convert(CGPoint(x: roll.x(Double(c.start) + beat * 2), y: roll.y(64) + roll.rowHeight / 2), to: nil)
        roll.mouseDown(with: click(roll, a, clicks: 2))
        for k in 1...6 { roll.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / 6, y: a.y), clicks: 2)) }
        roll.mouseUp(with: ev(.leftMouseUp, b, clicks: 2))
        let drawn = s.clip(midi)?.notes.first { $0.pitch == 64 }
        check(drawn.map { abs(Double($0.length) - beat * 2) <= roll.snapFrames / 2 + 1 } == true && e.undoName == "Add Note",
              "double-click-dragging draws a note two beats long, one undo step (\(drawn?.length ?? -1) frames, \(e.undoName))")
        check(w.pianoRollIsKey, "the docked piano roll takes the editing keys once clicked")
        try? w.snapshot(to: workdir.appendingPathComponent("clip-editor-midi.png"))

        // Copy and paste notes (⌘C / ⌘V at the playhead), duplicate (⌘D).
        roll.selection = Set((s.clip(midi)?.notes ?? []).map { roll.key($0) })
        check(key("c", 8) && PianoRollView.clipboard.count == roll.selection.count, "⌘C copies the selected notes")
        let pasteAt = c.start + Int64(beat * 3)
        e.seek(pasteAt); await waitUntil { e.position == pasteAt }
        let n0 = s.clip(midi)?.notes.count ?? 0
        check(key("v", 9) && s.clip(midi)?.notes.count == n0 + 1, "⌘V pastes the notes in the clip")
        check(s.clip(midi)?.notes.contains { $0.pitch == 64 && $0.start == pasteAt - c.start + c.offset } == true, "at the playhead")
        check(key("d", 2) && s.clip(midi)?.notes.count == n0 + 2, "⌘D repeats the selected notes")

        // The piano roll's playhead follows the transport.
        let into = c.start + Int64(beat)
        e.seek(into); _ = await waitUntil { e.position == into }
        w.clipEditor.tick()
        check(!roll.playheadLayer.isHidden && abs(roll.playheadLayer.frame.midX - roll.x(Double(into))) <= 2,
              "the piano roll shows the playhead (\(roll.playheadLayer.frame.midX) vs \(roll.x(Double(into))))")
        // Q quantizes the selected notes with the quantize value; Play starts at the selected notes.
        let off = Int64(roll.snapFrames * 0.3)
        let sixteenth = beat / 4
        s.setNotes(midi, [DalnokNote(start: c.offset + Int64(sixteenth) + off, length: Int64(sixteenth), pitch: 70, velocity: 100)])
        roll.selection = []
        roll.keyDown(with: keyEvent("q", code: 12))
        let q = s.clip(midi)?.notes.first?.start ?? -1
        check(abs(Double(q - c.offset) - sixteenth) <= 1 && e.undoName == "Quantize", "Q quantizes the notes to 1/16 (\(q - c.offset) vs \(sixteenth))")
        roll.selection = Set((s.clip(midi)?.notes ?? []).map { roll.key($0) })
        e.seek(0); await waitUntil { e.position == 0 }
        w.togglePlay()
        _ = await waitUntil { e.position > 0 }
        check(abs(Double(e.position) - (Double(c.start) + sixteenth)) <= 4_096, "Play starts at the selected notes (\(e.position))")
        e.pause()

        // The Clip / Devices switch.
        w.bottomTabs.selectedSegment = 1
        w.bottomTabChosen(w.bottomTabs)
        check(!w.devicePanel.isHidden && w.clipEditor.isHidden, "the switch shows the device chain")
        check(perform("Clip Editor", exact: true) && !w.clipEditor.isHidden && w.devicePanel.isHidden, "View ▸ Clip Editor switches back")

        // Plug-ins: copy a unit on one track and paste it on another (new instance, same settings).
        let fx = s.addTrack("Selftest FX")
        w.headers.select(fx)
        let slot = (try? s.addPlugin(fx, path: "dalnok:channel-eq")) ?? 0
        check(slot != 0, "a built-in plug-in loads for the copy test")
        _ = dalnok_plugin_set_parameter(e.handle, slot, 18, 0.875)
        w.setBottomMode(.devices)
        w.devicePanel.rebuild()
        w.window?.makeFirstResponder(nil) // nothing being typed (an earlier step may leave a field editing)
        w.devicePanel.select(slot, [])
        check(key("c", 8) && DevicePanel.copied?.slots == [slot], "⌘C copies the selected plug-in")
        let target = s.addTrack("Selftest Paste")
        w.headers.select(target)
        check(key("v", 9) && s.track(target)?.plugins.count == 1 && e.undoName == "Paste Plug-in",
              "⌘V puts a copy on the selected track (\(s.track(target)?.plugins.count ?? 0), \(e.undoName))")
        if let copy = s.track(target)?.plugins.first?.id {
            var p = DalnokPluginParameter(), v = -1.0
            for i in 0..<dalnok_plugin_parameter_count(e.handle, copy) where dalnok_plugin_parameter(e.handle, copy, i, &p) == DALNOK_OK && p.id == 18 { v = p.value }
            check(abs(v - 0.875) < 1e-6, "the pasted plug-in keeps the copied settings (\(v))")
        }
        check(trackMenuHas("Duplicate Track"), "the track's right-click menu offers Duplicate Track")

        // Audio: double-click opens the sample view; Q cuts at the transients and puts them on the grid.
        let drums = s.addTrack("Selftest Drums")
        let rate = e.sampleRate, step = Int(beat / 2) // eighths
        let total = step * 9
        var x = [Float](repeating: 0, count: total)
        for k in 1...7 {
            let at = k * step + [0, 900, -800, 600, -700, 500, -400, 300][k] * Int(rate / 48_000)
            for i in 0..<Int(rate * 0.12) where at + i < total {
                let t = Double(i) / rate
                x[at + i] += Float(min(1, t / 0.0003) * exp(-t / 0.03) * 0.6 * sin(2 * .pi * 200 * t))
            }
        }
        let audioClip: DalnokClipId = x.withUnsafeBufferPointer { buf in
            var ptr: UnsafePointer<Float>? = buf.baseAddress
            guard let m = dalnok_media_from_samples(&ptr, 1, Int64(total), rate) else { return 0 }
            defer { dalnok_media_release(m) }
            return DalnokEngine.dalnok_clip_add(e.handle, drums, dalnok_pool_add(e.handle, m, nil), 0, 0, 0)
        }
        s.refresh()
        w.timeline.layoutSubtreeIfNeeded()
        if let i = s.tracks.firstIndex(where: { $0.id == drums }) { w.timeline.revealTrack(at: i) }
        if let ap = w.timeline.windowPoint(ofClip: audioClip) {
            w.timeline.mouseDown(with: click(w.timeline, ap, clicks: 2))
            w.timeline.mouseUp(with: ev(.leftMouseUp, ap, clicks: 2))
        }
        check(w.clipEditor.clipId == audioClip && !w.clipEditor.audio.isHidden && w.clipEditor.roll.isHidden,
              "double-clicking an audio clip opens it in the clip editor's sample view")
        try? w.snapshot(to: workdir.appendingPathComponent("clip-editor-audio.png"))
        w.timeline.selectClips([audioClip])
        w.clipEditor.focused = false
        check(perform("Quantize Selection", exact: true) && s.track(drums)?.clips.count == 1 && (s.clip(audioClip)?.warp.count ?? 0) > 2,
              "Q quantizes audio in place: one clip, warped (\(s.track(drums)?.clips.count ?? 0) clips, \(s.clip(audioClip)?.warp.count ?? 0) anchors)")
        // The sample view's playhead follows the transport through the warp.
        let inside = Int64(step * 3 + step / 2)
        e.seek(inside); _ = await waitUntil { e.position == inside }
        w.openInClipEditor(audioClip)
        w.clipEditor.tick()
        let av = w.clipEditor.audio
        if let qc = s.clip(audioClip) {
            let want = av.x(qc.sourceFrame(atClipTime: Double(inside - qc.start)))
            check(!av.playheadLayer.isHidden && abs(av.playheadLayer.frame.midX - want) <= 2, "the audio editor shows the playhead (\(av.playheadLayer.frame.midX) vs \(want))")
        }
        s.setSolo(drums, true) // only the drums in the offline mix
        var l = [Float](repeating: 0, count: total), r = l
        _ = dalnok_render_offline(e.handle, 0, Int64(total), &l, &r) // only this track plays here? the mix: check the track's own peaks
        let hits = (1...7).map { k -> Int in
            let lo = k * step - step / 3, hi = min(total, k * step + step / 3)
            return (lo..<hi).first { abs(l[$0]) > 0.1 } ?? -1
        }
        check(hits.enumerated().allSatisfy { abs($0.element - ($0.offset + 1) * step) <= Int(rate * 0.001) },
              "every hit sounds on its eighth note within 1 ms (\(hits.enumerated().map { $0.element - ($0.offset + 1) * step }))")
        s.setSolo(drums, false)
        try? w.snapshot(to: workdir.appendingPathComponent("clip-quantized.png"))
        // Moving a quantized hit by hand in the arrangement: ⌃-drag its marker; the hit sounds where it was dropped.
        if let qc = s.clip(audioClip), let i = qc.warpMarkers(sampleRate: rate).dropFirst(2).first,
           let mp = w.timeline.windowPoint(ofWarp: i, in: audioClip) {
            let before = qc.warp[i].time
            let dx = CGFloat(rate * 0.02 / w.timeline.framesPerPoint) // 20 ms later
            w.timeline.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: mp, modifierFlags: .control, timestamp: 0,
                                                          windowNumber: w.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            for k in 1...6 {
                w.timeline.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: mp.x + dx * CGFloat(k) / 6, y: mp.y),
                                                                 modifierFlags: .control, timestamp: 0, windowNumber: w.window!.windowNumber,
                                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            w.timeline.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: mp.x + dx, y: mp.y), .control))
            let after = s.clip(audioClip)?.warp[i].time ?? before
            check(abs(Double(after - before) - rate * 0.02) <= w.timeline.framesPerPoint * 2 && e.undoName == "Move Quantized Hit",
                  "dragging a quantized hit's marker moves it (\(after - before) frames, \(e.undoName))")
            var l2 = [Float](repeating: 0, count: total), r2 = l2
            _ = dalnok_render_offline(e.handle, 0, Int64(total), &l2, &r2)
            if let moved = s.clip(audioClip) {
                let hitAt = Int(moved.start + moved.warp[i].time + moved.warpHitOffset(sampleRate: rate))
                let first = (hitAt - step / 3..<min(total, hitAt + step / 3)).first { abs(l2[$0]) > 0.1 } ?? -1
                check(abs(first - hitAt) <= Int(rate * 0.001), "the moved hit sounds where it was dropped (\(first - hitAt) frames)")
            }
            // The sample view: dragging the same hit's marker pins that time to other audio.
            let av = w.clipEditor.audio
            if let mc = s.clip(audioClip) {
                let srcBefore = mc.warp[i].source
                let ax = av.x(Double(srcBefore) + (rate * 0.006).rounded())
                let ap = av.convert(CGPoint(x: ax, y: av.bounds.height - 20), to: nil)
                let adx = CGFloat(rate * 0.003 / av.framesPerPoint)
                av.mouseDown(with: mouse(.leftMouseDown, ap))
                av.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: ap.x + adx, y: ap.y)))
                av.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: ap.x + adx, y: ap.y)))
                let srcAfter = s.clip(audioClip)?.warp[i].source ?? srcBefore
                check(srcAfter > srcBefore && e.undoName == "Move Quantized Hit",
                      "dragging a hit in the sample view pins other audio to it (\(srcAfter - srcBefore) frames)")
            }
        } else { check(false, "the quantized clip has hit markers on screen") }
        for _ in 0..<6 where (s.clip(audioClip)?.warp.count ?? 0) > 0 { _ = perform("Undo") } // the hits, Unsolo, Solo, the quantize
        check(s.clip(audioClip)?.warp.isEmpty == true, "undo restores the clip as recorded")

        // The hover playhead follows the mouse over the arrangement.
        if let hp = lanePoint(drums, frame: bar * 2) {
            w.timeline.mouseMoved(with: ev(.mouseMoved, hp))
            check(!w.timeline.hoverLine.isHidden && w.timeline.hoverFrame.map { abs(Double($0) - bar * 2) <= Double(w.timeline.snapQuantum()) } == true,
                  "hovering over the timeline shows a playhead outline there (\(w.timeline.hoverFrame ?? -1))")
            w.timeline.mouseExited(with: ev(.mouseMoved, hp))
            check(w.timeline.hoverLine.isHidden, "and it goes when the mouse leaves")
        }
        // Play from a selected clip.
        if let ap = w.timeline.windowPoint(ofClip: audioClip) {
            e.seek(Int64(bar * 4)); await waitUntil { e.position == Int64(bar * 4) }
            w.timeline.mouseDown(with: click(w.timeline, ap))
            w.timeline.mouseUp(with: ev(.leftMouseUp, ap))
            w.togglePlay()
            _ = await waitUntil { e.position < Int64(bar) }
            check(e.position < Int64(bar), "Play starts at the selected clip, not the playhead (\(e.position))")
            e.pause()
        }
        // Input Monitoring with no input chosen: a connected interface, not the Mac's own microphone.
        let devices = Engine.recordingDevices()
        if devices.contains(where: { !MainWindowController.isBuiltInOrPhone($0) }) && !MainWindowController.simulatedInput {
            let chosen = MainWindowController.recordingInputUID
            MainWindowController.recordingInputUID = nil
            check(w.recordingDevice.map { !MainWindowController.isBuiltInOrPhone($0) } == true,
                  "with no input chosen, monitoring uses the audio interface (\(w.recordingDevice?.name ?? "none"))")
            MainWindowController.recordingInputUID = chosen
        } else {
            print("SKIP  interface preferred for monitoring (no audio interface connected)")
        }
        for t in s.tracks.map(\.id) where !tracksBefore.contains(t) { s.removeTrack(t) }
    }

    private func trackMenuHas(_ title: String) -> Bool {
        w.headers.contextMenu?.items.contains { $0.title == title } == true
    }
}
