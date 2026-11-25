// Self-test steps (Arrangement), split out of SelfTest.swift (A-18). The harness (check, perform, mouse) lives there.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import DalnokEngine

extension SelfTest {
    /// Writes the timeline's committed layer and a fresh full draw as PNGs (diagnosing a redraw mismatch).
    func dumpTimeline(_ name: String) {
        let tl = w.timeline
        guard let win = tl.window else { return }
        let scale = win.backingScaleFactor, pw = Int(tl.bounds.width * scale), ph = Int(tl.bounds.height * scale)
        func ctx() -> CGContext? {
            let c = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            c?.scaleBy(x: scale, y: scale); return c
        }
        func write(_ c: CGContext?, _ suffix: String) {
            guard let img = c?.makeImage() else { return }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: workdir.appendingPathComponent("\(name)-\(suffix).png"))
        }
        let a = ctx()
        if let a, let layer = tl.layer {
            let overlays = (layer.sublayers ?? []).filter { !$0.isHidden }
            overlays.forEach { $0.isHidden = true }; layer.render(in: a); overlays.forEach { $0.isHidden = false }
        }
        write(a, "committed")
        let b = ctx()
        if let b {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: b, flipped: tl.isFlipped)
            tl.draw(tl.bounds); NSGraphicsContext.restoreGraphicsState()
        }
        write(b, "fresh")
    }

    /// Bytes by which the timeline's committed layer differs from drawing the whole view afresh (see partialTimelineRedraw).
    func timelineMismatch() -> Int {
        let tl = w.timeline
        guard let win = tl.window else { return Int.max }
        func context() -> CGContext? {
            let scale = win.backingScaleFactor, pw = Int(tl.bounds.width * scale), ph = Int(tl.bounds.height * scale)
            guard pw > 0, ph > 0, let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            return ctx
        }
        func bytes(_ ctx: CGContext) -> Data { Data(bytes: ctx.data!, count: ctx.bytesPerRow * ctx.height) }
        func committed() -> Data? {
            guard let layer = tl.layer, let ctx = context() else { return nil }
            // The playhead and selection glow are sublayers that draw(_:) never paints; compare the drawn content only.
            let overlays = (layer.sublayers ?? []).filter { !$0.isHidden }
            overlays.forEach { $0.isHidden = true }
            layer.render(in: ctx)
            overlays.forEach { $0.isHidden = false }
            return bytes(ctx)
        }
        func drawnFresh() -> Data? {
            guard let ctx = context() else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: tl.isFlipped)
            tl.draw(tl.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return bytes(ctx)
        }
        func differing(_ a: Data?, _ b: Data?) -> Int {
            guard let a, let b, a.count == b.count else { return Int.max }
            var n = 0
            a.withUnsafeBytes { x in b.withUnsafeBytes { y in for k in 0..<x.count where abs(Int(x[k]) - Int(y[k])) > 2 { n += 1 } } }
            return n
        }
        return differing(committed(), drawnFresh())
    }

    /// A structural edit on one track redraws only that track's lane, and the result matches drawing everything.
    /// The reference draws the whole view into an identical offscreen context; even a full redraw differs from it by a
    /// few rasterized text bytes, so a partial redraw must differ by no more than a full one does.
    func partialTimelineRedraw() async {
        let tl = w.timeline
        guard s.tracks.count >= 2, let clip = s.tracks[1].clips.first, let win = tl.window else {
            return check(false, "partial redraw check needs two tracks with clips")
        }
        for _ in 0..<2 { tl.needsDisplay = true; win.displayIfNeeded(); CATransaction.flush(); await wait(0.05) }
        let baseline = timelineMismatch()
        var ids = [clip.id]
        _ = dalnok_clips_nudge(s.h, &ids, 1, 4_800)
        s.refresh()
        win.displayIfNeeded(); CATransaction.flush() // the partial redraw, as the run loop would draw it
        let lanes = tl.lanesDrawn, reread = s.rereadTracks
        let partial = timelineMismatch()
        check(reread == [s.tracks[1].id] && lanes == 1,
              "a structural edit on one track redraws only its lane (\(lanes) lane drawn; tracks read \(reread.count))")
        check(partial <= baseline, "the partially redrawn timeline matches a full redraw (\(partial) vs \(baseline) differing bytes)")
        _ = perform("Undo")
    }

    func markersAndTrackTools() async {
        let e = s.engine
        e.pause()
        e.seek(Int64(e.sampleRate * 2)); await settle(e, Int64(e.sampleRate * 2))
        check(perform("Add Marker", exact: true) && s.markers.count == 1 && e.undoName == "Add Marker", "Transport ▸ Add Marker adds one at the playhead")
        e.seek(Int64(e.sampleRate * 6)); await settle(e, Int64(e.sampleRate * 6))
        _ = perform("Add Marker", exact: true)
        e.seek(0); await settle(e, 0)
        var ok = perform("Next Marker", exact: true); await wait(0.15)
        check(ok && abs(e.position - Int64(e.sampleRate * 2)) < 2, "Next Marker jumps to the first marker (\(e.position))")
        ok = perform("Next Marker", exact: true); await wait(0.15)
        check(ok && abs(e.position - Int64(e.sampleRate * 6)) < 2, "and then to the next (\(e.position))")
        ok = perform("Previous Marker", exact: true); await wait(0.15)
        check(ok && abs(e.position - Int64(e.sampleRate * 2)) < 2, "Previous Marker goes back (\(e.position))")
        // Drag the first marker's flag on the ruler: it moves (snapped) as one undo step; a click seeks to it.
        let tl = w.timeline, m0 = s.markers[0]
        let flag = tl.convert(CGPoint(x: tl.xPos(forFrame: Double(m0.frame)) + 4, y: 6), to: nil)
        tl.mouseDown(with: mouse(.leftMouseDown, flag))
        tl.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: flag.x + 80, y: flag.y)))
        tl.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: flag.x + 80, y: flag.y)))
        let moved = s.markers.first { $0.id == m0.id }
        check((moved?.frame ?? 0) > m0.frame && e.undoName == "Move Marker", "dragging a marker flag moves it (\(m0.frame) → \(moved?.frame ?? -1))")
        _ = perform("Undo")
        check(s.markers.first { $0.id == m0.id }?.frame == m0.frame, "undo puts it back")
        e.seek(0); await settle(e, 0)
        tl.mouseDown(with: mouse(.leftMouseDown, flag)); tl.mouseUp(with: mouse(.leftMouseUp, flag))
        await wait(0.15)
        check(abs(e.position - m0.frame) < 2, "clicking a marker flag moves the playhead there")
        s.renameMarker(m0.id, "Verse")
        check(fixedString(s.markers[0].name) == "Verse", "markers can be renamed")
        // View ▸ Composition Overview: sections from the markers (Start, Verse, the next marker), each track's coverage,
        // arrows and Return go to a section, Esc returns.
        func key(_ chars: String, _ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.window?.windowNumber ?? 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        let positionBeforeOverview = e.position
        check(perform("Composition Overview") && !w.overview.isHidden && w.window?.firstResponder === w.overview,
              "View ▸ Composition Overview opens the roadmap with the keyboard in it")
        let secs = w.overview.sections
        check(secs.count == 3 && secs[0].title == "Start" && secs[1].title == "Verse" && secs[1].start == s.markers[0].frame,
              "sections come from the markers (\(secs.map(\.title)))")
        if let t = s.tracks.first, secs.count == 3 {
            let expected = t.clips.map { c in max(0, min(c.end, secs[0].end) - max(c.start, secs[0].start)) }.reduce(0, +)
            check(abs(CompositionOverview.coverage(t, secs[0]) - Double(expected) / Double(secs[0].end - secs[0].start)) < 1e-9,
                  "a track's coverage of a section comes from its clips (\(CompositionOverview.coverage(t, secs[0])))")
        }
        w.overview.keyDown(with: key(String(UnicodeScalar(NSRightArrowFunctionKey)!), 124))
        w.overview.keyDown(with: key("\r", 36))
        await wait(0.4)
        check(w.overview.isHidden && secs.count == 3 && abs(e.position - secs[1].start) < 2 && w.timeline.scrollFrame <= Double(secs[1].start),
              "→ and Return show the Verse section in the arrangement (\(e.position), scroll \(Int(w.timeline.scrollFrame)))")
        _ = perform("Composition Overview")
        w.overview.keyDown(with: key("\u{1b}", 53))
        check(w.overview.isHidden, "Esc returns from the overview")
        e.seek(positionBeforeOverview); await settle(e, positionBeforeOverview)
        check(perform("Delete Marker", exact: true) && s.markers.count == 1, "Delete Marker removes the marker at the playhead")
        _ = perform("Undo"); _ = perform("Undo")
        s.markers.forEach { s.removeMarker($0.id) }
        // Duplicate Track (⌃⇧D): below the original, with its clips; one undo step.
        if let t = s.tracks.first(where: { !$0.isBus && !$0.isStack && !$0.clips.isEmpty }) {
            w.headers.select(t.id)
            let n = s.tracks.count
            check(perform("Duplicate Track", exact: true) && s.tracks.count == n + 1, "Track ▸ Duplicate Track adds a copy")
            let i = s.tracks.firstIndex { $0.id == t.id } ?? 0
            let copy = s.tracks[min(i + 1, s.tracks.count - 1)]
            check(copy.name == t.name + " copy" && copy.clips.count == t.clips.count && w.selectedTrack == copy.id,
                  "the copy sits below with the same clips and is selected (\(copy.name))")
            _ = perform("Undo")
            check(s.tracks.count == n, "undo removes the copy")
        }
        // Bounce Track in Place (⌃⌘B): a new audio track below with one clip; the original muted; one undo step.
        if let t = s.tracks.first(where: { !$0.isBus && !$0.isStack && !$0.clips.isEmpty && !$0.muted }) {
            w.headers.select(t.id)
            let n = s.tracks.count
            check(perform("Bounce Track in Place", exact: true) && s.tracks.count == n + 1, "Track ▸ Bounce Track in Place adds a track")
            let i = s.tracks.firstIndex { $0.id == t.id } ?? 0
            let bounced = s.tracks[min(i + 1, s.tracks.count - 1)]
            check(bounced.name == t.name + " Bounce" && bounced.clips.count == 1 && s.tracks[i].muted && w.selectedTrack == bounced.id,
                  "the bounce sits below with one clip, the original is muted (\(bounced.name))")
            _ = perform("Undo")
            check(s.tracks.count == n && s.tracks.first(where: { $0.id == t.id })?.muted == false, "undo removes the bounce and unmutes")
        }
        // Clip ▸ Loop Clip (L): the clip repeats past its audio when its end is dragged out; drawn pass by pass.
        if let c = s.tracks.flatMap(\.clips).first(where: { !$0.isMidi && $0.rate == 1 && $0.warp.isEmpty && $0.slot < 0 }) {
            tl.selectClips([c.id])
            check(perform("Loop Clip", exact: true) && s.clip(c.id)?.loopLength == c.length, "Clip ▸ Loop Clip loops the selected clip")
            tl.glide(framesPerPoint: Double(c.length) * 2 / Double(max(200, tl.bounds.width)),
                     scrollFrame: Double(max(0, c.start - c.length / 10)), duration: 0) // the whole clip and room to its right
            if let a = tl.windowPoint(ofClip: c.id, zone: "right"), let win = tl.window {
                // ⌃ ignores the grid: drag the right edge out by half the clip's length again.
                let b = CGPoint(x: a.x + (tl.xPos(forFrame: Double(c.start + c.length)) - tl.xPos(forFrame: Double(c.start))) / 2, y: a.y)
                func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: p, modifierFlags: type == .leftMouseDown ? [] : .control,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                tl.mouseDown(with: mouse(.leftMouseDown, a)); tl.mouseDragged(with: mouse(.leftMouseDragged, b)); tl.mouseUp(with: mouse(.leftMouseUp, b))
                s.refresh()
            }
            let looped = s.clip(c.id)
            let want = c.length + c.length / 2
            check(abs((looped?.length ?? 0) - want) <= c.length / 50 && looped?.loopLength == c.length,
                  "dragging a looped clip's end repeats its window (\(looped?.length ?? 0), about \(want); window \(looped?.loopLength ?? 0))")
            try? w.snapshot(to: workdir.appendingPathComponent("clip-loop.png"))
            _ = perform("Undo"); _ = perform("Undo")
            check(s.clip(c.id)?.loopLength == 0 && s.clip(c.id)?.length == c.length, "undo takes back the drag and the loop")
        }
        // Clip ▸ Normalize, Reverse, Join Clips (⌘J), on the Glass sound (not silent).
        if let c = s.tracks.flatMap(\.clips).first(where: { $0.name.hasPrefix("Glass") && !$0.isMidi && $0.rate == 1 && $0.pitch == 0 && $0.warp.isEmpty && $0.loopLength == 0 && !$0.offline && $0.slot < 0 }) {
            tl.selectClips([c.id])
            // A sound already near full scale moves very little; the step and its undo name are what's checked here (the
            // level itself is measured in ClipToolTests).
            check(perform("Normalize", exact: true) && e.undoName == "Normalize" && (s.clip(c.id)?.gainDb ?? 99) <= 24,
                  "Clip ▸ Normalize sets the clip's gain (\(s.clip(c.id)?.gainDb ?? 0) dB)")
            _ = perform("Undo")
            check(perform("Reverse", exact: true) && s.clip(c.id)?.media != c.media && e.undoName == "Reverse", "Clip ▸ Reverse plays a reversed file")
            _ = perform("Undo")
            check(s.clip(c.id)?.media == c.media, "undo plays the clip forwards again")
            if let t = s.tracks.first(where: { $0.clips.contains { $0.id == c.id } })?.id {
                let n = s.track(t)?.clips.count ?? 0
                var right: DalnokClipId = 0
                _ = dalnok_clip_split(e.handle, c.id, c.start + c.length / 2, &right)
                s.refresh()
                tl.selectClips([c.id, right])
                check(perform("Join Clips", exact: true) && s.track(t)?.clips.count == n && e.undoName == "Join Clips",
                      "Clip ▸ Join Clips makes one clip of the two halves")
                _ = perform("Undo"); _ = perform("Undo")
                check(s.track(t)?.clips.count == n && s.clip(c.id)?.length == c.length, "undo restores the clip")
            }
        }
        // Clip ▸ Slice to Drums: a new Drums track below with a MIDI clip of the slices; the clip muted; one undo.
        if let c = s.tracks.flatMap(\.clips).first(where: { !$0.isMidi && $0.rate == 1 && $0.pitch == 0 && $0.warp.isEmpty && $0.loopLength == 0 && !$0.offline && $0.slot < 0 }) {
            tl.selectClips([c.id])
            let n = s.tracks.count
            check(perform("Slice to Drums", exact: true) && s.tracks.count == n + 1 && s.clip(c.id)?.muted == true,
                  "Clip ▸ Slice to Drums adds a Drums track and mutes the clip")
            if let drums = s.tracks.first(where: { $0.name.hasSuffix(" Slices") }) {
                check(drums.plugins.first?.name == "Dalnok Drums" && (drums.clips.first?.noteCount ?? 0) >= 1,
                      "the new track plays the slices (\(drums.clips.first?.noteCount ?? 0) notes)")
            }
            _ = perform("Undo")
            check(s.tracks.count == n && s.clip(c.id)?.muted == false, "one undo takes the slicing back")
        }
        // Clip ▸ Set Project Tempo from Clip: a 110 BPM kick loop sets the tempo; one undo takes it back.
        do {
            let rate = Int(e.sampleRate), beat = 60.0 / 110
            var data = Data()
            func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            let frames = rate * 8, bytes = frames * 2
            data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVEfmt ".utf8))
            le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
            data.append(contentsOf: Array("data".utf8)); le(UInt32(bytes))
            for i in 0..<frames {
                let t = Double(i) / Double(rate), since = t.truncatingRemainder(dividingBy: beat)
                le(Int16(exp(-since * 14) * sin(2 * .pi * 55 * since) * 20_000))
            }
            let wav = workdir.appendingPathComponent("kick-110.wav")
            try? data.write(to: wav)
            let before = s.tracks.count, oldBpm = s.bpm
            await withCheckedContinuation { cont in s.importFiles([wav]) { cont.resume() } }
            s.refresh()
            if s.tracks.count == before + 1, let c = s.tracks.last?.clips.first {
                tl.selectClips([c.id])
                check(perform("Set Project Tempo from Clip", exact: true) && abs(s.bpm - 110) < 0.2,
                      "Clip ▸ Set Project Tempo from Clip hears 110 BPM (\(s.bpm))")
                _ = perform("Undo")
                check(abs(s.bpm - oldBpm) < 1e-9, "one undo restores the tempo (\(s.bpm))")
                _ = perform("Undo")
            } else { check(false, "the kick loop imports") }
            check(s.tracks.count == before, "the kick loop's import is undone")
        }
        // Hide Track / Show All Tracks: out of view, still playing; the header title counts them.
        if let t = s.tracks.first {
            w.headers.select(t.id)
            let n = s.tracks.count
            check(perform("Hide Track", exact: true) && s.tracks.count == n - 1 && s.hiddenCount == 1 && w.headers.row(t.id) == nil,
                  "Track ▸ Hide Track removes it from the arrangement")
            check(s.allTracks.contains { $0.id == t.id }, "the hidden track is still in the project")
            check(perform("Show All Tracks", exact: true) && s.tracks.count == n && s.hiddenCount == 0, "Show All Tracks brings it back")
        }
        // Zoom to selection and vertical zoom.
        if let c = s.tracks.flatMap(\.clips).first {
            tl.selectClips([c.id])
            check(perform("Zoom to Selection", exact: true), "View ▸ Zoom to Selection")
            let x0 = tl.xPos(forFrame: Double(c.start)), x1 = tl.xPos(forFrame: Double(c.end))
            check(x0 >= 0 && x1 <= tl.bounds.width && (x1 - x0) > tl.bounds.width * 0.8, "the selected clip fills the view (\(Int(x0))–\(Int(x1)) of \(Int(tl.bounds.width)))")
            tl.selectClips([])
            _ = perform("Zoom to Fit")
        }
        let h0 = Theme.trackHeight
        check(perform("Taller Tracks", exact: true) && Theme.trackHeight > h0, "View ▸ Taller Tracks (\(h0) → \(Theme.trackHeight))")
        w.window?.layoutIfNeeded()
        if let row = w.headers.rows.dropFirst().first {
            check(abs(row.frame.height - Theme.trackHeight) < 0.5 && abs(row.frame.minY - (Theme.trackHeight - w.headers.scrollY)) < 0.5,
                  "header rows follow the new height and stay aligned with the lanes")
        }
        check(perform("Shorter Tracks", exact: true) && abs(Theme.trackHeight - h0) < 0.5, "Shorter Tracks returns to \(h0)")
        w.window?.layoutIfNeeded()
        // One track's height: drag its header's bottom edge (one undo step); the lanes below move with it.
        if w.headers.rows.count >= 2 {
            let row = w.headers.rows[0], id = row.trackId
            let edge = row.convert(CGPoint(x: 40, y: row.bounds.height - 2), to: nil)
            row.mouseDown(with: mouse(.leftMouseDown, edge))
            row.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: edge.x, y: edge.y - 30)))
            row.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: edge.x, y: edge.y - 60)))
            row.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: edge.x, y: edge.y - 60)))
            w.window?.layoutIfNeeded()
            let h = s.track(id)?.height ?? 0
            check(abs(h - (h0 + 60)) < 1 && s.engine.undoName == "Track Height" && abs(w.headers.rows[0].frame.height - h) < 0.5
                  && abs(w.timeline.laneY(1) - (Theme.rulerHeight + h - w.timeline.scrollY)) < 0.5 && abs(s.laneHeight(1) - Theme.trackHeight) < 0.5,
                  "dragging a header's bottom edge sizes that one track; the lanes below follow (\(h))")
            _ = perform("Undo")
            check((s.track(id)?.height ?? -1) == 0, "one undo restores it")
            s.setTrackHeight(id, 56); w.window?.layoutIfNeeded()
            check(w.headers.rows[0].gain.isHidden && !w.headers.rows[0].nameLabel.isHidden, "a short track shows its name and buttons, not its knobs")
            s.setTrackHeight(id, 0); w.window?.layoutIfNeeded()
            check(!w.headers.rows[0].gain.isHidden, "and the knobs return at full height")
            // ⌥-scroll sizes every track.
            let before = Theme.trackHeight
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0) {
                cg.flags = .maskAlternate
                if let ev = NSEvent(cgEvent: cg) { w.timeline.scrollWheel(with: ev) }
            }
            check(Theme.trackHeight > before + 5, "⌥-scroll makes every track taller (\(before) → \(Theme.trackHeight))")
            w.setTrackHeight(before); w.window?.layoutIfNeeded()
        }
        // A long instrument name never runs over the pan knob, and never hides the plug-in count (it takes a second line).
        if let row = w.headers.rows.last { // the first row can be a track this run has hidden
            let (src, counts) = (row.inputSource, row.inputCounts)
            row.setInput(source: "A Very Long Instrument Name", counts: "3 FX")
            row.layoutSubtreeIfNeeded()
            check(row.inputButton.frame.minX >= row.pan.frame.maxX + 7, "the input label stops before the pan knob (truncating)")
            let lines = row.inputButton.title.components(separatedBy: "\n")
            check(lines.count == 2 && lines[1] == "3 FX", "a long input name puts the plug-in count on its own line (\(lines))")
            if let content = row.window?.contentView { // for a look by eye: the window, and where the row is in it
                row.display()
                Screenshots.png(content, workdir.appendingPathComponent("header-two-line.png"))
                print("HEADER-ROW \(NSStringFromRect(row.convert(row.bounds, to: content))) in \(NSStringFromRect(content.bounds))")
            }
            row.setInput(source: "IN 1", counts: "3 FX")
            check(row.inputButton.title == "IN 1 · 3 FX", "a short one keeps it on one line (\(row.inputButton.title))")
            row.setInput(source: src, counts: counts)
        }
        // The small second clock.
        TransportBar.showsSecondaryClock = true
        w.tick()
        check(!w.transport.subTimeLabel.isHidden && !w.transport.subTimeLabel.stringValue.isEmpty
              && w.transport.subTimeLabel.stringValue != w.transport.timeLabel.stringValue, "the second clock shows the other time format (\(w.transport.subTimeLabel.stringValue))")
        TransportBar.showsSecondaryClock = false
        check(w.transport.subTimeLabel.isHidden, "and hides again")
        UserDefaults.standard.removeObject(forKey: "secondaryClock")
    }

    // MARK: Dead controls: nothing may look usable while doing nothing

    func deadControls() {
        var dead: [String] = []
        for a in ShortcutRegistry.shared.actions {
            guard let it = a.item, let sel = it.action else { continue }
            let target: AnyObject? = it.target ?? (NSApp.target(forAction: sel, to: nil, from: it) as AnyObject?) ?? (w.responds(to: sel) ? w : nil)
                ?? (w.window?.responds(to: sel) == true ? w.window : nil) ?? (NSApp.responds(to: sel) ? NSApp : nil)
            if target?.responds(to: sel) != true { dead.append(a.title) }
        }
        check(dead.isEmpty, "every menu command has a handler (\(dead))")
        var buttons: [String] = []
        func walk(_ v: NSView) {
            if !v.isHidden, let b = v as? NSButton, type(of: b) == NSButton.self, b.isEnabled, b.action == nil, b.target == nil {
                buttons.append(b.title.isEmpty ? (b.accessibilityLabel() ?? "untitled") : b.title)
            }
            v.subviews.forEach(walk)
        }
        for win in [w.window, w.pluginManager.window, w.shortcutsEditor.window].compactMap({ $0 }) { if let c = win.contentView { walk(c) } }
        check(buttons.isEmpty, "no enabled button without an action (\(buttons))")
        // Accessibility: every visible, enabled control has a name VoiceOver can read.
        var unnamed: [String] = []
        func walkNames(_ v: NSView) {
            guard !v.isHidden else { return } // a hidden container hides everything in it
            if let c = v as? NSControl, c.isAccessibilityElement(), !(c is NSScroller), c.isEnabled, !(c is NSTextField && !(c as! NSTextField).isEditable) {
                let label = c.accessibilityLabel() ?? ""
                let title = (c as? NSButton)?.title ?? (c as? NSPopUpButton)?.titleOfSelectedItem ?? (c as? NSSearchField)?.placeholderString ?? ""
                let segs = (c as? NSSegmentedControl).map { sc in (0..<sc.segmentCount).compactMap { sc.label(forSegment: $0) }.joined() } ?? ""
                if label.isEmpty && title.isEmpty && segs.isEmpty && (c as? NSTextField)?.placeholderString?.isEmpty != false {
                    unnamed.append(String(describing: type(of: c)) + (c.toolTip.map { " (\($0.prefix(30)))" } ?? ""))
                }
            }
            v.subviews.forEach(walkNames)
        }
        for win in [w.window, w.pluginManager.window, w.shortcutsEditor.window].compactMap({ $0 }) { if let c = win.contentView { walkNames(c) } }
        check(unnamed.isEmpty, "every enabled control has an accessible name (\(Set(unnamed).sorted().prefix(12)))")
    }

    // MARK: Tape machine (Analog Mode transport)

    func tapeMachine() async {
        let e = s.engine
        e.pause(); e.seek(0); await settle(e, 0)
        check(perform("Tape Machine", exact: true) && w.tapeDeck?.window?.isVisible == true, "View ▸ Tape Machine opens the deck")
        guard let deck = w.tapeDeck?.deck else { return }
        let saved = Motion.override; Motion.override = true; defer { Motion.override = saved }
        if let window = w.tapeDeck?.window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(deck.loop)
            await wait(0.15)
            func deckKey(_ chars: String, _ code: UInt16) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
            }
            let space = deckKey(" ", 49), enter = deckKey("\r", 36)
            let cycleBefore = s.cycle.on
            check(!(NSApp.mainMenu?.performKeyEquivalent(with: space) ?? true), "focused tape key keeps Space from the shortcut registry")
            deck.loop.keyDown(with: space); deck.loop.keyUp(with: space)
            check(s.cycle.on != cycleBefore && !e.isPlaying, "Space activates focused LOOP instead of starting playback")
            deck.loop.keyDown(with: enter); deck.loop.keyUp(with: enter)
            check(s.cycle.on == cycleBefore, "Return activates the focused tape key")
            window.makeFirstResponder(deck.ffwd)
            deck.ffwd.keyDown(with: space)
            check(w.tapeTransport.winding == 1, "keyboard holds FF while pressed")
            deck.ffwd.keyUp(with: space)
            check(w.tapeTransport.winding == 0, "releasing the keyboard stops FF")
        }
        deck.step(dt: 0.016)
        let a0 = deck.model.angles
        deck.play.onPress?()
        await wait(0.6)
        deck.step(dt: 0.016)
        check(e.isPlaying && deck.play.lit, "PLAY starts the shared transport and lights")
        check(deck.model.angles.0 > a0.0 && deck.model.angles.1 > a0.1, "both reels turn forward while playing (\(a0) → \(deck.model.angles))")
        let start = e.position
        deck.pause.onPress?(); await wait(0.15); deck.step(dt: 0.016)
        let held = deck.model.angles
        await wait(0.2); deck.step(dt: 0.016)
        check(!e.isPlaying && deck.model.angles == held, "PAUSE stops the reels where they are")
        deck.wind(1, seconds: 1)
        await wait(0.15); deck.step(dt: 0.016)
        let wound = Double(e.position - start) / e.sampleRate
        check(abs(wound - TapeDeckView.windSpeed) < 1.5 && deck.model.angles.1 > held.1, "F.FWD winds the playhead forward at \(TapeDeckView.windSpeed)× (\(wound) s)")
        // Let the reel animation catch the forward seek before testing the opposite direction.
        for _ in 0..<40 {
            if abs(deck.model.shown - Double(e.position) / e.sampleRate) < 0.1 { break }
            await wait(0.05); deck.step(dt: 0.05)
        }
        let before = deck.model.angles
        deck.wind(-1, seconds: 0.5)
        for _ in 0..<40 {
            await wait(0.05); deck.step(dt: 0.05)
            if deck.model.angles.1 < before.1 { break }
        }
        check(deck.model.angles.1 < before.1, "REWIND turns the reels backwards")
        deck.play.onPress?(); await wait(0.3)
        deck.stop.onPress?(); await wait(0.15)
        check(!e.isPlaying && abs(e.position - deck.playStartForTests) < Int64(e.sampleRate * 0.05), "STOP returns to where playback started")
        deck.rtz.onPress?(); await wait(0.15)
        check(e.position == 0, "RTZ returns to zero")
        let cycle = s.cycle.on
        deck.loop.onPress?(); deck.step(dt: 0.016)
        check(s.cycle.on != cycle && deck.loop.lit == s.cycle.on, "LOOP toggles the same cycle as the main window")
        deck.loop.onPress?()
        // The tape speed changes the drawing only.
        deck.speedSwitch.selectedSegment = 2; _ = deck.speedSwitch.target?.perform(deck.speedSwitch.action, with: deck.speedSwitch)
        check(deck.model.speedFactor == 2, "the 30 ips switch doubles the tape speed of the drawing")
        deck.speedSwitch.selectedSegment = 1; _ = deck.speedSwitch.target?.perform(deck.speedSwitch.action, with: deck.speedSwitch)
        if let v = w.tapeDeck?.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: workdir.appendingPathComponent("tape-machine.png"))
        }
        w.tapeDeck?.window?.close()
        e.seek(0); await settle(e, 0)
        // Warm Analog: the same keys live in the control bar, so the window is optional.
        if (Theme.activeStyle == .warmAnalog) {
            let strip = w.transport.tapeStrip
            check(strip.superview != nil && strip.reels.superview != nil && strip.transport != nil, "the control bar carries the tape strip (reels and keys)")
            strip.play.onPress?(); await wait(0.4)
            check(e.isPlaying, "the bar's PLAY key starts the transport")
            await wait(0.1)
            check(strip.play.lit, "and its lamp lights")
            strip.play.onPress?(); await wait(0.2)
            check(!e.isPlaying, "pressing PLAY again pauses")
            let p0 = e.position
            w.tapeTransport.wind(1, seconds: 0.5); await wait(0.15)
            check(Double(e.position - p0) / e.sampleRate > 5, "the bar's FF winds the playhead (shared with the window)")
            strip.rtz.onPress?(); await wait(0.15)
            check(e.position == 0, "RTZ in the bar returns to zero")
        }
    }

    // MARK: Cut / copy / paste / duplicate / select all

    func clipEditing() async {
        let e = s.engine
        guard let t0 = s.tracks.first, let c = t0.clips.first else { return check(false, "a clip exists for clip editing") }
        w.window?.makeKeyAndOrderFront(nil)
        check(menuItem("Copy", exact: true)?.target == nil && menuItem("Paste", exact: true)?.target == nil,
              "Cut/Copy/Paste go through the responder chain (text fields keep ⌘C/⌘V)")
        let before = t0.clips.count
        w.timeline.selectClips([c.id])
        check(perform("Mute Clip", exact: true) && s.clip(c.id)?.muted == true, "Clip ▸ Mute Clip mutes the selected clip")
        check(menuItem("Unmute Clip", exact: true)?.isEnabled == true, "the clip menu offers Unmute Clip")
        check(perform("Unmute Clip", exact: true) && s.clip(c.id)?.muted == false, "Clip ▸ Unmute Clip restores the selected clip")
        check(perform("Duplicate", exact: true) && s.track(t0.id)?.clips.count == before + 1, "Edit ▸ Duplicate adds a copy")
        let dup = w.timeline.selectedClip.flatMap { s.clip($0) }
        check(dup?.start == c.end && dup?.length == c.length && dup?.offset == c.offset && e.undoName == "Duplicate",
              "the copy starts where the clip ends, same region (\(dup?.start ?? -1) vs \(c.end))")
        check(perform("Undo") && s.track(t0.id)?.clips.count == before, "undo removes the duplicate")
        // Cut and paste with real key events.
        w.timeline.selectClips([c.id])
        e.seek(c.end + 24_000); await waitUntil { e.position == c.end + 24_000 } // the audio thread applies seeks
        let at = e.position
        _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("x", code: 7, .command))
        check(s.clip(c.id) == nil && e.undoName.hasPrefix("Cut"), "⌘X cuts the clip (\(e.undoName))")
        w.headers.select(t0.id)
        _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("v", code: 9, .command))
        let pasted = w.timeline.selectedClip.flatMap { s.clip($0) }
        check(pasted?.track == t0.id && pasted?.start == at && pasted?.length == c.length && pasted?.offset == c.offset,
              "⌘V pastes the cut clip at the playhead (\(pasted?.start ?? -1) vs \(at))")
        _ = perform("Undo"); _ = perform("Undo")
        check(s.clip(c.id)?.start == c.start && s.track(t0.id)?.clips.count == before, "undo twice puts the clip back")
        let all = s.tracks.flatMap(\.clips).count
        check(ShortcutRegistry.shared.action("edit.select_all").map { ShortcutRegistry.shared.perform($0) } == true && w.timeline.selectedClips.count == all, "Edit ▸ Select All selects \(all) clips")
        w.timeline.selectClips([])
        e.seek(0); await settle(e, 0)
    }

    // MARK: Migration & onboarding

    func migrationSteps() async {
        let e = s.engine
        let savedDAW = SourceDAW.preferred, savedDone = WelcomeController.hasCompleted
        defer {
            SourceDAW.preferred = savedDAW
            WelcomeController.hasCompleted = savedDone
            Migration.applyKeymap(savedDAW, to: NSApp.mainMenu)
        }
        // Palette speaks other DAWs' languages.
        w.showCommandPalette(nil)
        w.palette.filter("bounce")
        let bounceHits = w.palette.results.prefix(3).map(\.title) // Logic's word for export, and Bounce in Place
        check(bounceHits.contains("Export Mix…") && bounceHits.contains("Bounce Track in Place"), "palette: 'bounce' → \(bounceHits)")
        w.palette.filter("split region")
        check(w.palette.results.first?.title == "Split at Playhead", "palette: 'split region' → \(w.palette.results.first?.title ?? "-")")
        w.palette.filter("collect all and save")
        check(w.palette.results.first?.title == "Copy Audio into Project on Save", "palette: Ableton's 'collect all and save'")
        w.palette.filter("flex time")
        check(w.palette.results.contains { $0.title.hasPrefix("Flex Time") && $0.item == nil }, "palette lists planned 'Flex Time' with status")
        w.palette.close()

        // Shortcut presets: expected keys, and no collisions in any preset.
        for daw in [SourceDAW.logic, .ableton, .reaper] {
            Migration.applyKeymap(daw, to: NSApp.mainMenu)
            let split = menuItem("Split at Playhead")
            let expected = daw == .ableton ? ("e", NSEvent.ModifierFlags.command) : daw == .reaper ? ("s", []) : ("t", .command)
            check(split?.keyEquivalent == expected.0 && split?.keyEquivalentModifierMask == expected.1,
                  "\(daw.title) preset: Split = \(PaletteIndex.shortcutString(split!))")
            let conflicts = Migration.shortcutConflicts(NSApp.mainMenu)
            check(conflicts.isEmpty, "\(daw.title) preset has no shortcut collisions \(conflicts)")
        }
        Migration.applyKeymap(nil, to: NSApp.mainMenu)
        check(menuItem("Split at Playhead")?.keyEquivalent == "t", "Dalnok defaults restored")

        // Concept guide.
        w.conceptGuide.show(daw: .ableton, query: "warp")
        check(w.conceptGuide.rows.contains { $0.term == "Warping" }, "concept guide: Ableton 'Warping' → \(w.conceptGuide.rows.first?.dalnok ?? "-")")
        w.conceptGuide.window.orderOut(nil)

        await recordingAndMidi()
        await realAudioInput()
        await motion()
        await navigation()
        pluginManager()
        hostedPlugins()
        devicePanel()
        await deviceFolding()

        // Import a REAPER project end to end (fixture built from this run's audio files).
        let media = workdir.appendingPathComponent("Media")
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for f in files { try? FileManager.default.copyItem(at: f, to: media.appendingPathComponent(f.lastPathComponent)) }
        var rpp = "<REAPER_PROJECT 0.1 \"7.0/macOS\"\n  SAMPLERATE 48000 0 0\n"
        for (i, f) in files.enumerated() {
            rpp += "  <TRACK\n    NAME \"Imported \(i + 1)\"\n    VOLPAN 1 0 -1 -1 1\n    <ITEM\n      POSITION \(i)\n      LENGTH 1\n"
                + "      <SOURCE WAVE\n        FILE \"Media\\\(f.lastPathComponent)\"\n      >\n    >\n  >\n"
        }
        rpp += "  <TRACK\n    NAME Keys\n    <ITEM\n      POSITION 0\n      LENGTH 2\n      <SOURCE MIDI\n      >\n    >\n  >\n>\n"
        let rppURL = workdir.appendingPathComponent("from-reaper.rpp")
        try? rpp.write(to: rppURL, atomically: true, encoding: .utf8)
        let logicPackage = workdir.appendingPathComponent("Example.logicx", isDirectory: true)
        try? FileManager.default.createDirectory(at: logicPackage, withIntermediateDirectories: true)
        check(w.panel(NSOpenPanel(), shouldEnable: logicPackage), "Open enables Logic project packages")
        check(menuItem("Import Project from Another DAW") == nil, "foreign projects use the Open menu")
        check(w.saveProject(to: workdir.appendingPathComponent("before-import.dalnok")), "save before import prompt")
        let revision = e.revision
        Task { await wait(0.2); if let sheet = w.window?.attachedSheet { w.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) } }
        let cancelled = await withCheckedContinuation { cont in w.openSelectedProject(rppURL) { cont.resume(returning: $0) } }
        check(!cancelled && e.revision == revision, "cancel import leaves the current project unchanged")
        Task { await wait(0.2); if let sheet = w.window?.attachedSheet { w.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn) } }
        let ok = await withCheckedContinuation { cont in w.openSelectedProject(rppURL) { cont.resume(returning: $0) } }
        check(ok && w.lastImportReport?.app == "REAPER", "Open confirms and imports a REAPER project")
        check(s.tracks.count == files.count + 1 && s.tracks.flatMap(\.clips).allSatisfy { !$0.offline }, "\(s.tracks.count) tracks, all audio found")
        check(s.tracks.flatMap(\.clips).map(\.start).sorted() == (0..<files.count).map { Int64($0) * Int64(e.sampleRate) },
              "clip positions from the RPP")
        check(w.lastImportReport?.notImported.first?.contains("MIDI") == true, "report explains the skipped MIDI item")
        let unavailableReport = ImportReport(json: "{}", unavailablePlugins: ["Track — Instrument: state rejected"])
        check(unavailableReport?.unavailablePlugins.first?.contains("state rejected") == true, "import report retains unavailable plug-in details")
        check(e.isDirty && s.projectURL == nil && w.window?.title == "Untitled", "import is a new unsaved project")

        // Stems folder.
        let stems = workdir.appendingPathComponent("Stems")
        try? FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        for (i, f) in files.enumerated() { try? FileManager.default.copyItem(at: f, to: stems.appendingPathComponent("Mix#0\(i + 1) \(f.lastPathComponent)")) }
        let ok2 = await withCheckedContinuation { cont in w.importProject(stems, confirm: false) { cont.resume(returning: $0) } }
        check(ok2 && s.tracks.count == files.count && s.tracks.allSatisfy { $0.clips.first?.start == 0 }, "stems folder → \(s.tracks.count) aligned tracks")
        check(s.tracks.first?.name.hasPrefix("01 ") == true, "common stem prefix stripped (\(s.tracks.first?.name ?? "-"))")

        // Welcome flow: choosing a DAW applies its preset and starts the project finder.
        w.welcome.show()
        // Secondary windows open centered on Dalnok's screen (Settings opened at the bottom-left corner).
        func centered(_ win: NSWindow?) -> Bool {
            guard let win, let vf = (w.window?.screen ?? NSScreen.main)?.visibleFrame else { return false }
            return abs(win.frame.midX - vf.midX) < 2 && abs(win.frame.midY - vf.midY) < 2
        }
        await wait(0.1)
        check(centered(w.welcome.window), "welcome window opens centered (frame \(w.welcome.window.frame))")
        let settingsWasOpen = w.settings.window?.isVisible == true
        if !settingsWasOpen {
            w.settings.show()
            await wait(0.1)
            check(centered(w.settings.window), "settings window opens centered (frame \(String(describing: w.settings.window?.frame)))")
            w.settings.window?.orderOut(nil)
        }
        // First launch: the look (applied as it is picked), then which shortcuts you know, then out of the way.
        let savedPreset = ShortcutRegistry.shared.presetId
        let savedLook = (Theme.preferredStyle, Theme.variantPreference)
        w.shortcutChooser.show()
        await wait(0.1)
        let looks = w.shortcutChooser.lookCards
        check(w.shortcutChooser.step == .look && looks.map(\.style) == Theme.Style.allCases && looks.allSatisfy { LookCard.image($0.style, $0.variant) != nil }
              && looks.filter { $0.versions != nil }.map(\.style) == [.prism, .atelier] && looks.first { $0.isSelected }?.style == Theme.activeStyle,
              "first launch opens on the look: a card with a picture per theme, Light | Dark where there are both, the current one marked")
        w.shortcutChooser.chooseLook(Theme.activeStyle, Theme.activeVariant) // the look in use: kept, no rebuild
        check(Theme.preferredStyle == Theme.activeStyle && w.shortcutChooser.window.isVisible, "picking a look remembers it and keeps the window")
        Theme.preferredStyle = savedLook.0; Theme.variantPreference = savedLook.1
        w.shortcutChooser.continueTapped()
        await wait(0.1)
        check(w.shortcutChooser.step == .shortcuts && centered(w.shortcutChooser.window) && w.shortcutChooser.cards.count == 6, "then it asks which shortcuts you know (6 apps; \(w.shortcutChooser.cards.count) cards, frame \(w.shortcutChooser.window.frame), screen \(String(describing: (w.window?.screen ?? NSScreen.main)?.visibleFrame)))")
        var recoveryOffered = 0
        w.shortcutChooser.onFinished = { recoveryOffered += 1 }
        check(recoveryOffered == 0, "a crash-recovery offer waits while the first-launch questions are open")
        w.shortcutChooser.choose("protools")
        check(recoveryOffered == 1, "and is made once they are answered (\(recoveryOffered) offers)")
        check(ShortcutRegistry.shared.presetId == "protools" && !w.shortcutChooser.window.isVisible && WelcomeController.hasCompleted,
              "choosing Pro Tools applies its shortcuts and closes the window (preset \(ShortcutRegistry.shared.presetId))")
        w.shortcutChooser.choose("logic")
        check(ShortcutRegistry.shared.presetId == "logic" && SourceDAW.preferred == .logic, "choosing Logic Pro also uses its words")
        ShortcutRegistry.shared.selectPreset(savedPreset)
        w.welcome.choose(.ableton)
        check(SourceDAW.preferred == .ableton && menuItem("Split at Playhead")?.keyEquivalent == "e", "welcome: Ableton chosen, preset applied")
        await w.welcome.rescan()
        check(true, "project finder scanned (\(w.welcome.projects.count) projects found)")
        w.welcome.window.orderOut(nil)
    }
}
