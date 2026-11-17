// End-to-end UI self-test: drives real menu items (through the responder
// chain) and synthesized mouse gestures, then verifies the engine model.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import DalnokEngine

@MainActor
final class SelfTest {
    static var running = false
    let app: AppDelegate
    let files: [URL]
    let workdir: URL
    private var failures = 0
    /// Preferences the test changes; all are restored at the end so a run never alters the owner's settings.
    private static let restoredKeys = ["copyAudioOnSave", "comingFrom", "onboardingDone", "recordingInputUID", "rulerBarsAndBeats", "metronome", "showDevicePanel", "countIn", "showMixer", "showLauncher", "automationMode"]
    private let previousPreferences: [String: Any]
    private var w: MainWindowController { app.main }
    private var s: Session { app.session }

    init(app: AppDelegate, files: [URL], workdir: URL) {
        self.app = app
        self.files = files
        self.workdir = workdir
        previousPreferences = Self.restoredKeys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
    }

    private func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    private func menuItem(_ title: String, in menu: NSMenu? = NSApp.mainMenu, submenuOnly: Bool = false, exact: Bool = false) -> NSMenuItem? {
        for it in menu?.items ?? [] {
            if let sub = it.submenu {
                if submenuOnly && it.title == title { return it }
                sub.update() // runs validateMenuItem, which sets dynamic titles
                if let found = menuItem(title, in: sub, submenuOnly: submenuOnly, exact: exact) { return found }
            } else if !submenuOnly && (exact ? it.title == title : it.title.hasPrefix(title)) {
                return it
            }
        }
        return nil
    }

    /// Fires a menu item exactly as a click would (validation + responder chain).
    private func perform(_ title: String, exact: Bool = false) -> Bool {
        guard let it = menuItem(title, exact: exact), let m = it.menu else { return false }
        m.update()
        guard it.isEnabled else { return false }
        m.performActionForItem(at: m.index(of: it))
        return true
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: 1)!
    }

    /// Drags by a fraction of the clip's on-screen width (works for any clip length).
    private func dragClip(_ id: DalnokClipId, zone: String, fraction: CGFloat, mods: NSEvent.ModifierFlags = []) {
        guard let c = s.clip(id) else { return check(false, "clip exists") }
        dragClip(id, zone: zone, dx: CGFloat(Double(c.length) / w.timeline.framesPerPoint) * fraction, mods: mods)
    }

    private func dragClip(_ id: DalnokClipId, zone: String, dx: CGFloat, mods: NSEvent.ModifierFlags = []) {
        guard let p = w.timeline.windowPoint(ofClip: id, zone: zone) else { return check(false, "clip on screen") }
        w.timeline.mouseDown(with: mouse(.leftMouseDown, p, mods))
        for k in 1...10 { w.timeline.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: p.x + dx * CGFloat(k) / 10, y: p.y))) }
        w.timeline.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: p.x + dx, y: p.y)))
    }

    private func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    func run() {
        Self.running = true
        MainWindowController.copyAudioOnSave = true
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        s.importFiles(files) { [self] in Task { await steps() } }
    }

    private func steps() async {
        let e = s.engine
        check(s.tracks.count == files.count, "import \(files.count) files -> \(s.tracks.count) tracks")
        check(e.undoName.hasPrefix("Import"), "import is one undo step (\(e.undoName))")
        guard let first = s.tracks.first?.clips.first else { return finish() }

        // Split via menu at 1 s.
        w.timeline.selectedClip = first.id
        e.seek(Int64(e.sampleRate))
        await wait(0.3)
        check(perform("Split at Playhead"), "menu Edit > Split at Playhead enabled")
        check(s.tracks.first?.clips.count == 2, "split made 2 clips")
        check(menuItem("Undo")?.title == "Undo Split at Playhead", "undo title is \"\(menuItem("Undo")?.title ?? "-")\"")
        check(perform("Undo"), "menu Edit > Undo")
        check(s.tracks.first?.clips.count == 1 && s.tracks.first?.clips.first?.length == first.length, "undo restored the clip")
        check(perform("Redo"), "menu Edit > Redo")
        check(s.tracks.first?.clips.count == 2, "redo re-split")
        _ = perform("Undo")

        check(!MainWindowController.isTyping, "no text field holds the keyboard at launch (Space, R and Delete work)")
        // Drag the clip body right: moves (snapped), one undo step.
        dragClip(first.id, zone: "body", fraction: 0.5)
        let moved = s.clip(first.id)!
        check(moved.start > 0, "drag moved clip to \(moved.start)")
        let q = Int64(w.timeline.snapQuantum())
        let quantum = w.timeline.snapQuantum()
        check(q > 0 && abs(Double(moved.start) - (Double(moved.start) / quantum).rounded() * quantum) <= 1,
              "move snapped to grid (\(q) frames, \(TimelineView.barsAndBeats ? "bars and beats" : "time"))")
        do { // a click on empty lane space places the playhead on the grid
            let x = w.timeline.xPos(forFrame: quantum * 7.4)
            let at = w.timeline.convert(CGPoint(x: x, y: w.timeline.bounds.maxY - 4), to: nil)
            w.timeline.mouseDown(with: mouse(.leftMouseDown, at)); w.timeline.mouseUp(with: mouse(.leftMouseUp, at))
            await wait(0.15) // the audio thread applies seeks
            check(abs(Double(s.engine.position) - quantum * 7) < 1.5, "clicking empty space snaps the playhead (\(s.engine.position))")
        }
        check(e.undoName == "Move Clip", "drag is one undo step (\(e.undoName))")
        _ = perform("Undo")
        check(s.clip(first.id)?.start == 0, "undo returns clip to 0")

        if let other = s.tracks.dropFirst().first?.clips.first, let point = w.timeline.windowPoint(ofClip: other.id) {
            w.timeline.selectedClip = first.id
            w.timeline.mouseDown(with: mouse(.leftMouseDown, point, .shift))
            w.timeline.mouseUp(with: mouse(.leftMouseUp, point, .shift))
            check(w.timeline.selectedClips == [first.id, other.id], "shift-click selects clips on multiple tracks")
            w.timeline.mouseDown(with: mouse(.leftMouseDown, point, .shift))
            w.timeline.mouseUp(with: mouse(.leftMouseUp, point, .shift))
            check(w.timeline.selectedClips == [first.id] && w.timeline.selectedClip == first.id && w.headers.selectedTrack == first.track,
                  "shift-click deselects the primary clip and restores the remaining track")
            w.timeline.mouseDown(with: mouse(.leftMouseDown, point, .shift))
            w.timeline.mouseUp(with: mouse(.leftMouseUp, point, .shift))
            let step = max(1, Int64(w.timeline.snapQuantum().rounded()))
            let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: w.window!.windowNumber, context: nil,
                                         characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                                         charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!), isARepeat: false, keyCode: 124)!
            check((NSApp.mainMenu?.performKeyEquivalent(with: right) ?? false) && s.clip(first.id)?.start == first.start + step && s.clip(other.id)?.start == other.start + step,
                  "nudge moves selected clips together")
            check(e.undoName == "Nudge Clips" && perform("Undo") && s.clip(first.id)?.start == first.start && s.clip(other.id)?.start == other.start,
                  "one undo restores both nudged clips")
            dragClip(first.id, zone: "body", fraction: 0.5)
            let shift1 = (s.clip(first.id)?.start ?? first.start) - first.start
            let shift2 = (s.clip(other.id)?.start ?? other.start) - other.start
            check(shift1 > 0 && shift1 == shift2, "drag moves selected clips together")
            _ = perform("Undo")
            check(perform("Delete") && s.clip(first.id) == nil && s.clip(other.id) == nil, "Delete removes selected clips together")
            check(perform("Undo") && s.clip(first.id) != nil && s.clip(other.id) != nil, "one undo restores deleted clips")
            w.timeline.selectedClip = nil
            let from = w.timeline.convert(CGPoint(x: w.timeline.bounds.maxX - 5, y: w.timeline.laneY(2) + 5), to: nil)
            let to = w.timeline.convert(CGPoint(x: 1, y: w.timeline.laneY(0) + 5), to: nil)
            w.timeline.mouseDown(with: mouse(.leftMouseDown, from))
            for k in 1...8 {
                w.timeline.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * CGFloat(k) / 8,
                                                                              y: from.y + (to.y - from.y) * CGFloat(k) / 8)))
            }
            w.timeline.mouseUp(with: mouse(.leftMouseUp, to))
            check(w.timeline.selectedClips == [first.id, other.id], "marquee selects clips across tracks")
            w.timeline.selectedClip = first.id
        } else { check(false, "two clips available for multi-selection") }

        // Trim the right edge left.
        dragClip(first.id, zone: "right", fraction: -0.3)
        let trimmed = s.clip(first.id)!
        check(trimmed.length < first.length && trimmed.offset == 0, "right-edge trim shortened clip to \(trimmed.length)")
        check(e.undoName == "Trim Clip", "trim is one undo step")

        // Trim the left edge right (keeps the right edge fixed).
        dragClip(first.id, zone: "left", fraction: 0.3)
        let lt = s.clip(first.id)!
        check(lt.start > trimmed.start && lt.offset == lt.start - trimmed.start && lt.end == trimmed.end,
              "left-edge trim: start=\(lt.start) offset=\(lt.offset), right edge fixed")

        // Delete via menu, then undo.
        w.timeline.selectedClip = first.id
        check(perform("Delete"), "menu Edit > Delete")
        check(s.clip(first.id) == nil, "clip deleted")
        _ = perform("Undo")
        check(s.clip(first.id) != nil, "undo restored deleted clip")

        // Command palette: open via its menu item, fuzzy-find, execute.
        check(perform("Command Palette"), "menu View > Command Palette…")
        check(w.palette.isVisible, "palette is visible")
        w.palette.filter("splt plhd")
        check(w.palette.results.first?.title == "Split at Playhead", "fuzzy 'splt plhd' → \(w.palette.results.first?.title ?? "-")")
        check(w.palette.results.first?.shortcut == "⌘T", "palette shows shortcut \(w.palette.results.first?.shortcut ?? "-")")
        w.palette.filter("tempo")
        check(w.palette.results.first?.title.localizedCaseInsensitiveContains("tempo") == true &&
              !w.palette.results.contains { $0.title.contains("Speakers") },
              "'tempo' leads with tempo commands, without scattered-letter matches (\(w.palette.results.prefix(3).map(\.title)))")
        w.palette.filter("splt plhd")
        w.timeline.selectedClip = first.id
        e.seek(s.clip(first.id)!.start + s.clip(first.id)!.length / 2)
        await wait(0.3)
        let before = s.tracks.first?.clips.count ?? 0
        w.palette.runSelected()
        check(!w.palette.isVisible, "palette closes after running")
        check(s.tracks.first?.clips.count == before + 1, "palette ran Split at Playhead")
        _ = perform("Undo")
        let entries = PaletteIndex.entries()
        check(entries.count >= 20, "palette indexes \(entries.count) commands")
        check(entries.filter { $0.path.hasSuffix("Output Device") }.count >= 2, "palette includes output devices")

        // Meters move during playback.
        e.seek(0)
        e.play()
        await wait(0.6)
        let master = w.transport.masterMeter.levelDb
        let trackLevels = w.headers.rows.map(\.meter.levelDb.0)
        let litBeforeStop = w.headers.rows.filter { $0.gain.meterDb > -60 }.count
        check(w.headers.rows.contains { $0.gain.meterDb > -60 }, "gain halo receives live track level")
        e.pause()
        check(master.0 > -60, String(format: "master meter live (%.1f dBFS)", master.0))
        check(trackLevels.contains { $0 > -60 }, "track meters live (\(trackLevels.map { Int($0) }) dBFS)")
        await wait(RotaryKnob.meterReleaseSeconds + 0.2)
        let after = w.headers.rows.map(\.gain.meterDb)
        check(litBeforeStop > 0 && after.allSatisfy { $0 <= -60 },
              "gain rings go dark after stop (\(litBeforeStop) lit during playback; \(after.map { Int($0) }) dB after release)")
        do { // Exact timing: a loud and a quiet ring are each halfway at half the release time, and both empty at the end.
            let loud = RotaryKnob(frame: NSRect(x: 0, y: 0, width: 30, height: 30)), quiet = RotaryKnob(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
            for (k, db) in [(loud, Float(-3)), (quiet, Float(-45))] { k.showsMeter = true; k.updateMeter(db); k.transportChanged(playing: false) }
            let t0 = loud.release?.start ?? -1, q0 = quiet.release?.start ?? -1
            check(t0 >= 0 && q0 >= 0, "ring release starts on stop")
            let half = RotaryKnob.meterReleaseSeconds / 2
            loud.updateMeter(-15, now: t0 + half); quiet.updateMeter(-57, now: q0 + half) // the meter's own 24 dB/s fall is ignored
            let mid = (loud.meterDb, quiet.meterDb)
            let midScale = loud.faceScale, expected = RotaryKnob.revealScale + (1 - RotaryKnob.revealScale) * 0.5
            loud.updateMeter(-22, now: t0 + 2 * half + 0.0001); quiet.updateMeter(-120, now: q0 + 2 * half + 0.0001)
            if !Analog.on {
                check(abs(midScale - expected) < 0.001 && abs(loud.faceScale - 1) < 1e-9 && abs(quiet.faceScale - 1) < 1e-9,
                      String(format: "dial face grows back in step with the falling ring (half-way %.3f, expected %.3f; end %.3f)", midScale, expected, loud.faceScale))
            }
            check(abs(mid.0 - -31.5) < 0.01 && abs(mid.1 - -52.5) < 0.01 && loud.meterDb <= -60 && quiet.meterDb <= -60,
                  String(format: "rings fall at their own rates and empty together (half-way %.2f / %.2f dB, end %.0f / %.0f)", mid.0, mid.1, loud.meterDb, quiet.meterDb))
        }

        // Output device menu: pick a specific device, then back to System Default.
        if let sub = menuItem("Output Device", submenuOnly: true)?.submenu {
            w.menuNeedsUpdate(sub)
            let concrete = sub.items.filter { ($0.representedObject as? String)?.isEmpty == false }
            check(!concrete.isEmpty, "device menu lists \(concrete.count) device(s)")
            if let d = concrete.first {
                sub.performActionForItem(at: sub.index(of: d))
                check(e.outputDeviceUid == d.representedObject as? String, "selected \(d.title)")
                check(e.deviceAlive, "device alive after switch")
                w.menuNeedsUpdate(sub)
                sub.performActionForItem(at: 0)
                check(e.outputDeviceUid.isEmpty, "back to System Default")
            }
        } else {
            check(false, "Audio > Output Device menu exists")
        }

        // Fades: drag the fade-in handle, switch curve, remove.
        w.timeline.selectedClip = first.id
        dragClip(first.id, zone: "fadeIn", fraction: 0.2)
        let faded = s.clip(first.id)!
        check(faded.fadeIn > 0 && e.undoName == "Fade", "fade-in handle drag: \(faded.fadeIn) frames, one undo step")
        check(perform("Equal Power"), "menu Clip > Fade Curve > Equal Power")
        check(s.clip(first.id)?.fadeCurve == 1, "curve is equal power")
        check(perform("Remove Fades"), "menu Clip > Remove Fades")
        check(s.clip(first.id)?.fadeIn == 0, "fades removed")
        check(perform("Add Short Fades"), "menu Clip > Add Short Fades")
        check(s.clip(first.id)?.fadeIn == Int64(e.sampleRate * 0.01), "10 ms fades added")

        // Time stretch: ⌥-drag the right edge keeps the source audio and changes its speed.
        _ = perform("Remove Fades")
        let pre = s.clip(first.id)!
        dragClip(first.id, zone: "right", fraction: 0.6, mods: .option)
        let st = s.clip(first.id)!
        check(st.length > pre.length && abs(Double(st.sourceSpan) - Double(pre.sourceSpan)) <= 2 && st.rate < 1,
              String(format: "⌥-drag stretched clip: length %lld→%lld, rate %.3f", pre.length, st.length, st.rate))
        check(e.undoName == "Time Stretch", "stretch drag is one undo step")
        var waited = 0
        while (s.clip(first.id)?.processing ?? false) && waited < 300 { _ = s.pollJobs(); await wait(0.02); waited += 1 }
        check(s.clip(first.id)?.processing == false, "stretched audio rendered in background (\(waited * 20) ms)")
        check(perform("Double Speed"), "menu Clip > Double Speed")
        check(abs((s.clip(first.id)?.rate ?? 0) - st.rate * 2) < 1e-6, "rate doubled")
        check(perform("Transpose Up a Semitone") && s.clip(first.id)?.pitch == 1, "transpose up")
        check(perform("Reset Speed and Pitch"), "menu Clip > Reset Speed and Pitch")
        check(s.clip(first.id)?.rate == 1 && s.clip(first.id)?.pitch == 0 && s.clip(first.id)?.length == pre.sourceSpan, "back to original")

        // Mixer controls: gain and pan drags, reset, and undo.
        if let row = w.headers.rows.first {
            let f = row.gain
            func at(_ v: NSView, _ x: CGFloat, _ y: CGFloat) -> CGPoint { v.convert(CGPoint(x: x, y: y), to: nil) }
            let center = at(f, f.bounds.midX, f.bounds.midY)
            f.mouseDown(with: mouse(.leftMouseDown, center))
            f.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: center.x, y: center.y - 40)))
            f.mouseUp(with: mouse(.leftMouseUp, center))
            let g = s.track(row.trackId)!.gainDb
            check(g < -2 && e.undoName == "Volume", String(format: "gain knob drag lowered volume to %.1f dB (one undo step)", g))
            f.mouseDown(with: mouse(.leftMouseDown, center, .option))
            check(s.track(row.trackId)!.gainDb == 0, "⌥-click resets gain to 0 dB")
            let k = row.pan
            k.mouseDown(with: mouse(.leftMouseDown, at(k, k.bounds.midX, k.bounds.midY)))
            k.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: at(k, k.bounds.midX, 0).x, y: at(k, k.bounds.midX, k.bounds.midY).y + 30)))
            k.mouseUp(with: mouse(.leftMouseUp, at(k, k.bounds.midX, k.bounds.midY)))
            check((s.track(row.trackId)?.pan ?? 0) > 0.2, "pan knob drag up pans right (\(s.track(row.trackId)?.pan ?? 0))")
            _ = perform("Undo"); _ = perform("Undo"); _ = perform("Undo")
            check(s.track(row.trackId)!.gainDb == 0 && s.track(row.trackId)!.pan == 0, "undo restores gain and pan")
            let steps = s.tracks.map { OKLCH.fromSRGB($0.color).2 }
            check(steps.count < 2 || zip(steps, steps.dropFirst()).allSatisfy { a, b in (b - a + 360).truncatingRemainder(dividingBy: 360) > 15 },
                  "automatic colors advance around the hue wheel from green (\(steps.map { Int($0) }))")
            w.headers.select(row.trackId)
            check(perform("Rose"), "Track ▸ Track Color ▸ Rose")
            check(s.track(row.trackId)!.customColor >= 0, "custom color pinned")
            check(perform("Automatic (Gradient)") && s.track(row.trackId)!.customColor == -1, "back to automatic")
        }

        // Tracks: select, solo, reorder (menu and drag), new, delete, rename.
        guard let t0 = s.tracks.first?.id else { check(false, "a track exists for track commands"); return finish() }
        w.headers.select(t0)
        check(perform("Solo Track"), "menu Track > Solo Track")
        check(s.track(t0)?.solo == true, "track soloed")
        _ = perform("Solo Track")
        check(s.track(t0)?.solo == false, "track unsoloed")
        check(perform("Move Track Down"), "menu Track > Move Track Down")
        check(s.tracks.dropFirst().first?.id == t0, "track moved down")
        _ = perform("Undo")
        if let row = w.headers.row(t0), s.tracks.count >= 2 {
            let target = w.headers.convert(CGPoint(x: 20, y: Theme.rulerHeight + Theme.trackHeight * 2), to: nil)
            w.headers.dragUpdate(row: row, windowPoint: target)
            w.headers.dragEnd(row: row)
            check(s.tracks.dropFirst().first?.id == t0, "drag header reorders (now index \(s.tracks.firstIndex { $0.id == t0 } ?? -1))")
            _ = perform("Undo")
        }
        let count = s.tracks.count
        check(perform("New Track"), "menu Track > New Track")
        check(s.tracks.count == count + 1, "track added")
        check(perform("Delete Track"), "menu Track > Delete Track")
        check(s.tracks.count == count, "track deleted")
        w.headers.select(t0)
        check(perform("Rename Track"), "menu Track > Rename Track")
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: w.window!.windowNumber, context: nil, characters: " ",
                                     charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        let typing = MainWindowController.isTyping
        let consumed = NSApp.mainMenu?.performKeyEquivalent(with: space) ?? true
        let rightArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: w.window!.windowNumber, context: nil,
                                          characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                                          charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!), isARepeat: false, keyCode: 124)!
        check(typing && !consumed && !e.isPlaying,
              "Space types into the rename field instead of starting playback (typing=\(typing), menu consumed=\(consumed))")
        check(!(NSApp.mainMenu?.performKeyEquivalent(with: rightArrow) ?? true), "arrow keys stay in the rename field")
        if let row = w.headers.row(t0), let editor = row.nameLabel.currentEditor() as? NSTextView {
            let before = s.track(t0)?.name
            editor.insertText("Discarded", replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            check(!MainWindowController.isTyping && s.track(t0)?.name == before && row.nameLabel.stringValue == before,
                  "Escape cancels the rename and keeps the old name")
            check(perform("Rename Track"), "rename again after cancelling")
        }
        w.headers.row(t0)?.nameLabel.stringValue = "Lead Vox"
        w.window?.makeFirstResponder(nil)
        check(!MainWindowController.isTyping && NSApp.mainMenu?.performKeyEquivalent(with: space) == true && e.isPlaying,
              "Space starts playback when not typing")
        check(NSApp.mainMenu?.performKeyEquivalent(with: space) == true && !e.isPlaying,
              "Space pauses playback")
        if let gain = w.headers.row(t0)?.gain {
            w.window?.makeFirstResponder(gain)
            check(NSApp.mainMenu?.performKeyEquivalent(with: space) == true && e.isPlaying,
                  "Space starts playback with gain knob focused")
            check(NSApp.mainMenu?.performKeyEquivalent(with: space) == true && !e.isPlaying,
                  "Space pauses playback with gain knob focused")
            NSApp.sendEvent(space) // the real event path, not just the menu
            let viaEvent = e.isPlaying
            NSApp.sendEvent(space)
            check(viaEvent && !e.isPlaying, "real Space key toggles playback with gain knob focused (started=\(viaEvent), stopped=\(!e.isPlaying))")
            // Clicking a dial must not take the keyboard: Space still reaches the transport afterwards.
            w.window?.makeFirstResponder(w.timeline)
            let c = gain.convert(CGPoint(x: gain.bounds.midX, y: gain.bounds.midY), to: nil)
            let before = gain.value
            gain.mouseDown(with: mouse(.leftMouseDown, c)); gain.mouseUp(with: mouse(.leftMouseUp, c))
            check(w.window?.firstResponder !== gain && gain.value == before, "clicking a gain dial doesn't take keyboard focus")
            NSApp.sendEvent(space); let started = e.isPlaying; NSApp.sendEvent(space)
            check(started && !e.isPlaying, "real Space key works after clicking a dial")
            check(abs(GainKnob.position(for: 0) - 0.5) < 1e-9 && GainKnob.db(for: 0.5) == 0 && GainKnob.db(for: 1) == FaderControl.maxDb
                  && abs(GainKnob.db(for: GainKnob.position(for: -12)) - -12) < 1e-3 && GainKnob.db(for: 0) == -.infinity,
                  "gain dial: 0 dB at the top center, +\(FaderControl.maxDb) dB at full, −∞ at zero, round-trips")
        }
        check(s.track(t0)?.name == "Lead Vox", "renamed track (\(s.track(t0)?.name ?? "-"))")

        // Save, New (via menu), reopen.
        let project = workdir.appendingPathComponent("selftest.dalnok")
        check(w.saveProject(to: project), "save project")
        check(!e.isDirty && w.window?.isDocumentEdited == false, "saved state is clean")
        check(perform("New"), "menu File > New")
        check(s.tracks.isEmpty, "new project is empty")
        check(!w.emptyState.isHidden && w.timeline.isHidden, "empty state shown for an empty project")
        if let b = w.emptyState.subviewsDeep.compactMap({ $0 as? NSButton }).first(where: { $0.title == "New Instrument Track" }) {
            b.performClick(nil)
            check(s.tracks.count == 1 && s.tracks.first?.isInstrument == true, "empty state's New Instrument Track adds one")
            _ = perform("Undo")
        } else { check(false, "empty state offers New Instrument Track") }
        let opened = await withCheckedContinuation { cont in w.openProject(project) { cont.resume(returning: $0) } }
        check(opened, "background open completed")
        check(s.tracks.count == files.count, "reopened \(s.tracks.count) tracks")
        check(s.clip(first.id)?.start == lt.start && s.clip(first.id)?.length == lt.length, "edits survived save/open")
        check(w.window?.title == "selftest", "window title is project name (\(w.window?.title ?? "-"))")
        let audioDir = workdir.appendingPathComponent("Audio Files")
        let copied = (try? FileManager.default.contentsOfDirectory(atPath: audioDir.path)) ?? []
        check(copied.count == files.count, "save copied \(copied.count) audio files into Audio Files/")

        // Relink: move the audio folder away, reopen, relink by searching the folder.
        let movedAudio = workdir.appendingPathComponent("Moved Audio")
        try? FileManager.default.moveItem(at: audioDir, to: movedAudio)
        _ = await withCheckedContinuation { cont in w.openProject(project) { cont.resume(returning: $0) } }
        check(s.offlineMedia.count == files.count, "\(s.offlineMedia.count) clips offline after moving audio")
        check(menuItem("Relink Missing Audio")?.isEnabled == true, "File > Relink Missing Audio… enabled")
        let (relinked, still) = await w.relink(searching: [movedAudio])
        check(relinked == files.count && still == 0, "relinked \(relinked), \(still) still missing")
        check(s.tracks.flatMap(\.clips).allSatisfy { !$0.offline }, "all clips back online")

        // Export.
        let wav = workdir.appendingPathComponent("selftest.wav")
        check(w.exportMix(to: wav), "export mix")
        var media: OpaquePointer?
        let loaded = dalnok_media_load(wav.path, e.sampleRate, &media, nil, 0) == DALNOK_OK
        check(loaded && dalnok_media_frames(media) == s.length && dalnok_media_channels(media) == 2,
              "exported WAV decodes to \(dalnok_media_frames(media)) frames (session \(s.length)), stereo")
        if let media { dalnok_media_release(media) }
        // DAWproject: the File menu offers it; the export imports back with the same clips.
        if let item = menuItem("Export as DAWproject…") { item.menu?.update(); check(item.isEnabled, "File > Export as DAWproject… is enabled") }
        else { check(false, "File > Export as DAWproject… exists") }
        let dawp = workdir.appendingPathComponent("selftest.dawproject")
        check(w.exportDawproject(to: dawp), "export DAWproject (\(w.lastFlashText))")
        var report = [CChar](repeating: 0, count: 8192), derr = [CChar](repeating: 0, count: 512)
        let ok = dalnok_project_import_report(dawp.path, &report, report.count, &derr, derr.count) == DALNOK_OK
        let clipsBack = (try? JSONSerialization.jsonObject(with: Data(String(cString: report).utf8)) as? [String: Any])
            .flatMap { ($0["imported"] as? [String: Any])?["clips"] as? Int } ?? -1
        let arrangementClips = s.tracks.flatMap(\.clips).filter { !$0.isMidi && !$0.offline }.count
        check(ok && clipsBack == arrangementClips, "the DAWproject imports back with its \(arrangementClips) audio clips (\(clipsBack), \(String(cString: derr)))")

        // Exercise recovery snapshots without writing into the user's recovery folder.
        if let track = s.tracks.first {
            s.renameTrack(track.id, "Before Recovery")
            let recoveryDir = workdir.appendingPathComponent("Recovery", isDirectory: true)
            let recovery = try? w.writeRecoverySnapshot(in: recoveryDir)
            check(recovery != nil && e.isDirty, "recovery snapshot preserves unsaved state")
            check((try? w.writeRecoverySnapshot(in: recoveryDir)) == nil, "unchanged revision does not create another snapshot")
            s.renameTrack(track.id, "After Recovery")
            if let recovery {
                Task { await wait(0.2); if let sheet = w.window?.attachedSheet { w.window?.endSheet(sheet, returnCode: .cancel) } }
                check(perform("Recover Snapshot"), "File > Recover Snapshot opens a panel")
                await wait(0.3)
                let recovered = await withCheckedContinuation { cont in w.openRecovery(recovery) { cont.resume(returning: $0) } }
                check(recovered && s.tracks.first?.name == "Before Recovery", "recovery restores the saved model")
                check(e.isDirty && s.projectURL == nil, "recovered snapshot is an unsaved project")
                check(FileManager.default.fileExists(atPath: recovery.path), "recovery keeps the original snapshot")
            }
            // Launch-time crash detection, in the test's own recovery folder.
            setenv("DALNOK_RECOVERY_DIR", recoveryDir.path, 1)
            defer { unsetenv("DALNOK_RECOVERY_DIR") }
            let marker = recoveryDir.appendingPathComponent("running.json")
            func writeMarker(pid: Int32, started: Double) {
                try? JSONSerialization.data(withJSONObject: ["pid": Int(pid), "started": started]).write(to: marker)
            }
            writeMarker(pid: 999_999, started: Date().timeIntervalSince1970 - 3_600) // a session that is gone
            check(w.unfinishedSessionSnapshot()?.resolvingSymlinksInPath() == recovery?.resolvingSymlinksInPath(),
                  "a session that ended unexpectedly offers its newest snapshot")
            writeMarker(pid: 1, started: Date().timeIntervalSince1970 - 3_600) // still running (another instance)
            check(w.unfinishedSessionSnapshot() == nil, "no offer while that session is still running")
            writeMarker(pid: 999_999, started: Date().timeIntervalSince1970 + 60) // nothing saved since it started
            check(w.unfinishedSessionSnapshot() == nil, "no offer when that session saved no snapshot")
            w.beginSessionMarker()
            w.endSessionMarker()
            check(!FileManager.default.fileExists(atPath: marker.path) && w.unfinishedSessionSnapshot() == nil,
                  "a clean quit removes the marker, so the next launch offers nothing")
        }

        try? w.snapshot(to: workdir.appendingPathComponent("selftest.png"))
        await migrationSteps()
        // Settings: exercise the menu, appearance selection, and project preference.
        let oldTheme = UserDefaults.standard.object(forKey: "appearanceStyle")
        let oldCopy = MainWindowController.copyAudioOnSave
        check(perform("Settings…"), "Dalnok > Settings opens")
        check(w.settings.window?.isVisible == true, "settings window is visible")
        if let view = w.settings.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: workdir.appendingPathComponent("settings.png"))
        }
        // Live theme switching: the window rebuilds in the other style around the same project and undo history.
        let startStyle = Theme.activeStyle, firstWindow = w.window
        let tracksBefore = s.tracks.map(\.id), undoBefore = e.undoName
        let other = startStyle == .graphite ? 1 : 0
        w.settings.themePicker.selectItem(at: other)
        _ = NSApp.sendAction(#selector(SettingsController.themeChanged(_:)), to: w.settings, from: w.settings.themePicker)
        await wait(0.2)
        check(Theme.preferredStyle == Theme.Style.allCases[other] && Theme.activeStyle == Theme.Style.allCases[other],
              "settings switches the theme live (\(Theme.activeStyle.title))")
        check(w.window !== firstWindow && w.window?.isVisible == true && firstWindow?.isVisible != true, "the main window is rebuilt and the old one closed")
        check(s.tracks.map(\.id) == tracksBefore && e.undoName == undoBefore, "the project and undo history carry over")
        check((w.transport.reels.superview != nil) == Analog.on, "the rebuilt window uses the new style's parts (tape reels \(Analog.on ? "shown" : "hidden"))")
        check(w.settings.window?.isVisible == true && w.settings.relaunch.isHidden, "settings stays open, with no relaunch needed")
        try? w.snapshot(to: workdir.appendingPathComponent("theme-switched.png"))
        w.settings.themePicker.selectItem(at: other == 1 ? 0 : 1)
        _ = NSApp.sendAction(#selector(SettingsController.themeChanged(_:)), to: w.settings, from: w.settings.themePicker)
        await wait(0.2)
        check(Theme.activeStyle == startStyle, "switching back restores \(startStyle.title)")
        w.settings.copyAudio.state = .off
        _ = NSApp.sendAction(#selector(SettingsController.copyChanged(_:)), to: w.settings, from: w.settings.copyAudio)
        check(!MainWindowController.copyAudioOnSave, "settings updates copy-audio preference")
        if let oldTheme { UserDefaults.standard.set(oldTheme, forKey: "appearanceStyle") }
        else { UserDefaults.standard.removeObject(forKey: "appearanceStyle") }
        MainWindowController.copyAudioOnSave = oldCopy
        w.settings.window?.orderOut(nil)
        finish()
    }

    // MARK: Migration & onboarding

    private func migrationSteps() async {
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
        check(w.palette.results.first?.title == "Export Mix…", "palette: 'bounce' → \(w.palette.results.first?.title ?? "-")")
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
        await motion()
        pluginManager()
        hostedPlugins()
        devicePanel()

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
        w.welcome.choose(.ableton)
        check(SourceDAW.preferred == .ableton && menuItem("Split at Playhead")?.keyEquivalent == "e", "welcome: Ableton chosen, preset applied")
        await w.welcome.rescan()
        check(true, "project finder scanned (\(w.welcome.projects.count) projects found)")
        w.welcome.window.orderOut(nil)
    }

    /// Recording through the real menus on the simulated input, record arm, input labels,
    /// a failed take, journal recovery, instrument tracks, MIDI clips, quantize, live MIDI and MIDI recording.
    private func recordingAndMidi() async {
        let e = s.engine
        e.pause()
        check(w.saveProject(to: workdir.appendingPathComponent("recording.dalnok")), "save so takes go to the project's Audio Files")
        let audioFiles = workdir.appendingPathComponent("Audio Files")
        dalnok_engine_stop_device(e.handle) // the simulated input replaces the device during the take
        MainWindowController.simulatedInput = true
        defer { MainWindowController.simulatedInput = false }
        guard let track = s.tracks.first?.id else { return check(false, "an audio track exists for recording") }
        w.headers.select(track)
        check(perform("Record Enable Track") && s.track(track)?.armed == true, "menu Track > Record Enable Track arms the track")
        check(w.headers.row(track)?.inputButton.title == "IN 1", "header shows the track input (IN 1)")
        e.seek(0)
        let clipsBefore = s.track(track)?.clips.count ?? 0
        check(perform("Record", exact: true) && e.isRecording, "menu Transport > Record starts recording")
        check(menuItem("Stop Recording") != nil, "record menu item becomes Stop Recording")
        var l = [Float](repeating: 0, count: 512), r = l
        let input = [Float](repeating: 0.25, count: 512)
        for _ in 0..<20 { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        w.updateRecording()
        check(w.timeline.recording?.tracks.contains(track) == true, "timeline shows the take in progress")
        check(perform("Stop Recording", exact: true) && !e.isRecording, "menu Transport > Stop Recording")
        let take = s.track(track)?.clips.last
        check(s.track(track)?.clips.count == clipsBefore + 1 && (take?.length ?? 0) >= 19 * 512,
              "take placed on the armed track (\(take?.length ?? 0) frames)")
        check(FileManager.default.fileExists(atPath: audioFiles.appendingPathComponent("\(s.track(track)?.name ?? "") Take 1.wav").path),
              "take saved in the project's Audio Files")
        check(e.undoName == "Record", "recording is one undo step")
        check(perform("Undo") && s.track(track)?.clips.count == clipsBefore, "undo removes the take")
        check(perform("Redo") && s.track(track)?.clips.count == clipsBefore + 1, "redo restores the take")

        // Count-in: the transport starts a bar early with clicks; the take starts where Record was pressed.
        let bar2 = Int64(s.beatToFrame(s.barToBeat(2)).rounded())
        e.seek(bar2)
        for _ in 0..<2 { dalnok_engine_pump(e.handle, &l, &r, 512) } // let the seek land (no input session yet)
        let wasCountIn = MainWindowController.countIn
        if !wasCountIn { check(perform("Count-In") && MainWindowController.countIn, "Transport > Count-In turns it on") }
        check(perform("Record", exact: true) && e.isRecording, "count-in take starts")
        let barLength = bar2 - Int64(s.beatToFrame(s.barToBeat(1)).rounded())
        for _ in 0..<(Int(barLength) / 512 + 12) { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        check(perform("Stop Recording", exact: true), "count-in take stops")
        let counted = s.track(track)?.clips.last
        let latency = dalnok_record_latency(e.handle)
        check(counted.map { abs($0.start + latency - bar2) <= 1 } == true,
              "count-in take starts at the record position (\(counted?.start ?? -1) + latency \(latency) vs \(bar2))")
        if !wasCountIn { _ = perform("Count-In") }

        // Autopunch: only the red range is kept.
        let bar3 = Int64(s.beatToFrame(s.barToBeat(3)).rounded())
        w.timeline.punchRange = (bar2 + 1_000, bar3)
        if !MainWindowController.autopunch { check(perform("Autopunch") && MainWindowController.autopunch, "Transport > Autopunch turns it on") }
        w.timeline.punchRange = (bar2 + 1_000, bar3)
        e.seek(Int64(s.beatToFrame(s.barToBeat(1)).rounded()))
        for _ in 0..<2 { dalnok_engine_pump(e.handle, &l, &r, 512) }
        check(perform("Record", exact: true) && e.isRecording, "autopunch take starts")
        for _ in 0..<(Int(bar3 - bar2) * 2 / 512 + 20) { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        check(perform("Stop Recording", exact: true), "autopunch take stops")
        let punched = s.track(track)?.clips.last
        check(punched.map { abs($0.start + latency - (bar2 + 1_000)) <= 1 && abs($0.length - (bar3 - bar2 - 1_000)) <= 1 } == true,
              "autopunch keeps exactly the punch range (\(punched?.start ?? -1), \(punched?.length ?? -1))")
        _ = perform("Autopunch")

        // Two armed audio tracks record together: one take each, one undo step.
        if let second = s.tracks.first(where: { !$0.isInstrument && $0.id != track })?.id {
            w.headers.select(second)
            if s.track(second)?.armed != true { _ = perform("Record Enable Track") }
            check(s.track(track)?.armed == true && s.track(second)?.armed == true, "two audio tracks can be armed together")
            let before = (s.track(track)?.clips.count ?? 0, s.track(second)?.clips.count ?? 0)
            e.seek(Int64(s.beatToFrame(s.barToBeat(5)).rounded()))
            for _ in 0..<2 { dalnok_engine_pump(e.handle, &l, &r, 512) }
            check(perform("Record", exact: true) && e.isRecording, "multi-track take starts")
            for _ in 0..<12 { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
            check(perform("Stop Recording", exact: true), "multi-track take stops")
            check(s.track(track)?.clips.count == before.0 + 1 && s.track(second)?.clips.count == before.1 + 1,
                  "both armed tracks get a take")
            check(perform("Undo") && s.track(track)?.clips.count == before.0 && s.track(second)?.clips.count == before.1,
                  "one undo removes both takes")
            _ = perform("Redo")
            w.headers.select(second); _ = perform("Record Enable Track") // disarm
            w.headers.select(track)
        } else { check(false, "a second audio track for multi-track recording") }

        // Cycle recording: each pass becomes a take in a take folder; the comp editor swipes between them.
        do {
            let c0 = Int64(s.beatToFrame(s.barToBeat(8)).rounded()), c1 = Int64(s.beatToFrame(s.barToBeat(9)).rounded())
            _ = s.setCycle(true, c0, c1)
            e.seek(c0)
            for _ in 0..<2 { dalnok_engine_pump(e.handle, &l, &r, 512) }
            check(perform("Record", exact: true) && e.isRecording, "cycle take starts")
            let blocks = Int((c1 - c0) * 5 / 2 / 512) // two and a half passes
            for _ in 0..<blocks { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
            check(perform("Stop Recording", exact: true), "cycle take stops")
            _ = s.setCycle(false, c0, c1)
            let folders = s.takeFolders(track)
            check(folders.count == 1 && s.takes(folders.first ?? 0).count == 3, "a cycle take makes a folder of 3 takes (\(folders))")
            if let f = folders.first, let piece = s.track(track)?.clips.first(where: { $0.folder == f }) {
                let lane = s.tracks.firstIndex { $0.id == track } ?? 0
                let rect = w.timeline.clipRect(piece, laneY: w.timeline.laneY(lane))
                let at = w.timeline.convert(CGPoint(x: rect.minX + 8, y: rect.midY), to: nil)
                w.timeline.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: at, modifierFlags: [], timestamp: 0,
                                                              windowNumber: w.window!.windowNumber, context: nil, eventNumber: 0,
                                                              clickCount: 2, pressure: 1)!)
                w.timeline.mouseUp(with: mouse(.leftMouseUp, at))
                await wait(0.2)
                let ed = w.compEditor.view
                check(w.compEditor.window?.isVisible == true && ed.folder == f, "double-clicking a comp opens the take folder")
                ed.layoutSubtreeIfNeeded(); ed.fit()
                // Swipe across the first half of take 1.
                let y = ed.laneTop(0) + CompView.lane / 2
                let a = ed.convert(CGPoint(x: ed.x(Double(c0)) + 2, y: y), to: nil)
                let b = ed.convert(CGPoint(x: ed.x(Double(c0 + (c1 - c0) / 2)), y: y), to: nil)
                ed.mouseDown(with: mouse(.leftMouseDown, a))
                for k in 1...5 { ed.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / 5, y: a.y))) }
                ed.mouseUp(with: mouse(.leftMouseUp, b))
                let comp = s.comp(f)
                check(comp.first?.take == 0 && comp.first?.from == c0 && e.undoName == "Comp",
                      "swiping across take 1 puts it in the comp (\(comp.map { ($0.from, $0.to, $0.take) }))")
                try? w.compEditor.window?.contentView?.superview.map { v in
                    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!; v.cacheDisplay(in: v.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: workdir.appendingPathComponent("comp-editor.png"))
                }
                // Clicking a take's name uses all of it.
                let name = ed.convert(CGPoint(x: 20, y: ed.laneTop(1) + 10), to: nil)
                ed.mouseDown(with: mouse(.leftMouseDown, name)); ed.mouseUp(with: mouse(.leftMouseUp, name))
                check(s.comp(f).count == 1 && s.comp(f).first?.take == 1, "clicking Take 2 comps the whole take")
                check(perform("Undo") && s.comp(f).first?.take == 0, "undo restores the swiped comp")
                w.compEditor.window?.orderOut(nil)
            } else { check(false, "the comp shows in the arrangement") }
        }

        // Interrupted take: pausing ends it with an explanation; nothing is placed.
        let clipsBeforeInterrupted = s.track(track)?.clips.count ?? 0
        check(perform("Record", exact: true) && e.isRecording, "second take starts")
        for _ in 0..<5 { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        e.pause()
        for _ in 0..<3 { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        w.updateRecording()
        check(!e.isRecording && w.lastRecordingProblem == "The take was interrupted", "interrupted take is reported (\(w.lastRecordingProblem ?? "-"))")
        check(s.track(track)?.clips.count == clipsBeforeInterrupted, "interrupted take is not placed")

        // An unfinished take (as after a crash) is recovered through File > Recover Recordings.
        var spool = Data("DLNCAP01".utf8)
        withUnsafeBytes(of: UInt32(e.sampleRate).littleEndian) { spool.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(1).littleEndian) { spool.append(contentsOf: $0) }
        for _ in 0..<4_800 { withUnsafeBytes(of: Float(0.1).bitPattern.littleEndian) { spool.append(contentsOf: $0) } }
        try? spool.write(to: audioFiles.appendingPathComponent("Crash Take 1.dlncap"))
        try? #"{"format":"dalnok-take","version":1,"state":"recording","spool":"Crash Take 1.dlncap","wav":"Crash Take 1.wav"}"#
            .write(to: audioFiles.appendingPathComponent("Crash Take 1.dlntake"), atomically: true, encoding: .utf8)
        check(perform("Recover Recordings") && w.lastRecoveredTakes.map(\.lastPathComponent) == ["Crash Take 1 (recovered).wav"],
              "File > Recover Recordings recovers the unfinished take")
        do { try e.startDevice() } catch { check(false, "device restarts after recording: \(error)") }
        check(perform("Record Enable Track") && s.track(track)?.armed == false, "disarm the audio track")

        // Instrument track and MIDI clip.
        check(perform("New Instrument Track"), "menu Track > New Instrument Track")
        guard let keys = s.tracks.last, keys.isInstrument, keys.armed else { return check(false, "instrument track is armed") }
        check(w.headers.row(keys.id)?.inputButton.title == "Dalnok Poly", "instrument header names its instrument (Dalnok Poly)")
        e.seek(0)
        try? await Task.sleep(for: .milliseconds(100))
        check(perform("New MIDI Clip"), "menu Clip > New MIDI Clip")
        guard let clip = w.timeline.selectedClip, s.clip(clip)?.isMidi == true else { return check(false, "MIDI clip selected") }
        let sixteenth = s.framesPerBeat / 4
        s.setNotes(clip, [DalnokNote(start: sixteenth + 100, length: sixteenth, pitch: 60, velocity: 100),
                          DalnokNote(start: 2 * sixteenth - 90, length: sixteenth, pitch: 64, velocity: 90)])
        check(perform("1/16 Notes"), "menu Clip > Quantize > 1/16 Notes")
        check(s.clip(clip)?.notes.map(\.start) == [sixteenth, 2 * sixteenth], "notes quantized to 16ths")
        check(menuItem("Double Speed")?.isEnabled == false, "audio-only clip commands are disabled for MIDI clips")

        // Live MIDI through the running device: the armed instrument meters while stopped.
        dalnok_midi_inject(e.handle, 0x90, 69, 110)
        try? await Task.sleep(for: .milliseconds(300))
        let live = w.headers.row(keys.id)?.meter.levelDb.0 ?? -200
        dalnok_midi_inject(e.handle, 0x80, 69, 0)
        check(live > -40, String(format: "live MIDI plays the armed instrument (%.1f dBFS)", live))

        // MIDI recording through the menu (device clock).
        let before = s.track(keys.id)?.clips.count ?? 0
        e.seek(Int64(e.sampleRate) * 8)
        check(perform("Record", exact: true) && e.isRecording, "Record with only an instrument armed")
        try? await Task.sleep(for: .milliseconds(150))
        dalnok_midi_inject(e.handle, 0x90, 67, 100)
        try? await Task.sleep(for: .milliseconds(250))
        dalnok_midi_inject(e.handle, 0x80, 67, 0)
        try? await Task.sleep(for: .milliseconds(100))
        check(perform("Stop Recording", exact: true), "stop MIDI recording")
        let recorded = s.track(keys.id)?.clips.last
        _ = recorded
        await pianoRoll(clip: clip)
        await tempoAndMetronome()
        await cycle()
        await mixerAndRouting()
        await launcherSteps()
        check(s.track(keys.id)?.clips.count == before + 1 && recorded?.notes.count == 1 && recorded?.notes.first?.pitch == 67,
              "recorded one MIDI note (\(recorded?.notes.count ?? 0))")
        let ms = Double(recorded?.notes.first?.length ?? 0) / e.sampleRate * 1000
        check(ms > 150 && ms < 400, String(format: "recorded note length %.0f ms (held ~250 ms)", ms))
    }

    /// Piano roll through real menus, mouse gestures (synthesized events) and keys.
    private func pianoRoll(clip: DalnokClipId) async {
        let e = s.engine
        w.timeline.selectedClip = clip
        check(perform("Piano Roll", exact: true), "menu Clip > Piano Roll opens the editor")
        let roll = w.pianoRoll.roll
        guard let win = w.pianoRoll.window, win.isVisible, roll.clipId == clip else { return check(false, "piano roll window is visible") }
        win.makeKey()
        let pianoArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: win.windowNumber, context: nil,
                                          characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                                          charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!), isARepeat: false, keyCode: 124)!
        check(!(NSApp.mainMenu?.performKeyEquivalent(with: pianoArrow) ?? true), "arrangement nudge shortcuts do not steal piano-roll arrows")
        roll.layoutSubtreeIfNeeded()
        func ev(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, mods: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: roll.convert(p, to: nil), modifierFlags: mods,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func key(_ code: UInt16, _ chars: String, mods: NSEvent.ModifierFlags = []) {
            roll.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                                windowNumber: win.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        func drag(from a: CGPoint, to b: CGPoint, mods: NSEvent.ModifierFlags = []) {
            roll.mouseDown(with: ev(.leftMouseDown, a, mods: mods))
            for k in 1...8 { roll.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / 8, y: a.y + (b.y - a.y) * CGFloat(k) / 8), mods: mods)) }
            roll.mouseUp(with: ev(.leftMouseUp, b, mods: mods))
        }
        guard let c = s.clip(clip) else { return }
        let before = c.notes.count
        let beat = s.framesPerBeat
        // Double-click empty grid at bar 1 beat 3 of the clip, pitch D5 (74): adds a snapped note.
        let target = Double(c.start + 2 * beat) + Double(roll.snapFrames) * 0.2
        let p = CGPoint(x: roll.x(target), y: roll.y(74) + roll.rowHeight / 2)
        roll.mouseDown(with: ev(.leftMouseDown, p, clicks: 2))
        roll.mouseUp(with: ev(.leftMouseUp, p, clicks: 2))
        let added = s.clip(clip)?.notes.first { $0.pitch == 74 }
        check(s.clip(clip)?.notes.count == before + 1 && added?.start == c.offset + 2 * beat, "double-click adds a snapped note (\(added?.start ?? -1))")
        check(e.undoName == "Edit Notes", "adding a note is one undo step")
        guard let n = added, let cur = s.clip(clip) else { return }
        // Drag the note up two rows and right one beat: one undo step "Move Notes".
        let r = roll.rect(n, cur)
        drag(from: CGPoint(x: r.minX + 3, y: r.midY), to: CGPoint(x: r.minX + 3 + CGFloat(Double(beat) / roll.framesPerPoint), y: r.midY - 2 * roll.rowHeight))
        let moved = s.clip(clip)?.notes.first { $0.pitch == 76 && $0.start == n.start + beat }
        check(moved != nil && e.undoName == "Move Notes", "dragging a note moves it in time and pitch as one undo step")
        // Resize from its right edge.
        if let m = moved, let cur = s.clip(clip) {
            let r2 = roll.rect(m, cur)
            drag(from: CGPoint(x: r2.maxX - 2, y: r2.midY), to: CGPoint(x: r2.maxX - 2 + CGFloat(Double(beat) / roll.framesPerPoint), y: r2.midY))
            let resized = s.clip(clip)?.notes.first { $0.pitch == 76 && $0.start == m.start }
            check((resized?.length ?? 0) == m.length + beat && e.undoName == "Resize Notes", "dragging the right edge lengthens the note by a beat")
            // Velocity stem: drag up.
            if let rn = resized, let cur2 = s.clip(clip) {
                let sx = roll.x(roll.timeline(rn, cur2)) + 1
                let lane = roll.velocityLane
                let h = (lane.height - 12) * CGFloat(rn.velocity) / 127
                drag(from: CGPoint(x: sx, y: lane.maxY - 4 - h / 2), to: CGPoint(x: sx, y: lane.maxY - 4 - h / 2 - 20))
                let v = s.clip(clip)?.notes.first { $0.pitch == 76 && $0.start == rn.start }?.velocity ?? 0
                check(v > rn.velocity && e.undoName == "Note Velocity", "velocity lane drag raises velocity (\(rn.velocity) → \(v))")
            }
        }
        // Keys: transpose down an octave, nudge right, then delete through Edit > Delete.
        key(125, "", mods: .shift)
        check(s.clip(clip)?.notes.contains { $0.pitch == 64 && $0.start == n.start + beat } == true, "⇧↓ transposes the selection down an octave")
        key(124, "")
        check(s.clip(clip)?.notes.contains { $0.pitch == 64 && $0.start == n.start + beat + Int64(roll.snapFrames) } == true, "→ nudges by the grid")
        let count = s.clip(clip)?.notes.count ?? 0
        check(perform("Delete") && s.clip(clip)?.notes.count == count - 1, "Edit > Delete removes the selected note, not the clip")
        check(s.clip(clip) != nil, "the clip itself is untouched")
        _ = perform("Undo")
        check(s.clip(clip)?.notes.count == count, "undo restores the note")
        key(0, "a", mods: .command)
        check(roll.selection.count == s.clip(clip)?.notes.count, "⌘A selects all notes")
        if let cur = s.clip(clip), let targetNote = cur.notes.first(where: { $0.pitch == 64 && $0.start > c.offset + 2 * beat }) {
            let box = roll.rect(targetNote, cur)
            drag(from: CGPoint(x: box.minX - 3, y: box.minY - 2), to: CGPoint(x: box.maxX + 3, y: box.maxY + 2))
            check(roll.selection == [roll.key(targetNote)], "marquee selects intersecting notes")
            if let other = cur.notes.first(where: { $0.pitch == 60 }) {
                let box2 = roll.rect(other, cur)
                drag(from: CGPoint(x: box2.minX - 3, y: box2.minY - 2), to: CGPoint(x: box2.maxX + 3, y: box2.maxY + 2), mods: .shift)
                check(roll.selection.contains(roll.key(targetNote)) && roll.selection.contains(roll.key(other)), "shift-marquee adds to selection")
            } else { check(false, "shift-marquee fixture exists") }
        } else { check(false, "marquee fixture exists") }
        roll.entryFrame = Double(c.start)
        roll.entryPitch = 70
        key(124, "", mods: .option)
        key(126, "", mods: .option)
        let entry = Int64(roll.snapFrames)
        key(36, "\r")
        check(s.clip(clip)?.notes.contains { $0.pitch == 71 && $0.start == c.offset + entry && $0.length == entry } == true,
              "option arrows and Return enter a note at the cursor")
        check(roll.entryFrame == Double(c.start + 2 * entry), "step entry advances by the grid")
        _ = perform("Undo")
        check(s.clip(clip)?.notes.contains { $0.pitch == 71 && $0.start == c.offset + entry } == false, "undo removes the entered note")
        let originalNotes = s.clip(clip)?.notes ?? []
        let boundaryNotes = [DalnokNote(start: 0, length: entry, pitch: 126, velocity: 100),
                             DalnokNote(start: entry, length: entry, pitch: 127, velocity: 100)]
        s.setNotes(clip, boundaryNotes)
        key(0, "a", mods: .command)
        key(126, "")
        key(123, "")
        check(s.clip(clip)?.notes.map(\.pitch) == [126, 127] && s.clip(clip)?.notes.map(\.start) == [0, entry],
              "keyboard movement preserves group spacing at MIDI boundaries")
        if let current = s.clip(clip), let first = current.notes.first {
            roll.scrollY = 0
            let r = roll.rect(first, current)
            drag(from: CGPoint(x: r.minX + 2, y: r.midY), to: CGPoint(x: r.minX - 30, y: r.midY - roll.rowHeight * 4))
            check(s.clip(clip)?.notes.map(\.pitch) == [126, 127] && s.clip(clip)?.notes.map(\.start) == [0, entry],
                  "drag preserves group spacing at MIDI boundaries")
        }
        s.setNotes(clip, originalNotes)
        win.close()
        check(!w.pianoRollIsKey, "closing the piano roll returns Delete to the arrangement")
        w.window?.makeKey()
    }

    /// Audio > Plug-ins lists what is installed from metadata (no plug-in code is loaded by the self-test).
    private func pluginManager() {
        check(perform("Plug-ins"), "menu Audio > Plug-ins… opens the plug-in list")
        let pm = w.pluginManager
        check(pm.all.count > 0 && pm.all.contains { $0.format == "AU" && $0.vendor == "Apple" }, "plug-in list shows \(pm.all.count) plug-ins including Apple's Audio Units")
        pm.filter("apple")
        check(!pm.rows.isEmpty && pm.rows.allSatisfy { "\($0.name) \($0.vendor)".lowercased().contains("apple") }, "search narrows the list (\(pm.rows.count))")
        check(pm.summary.stringValue.contains("VST3 and Audio Unit plug-ins can be added"), "the list says which formats can be added")
        pm.filter("")
        pm.window?.orderOut(nil)
    }

    /// With DALNOK_TEST_VST3 (the test plug-in from scripts/ci/plugin-host.sh): add, show and remove hosted plug-ins.
    private func hostedPlugins() {
        guard let bundle = ProcessInfo.processInfo.environment["DALNOK_TEST_VST3"], !bundle.isEmpty else {
            return print("SKIP  hosted plug-in UI checks (set DALNOK_TEST_VST3)")
        }
        guard let keys = s.tracks.first(where: \.isInstrument) else { return check(false, "an instrument track exists") }
        w.headers.select(keys.id)
        _ = perform("Plug-ins")
        let pm = w.pluginManager
        check(pm.onAdd?(bundle) == nil, "Add to Selected Track loads the test plug-in (the instrument class comes first only if asked)")
        var t = s.track(keys.id)
        check(t?.plugins.count == 1, "the track lists its plug-in (\(t?.plugins.map(\.name) ?? []))")
        // The test bundle's first class is an effect: it becomes an insert after Dalnok Poly.
        check(w.headers.row(keys.id)?.inputButton.title.contains("1 FX") == true, "header shows the insert (\(w.headers.row(keys.id)?.inputButton.title ?? "-"))")
        let menu = w.pluginsMenu(for: t!)
        let remove = menu.items.first { $0.title.hasPrefix("Remove Dalnok Test Gain") }
        check(remove != nil, "track menu offers to remove it")
        if let remove { menu.performActionForItem(at: menu.index(of: remove)) }
        t = s.track(keys.id)
        check(t?.plugins.isEmpty == true && s.engine.undoName == "Remove Plug-in", "removed through the track menu as one undo step")
        _ = perform("Undo")
        check(s.track(keys.id)?.plugins.count == 1, "undo brings the plug-in back")
        pm.window?.orderOut(nil)
        // Plug-in window: no editor view in the test plug-in, so the generic parameter panel opens.
        guard let slot = s.track(keys.id)?.plugins.first?.id else { return }
        let trackMenu = w.pluginsMenu(for: s.track(keys.id)!) // held: items reference their menu weakly
        let open = trackMenu.items.first { $0.title == "Open Dalnok Test Gain" }
        check(open != nil, "track menu offers to open the plug-in")
        if let open { trackMenu.performActionForItem(at: trackMenu.index(of: open)) }
        guard let pw = w.pluginWindows[slot] else { return check(false, "plug-in window opened") }
        check(!pw.editorOpen && pw.parameters.count == 1 && fixedString(pw.parameters[0].title) == "Gain",
              "parameter panel lists the plug-in's parameters (\(pw.parameters.map { fixedString($0.title) }))")
        pw.set(1, 0.25)
        check(pw.current(1)?.value == 0.25 && fixedString(pw.current(1)!.display) == "25 %", "panel sets a parameter and shows the plug-in's text")
        pw.filter("xyz")
        check(pw.rows.isEmpty, "parameter search filters")
        pw.window?.close()
        check(w.pluginWindows[slot] == nil, "closing the plug-in window releases it")
    }

    /// Device panel with Apple's built-in Audio Units (present on every Mac): controller knobs, Edit Controls, undo.
    private func devicePanel() {
        guard let track = s.tracks.first(where: { !$0.isInstrument })?.id else { return check(false, "an audio track exists") }
        w.headers.select(track)
        let slot = (try? s.addPlugin(track, path: "au:aufx:dely:appl")) ?? 0
        check(slot != 0, "AUDelay loads as an insert")
        let limiter = (try? s.addPlugin(track, path: "au:aufx:lmtr:appl")) ?? 0
        let panel = w.devicePanel
        check(!panel.isHidden && panel.devices.map(\.slot) == [slot, limiter], "device panel shows the track's plug-ins in order")
        check(panel.subviewsDeep.contains { ($0 as? NSButton)?.title.contains("Add Plug-in") == true && !$0.isHiddenOrHasHiddenAncestor },
              "device panel offers Add Plug-in after the chain")
        if Analog.on {
            panel.layoutCables()
            check(panel.cableCount == 3, "Warm Analog patches IN → AUDelay → AUPeakLimiter → OUT with \(panel.cableCount) cables")
        }
        // Plug-in parameter automation: the plug-in window's Automate shows the lane; a click adds points.
        w.openPluginWindow(track: track, slot: slot)
        if let pw = w.pluginWindows[slot], let i = s.tracks.firstIndex(where: { $0.id == track }) {
            pw.tabs.selectedSegment = 1; pw.tabChanged(nil)
            pw.table.selectRowIndexes([0], byExtendingSelection: false)
            let param = pw.rows.first?.id ?? 0
            pw.automateSelected()
            check(w.timeline.showAutomation && w.timeline.pluginLanes[track] != nil, "Automate in Arrangement shows the parameter's lane")
            let tl = w.timeline, y = tl.laneY(i)
            let lane = tl.pluginLanes[track]!
            let at = tl.convert(CGPoint(x: tl.xPos(forFrame: s.beatToFrame(s.barToBeat(1))), y: tl.autoY(0.8, laneY: y, lane: lane)), to: nil)
            tl.mouseDown(with: mouse(.leftMouseDown, at)); tl.mouseUp(with: mouse(.leftMouseUp, at))
            let pts = s.pluginAutomation(track, slot, param)
            check(pts.count == 2 && abs((pts.last?.value ?? 0) - 0.8) < 0.05 && s.engine.undoName == "Plug-in Automation",
                  "clicking the lane adds a plug-in automation point (\(pts.map { ($0.frame, $0.value) }))")
            check(perform("Undo") && s.pluginAutomation(track, slot, param).isEmpty, "undo removes it")
            _ = perform("Show Automation"); tl.pluginLanes = [:]
            pw.window?.close()
        } else { check(false, "AUDelay's window opens") }
        guard let delay = panel.devices.first else { return }
        let names = delay.knobs.map { $0.label.stringValue }
        check(delay.knobs.count == 4 && names.contains("Dry/Wet Mix"), "controller shows AUDelay's parameters (\(names))")
        if let lim = panel.devices.last {
            let limNames = lim.knobs.map { $0.label.stringValue }
            check(lim.knobs.count == lim.controlIds.count && !limNames.contains(""), "every limiter control has a named knob (\(limNames))")
        }
        // Turning a knob changes the plug-in.
        guard let mix = delay.knobs.first else { return check(false, "AUDelay has a controller knob") }
        delay.set(mix.id, 0.2)
        check(abs((delay.current(mix.id)?.value ?? 0) - 0.2) < 1e-4 && mix.value.stringValue.hasPrefix("20"), "knob sets the parameter (\(mix.value.stringValue))")
        // Edit Controls: remove one control, undo restores the default set.
        delay.toggleControl(mix.id)
        check(delay.knobs.count == 3 && s.engine.undoName == "Edit Controls", "Edit Controls removes a knob as one undo step")
        _ = perform("Undo")
        panel.rebuild()
        check(panel.devices.first?.knobs.count == 4, "undo restores the controller")
        // External change (as from the plug-in's own window): the knob follows.
        dalnok_plugin_set_parameter(s.engine.handle, slot, mix.id, 0.9)
        panel.refreshValues()
        check(abs((panel.devices.first?.knobs.first?.knob.value ?? 0) - 0.9) < 1e-4, "knob follows changes made elsewhere")
        check(perform("Device Panel") && w.devicePanel.isHidden, "View > Device Panel hides it")
        _ = perform("Device Panel")
        s.removePlugin(track, limiter)
        s.removePlugin(track, slot)
        check(w.devicePanel.devices.isEmpty, "removing the plug-ins clears the panel")
    }

    /// Animations run when motion is allowed and are skipped with Reduce Motion.
    private func motion() async {
        let e = s.engine
        guard let track = s.tracks.first?.id, let row = w.headers.row(track) else { return check(false, "a track for motion checks") }
        Motion.override = true
        defer { Motion.override = false }
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
        if Analog.on, let content = w.window?.contentView {
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

    /// Clip launcher: View ▸ Clip Launcher, copy a selected clip into a slot, launch it on the bar, stop it.
    private func launcherSteps() async {
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
    private func mixerAndRouting() async {
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
    private func cycle() async {
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
    private func tempoAndMetronome() async {
        let e = s.engine
        w.transport.tempoField.stringValue = "96"
        w.tempoEdited(nil)
        check(abs(s.bpm - 96) < 1e-9 && e.undoName == "Tempo", "tempo field sets 96 BPM as an undo step")
        w.transport.tempoField.stringValue = "1000"
        w.tempoEdited(nil)
        check(abs(s.bpm - 96) < 1e-9 && w.transport.tempoField.stringValue == "96", "invalid tempo is rejected and the field restored")
        w.transport.meterPopup.selectItem(withTitle: "3/4")
        w.meterChosen(nil)
        check(s.meter == (3, 4), "meter popup sets 3/4")
        let wasBars = TimelineView.barsAndBeats
        if !wasBars { _ = perform("Bars and Beats Ruler") }
        e.seek(Int64(e.sampleRate * 60 / 96 * 3) + Int64(e.sampleRate * 60 / 96)) // bar 2, beat 2
        try? await Task.sleep(for: .milliseconds(150))
        check(w.transport.timeLabel.stringValue.hasPrefix("2.2.1."), "LCD shows bars and beats (\(w.transport.timeLabel.stringValue))")
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

    private func finish() {
        for key in Self.restoredKeys {
            if let value = previousPreferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        print(failures == 0 ? "SELFTEST: PASS" : "SELFTEST: FAIL (\(failures))")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}

extension NSView {
    /// Every descendant view (self excluded), depth first.
    var subviewsDeep: [NSView] { subviews.flatMap { [$0] + $0.subviewsDeep } }
}
