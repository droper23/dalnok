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
    private static let restoredKeys = ["copyAudioOnSave", "comingFrom", "onboardingDone", "recordingInputUID", "rulerBarsAndBeats", "metronome", "showDevicePanel", "countIn", "showMixer", "showLauncher", "automationMode", "pedal.AUDelay", "shortcuts.preset", "shortcuts.overrides", "shortcuts.userPresets"] + PluginLibrary.keys + ["tapeSpeed", "trackHeight", "secondaryClock", "gainRingLevel", "isolatePlugins"] + Faceplate.preferenceKeys
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
        s.refresh(onDisplayTick: true) // simulate a display tick between scripted menu actions
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
        // A known layout whatever the owner left open (the mixer would squeeze the tracks to a sliver); restored at the end.
        if MainWindowController.showMixer { w.toggleMixer(nil) }
        if MainWindowController.showLauncher { w.toggleLauncher(nil) }
        UserDefaults.standard.removeObject(forKey: "secondaryClock")
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
            s.refresh(onDisplayTick: true) // simulate the next display tick
            let g = s.track(row.trackId)!.gainDb
            check(g < -2 && e.undoName == "Volume", String(format: "gain knob drag lowered volume to %.1f dB (one undo step)", g))
            f.mouseDown(with: mouse(.leftMouseDown, center, .option))
            s.refresh(onDisplayTick: true)
            check(s.track(row.trackId)!.gainDb == 0, "⌥-click resets gain to 0 dB")
            let k = row.pan
            k.mouseDown(with: mouse(.leftMouseDown, at(k, k.bounds.midX, k.bounds.midY)))
            k.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: at(k, k.bounds.midX, 0).x, y: at(k, k.bounds.midX, k.bounds.midY).y + 30)))
            k.mouseUp(with: mouse(.leftMouseUp, at(k, k.bounds.midX, k.bounds.midY)))
            s.refresh(onDisplayTick: true)
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
        s.refresh(onDisplayTick: true)
        check(s.track(t0)?.solo == true, "track soloed")
        _ = perform("Solo Track")
        s.refresh(onDisplayTick: true)
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
            if let recovery {
                // Simulate a previous snapshot predating this new session, then
                // another crash before the delayed recovery alert appears.
                try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: recovery.path)
                w.beginSessionMarker(carrying: [recovery])
                if let data = try? Data(contentsOf: marker),
                   var info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    info["pid"] = 999_999
                    try? JSONSerialization.data(withJSONObject: info).write(to: marker)
                }
                check(w.unfinishedSessionSnapshot()?.resolvingSymlinksInPath() == recovery.resolvingSymlinksInPath(),
                      "a second crash before the alert keeps the previous recovery offer")
                w.beginSessionMarker(carrying: [recovery])
                let incoming = recoveryDir.appendingPathComponent("Recovery-incoming.dalnok")
                try? Data("new project".utf8).write(to: incoming)
                let pending = w.unfinishedSessionSnapshots()
                check(pending.map(\.lastPathComponent) == [incoming.lastPathComponent, recovery.lastPathComponent],
                      "newer incoming snapshot and previous recovery are both offered after a crash")
                w.beginSessionMarker(carrying: pending)
                w.clearPendingRecovery(incoming)
                check(w.unfinishedSessionSnapshot()?.lastPathComponent == recovery.lastPathComponent,
                      "handling the newer copy exposes the earlier recovery")
                w.endSessionMarker()
                check(w.unfinishedSessionSnapshot()?.lastPathComponent == recovery.lastPathComponent,
                      "a clean quit preserves an unresolved recovery offer")
                w.beginSessionMarker(carrying: [recovery])
                w.clearPendingRecovery(recovery)
                check(w.unfinishedSessionSnapshots().isEmpty, "handled offers are not repeated")
                try? FileManager.default.removeItem(at: incoming)
            }
            w.beginSessionMarker()
            w.endSessionMarker()
            check(!FileManager.default.fileExists(atPath: marker.path) && w.unfinishedSessionSnapshot() == nil,
                  "a clean quit removes the marker, so the next launch offers nothing")
        }

        await trackHeaderScrolling()
        if ProcessInfo.processInfo.environment["DALNOK_SKIP_SHORTCUT_TEST"] == nil { await shortcutSystem() }
        await clipEditing()
        deadControls()
        await tapeMachine()
        await markersAndTrackTools()
        await partialTimelineRedraw()
        await realInputChecks()
        await deferredPluginLoading()
        await slowIsolatedPluginLoading()
        await isolatedPluginEditors()
        try? w.snapshot(to: workdir.appendingPathComponent("selftest.png"))
        await migrationSteps()
        // Settings: exercise the menu, appearance selection, and project preference.
        let oldTheme = UserDefaults.standard.object(forKey: "appearanceStyle")
        let oldCopy = MainWindowController.copyAudioOnSave
        check(perform("Settings…"), "Dalnok > Settings opens")
        check(w.settings.window?.isVisible == true, "settings window is visible")
        // ADR-0014: Settings > Plug-ins > Safety runs plug-ins loaded afterwards in their own processes.
        let isolation = w.settings.isolatePlugins
        if isolation.isEnabled, let action = isolation.action, let track = s.tracks.first?.id {
            isolation.state = .on; _ = NSApp.sendAction(action, to: isolation.target, from: isolation)
            check(s.engine.pluginHost == Engine.pluginHostPath, "Safety on: new plug-ins go to dalnok-plughost")
            var err = [CChar](repeating: 0, count: 256)
            let before = dalnok_track_plugin_count(s.h, track)
            let slot = dalnok_plugin_add(s.h, track, "au:aufx:dely:appl", nil, &err, 256)
            var info = DalnokPluginSlotInfo()
            _ = dalnok_track_plugin_info(s.h, track, before, &info)
            check(slot != 0 && info.isolated && info.loaded && fixedString(info.name).contains("Delay"),
                  "an Audio Unit loads in its own process (\(cString(err)))")
            if slot != 0 { _ = perform("Undo") }
            isolation.state = .off; _ = NSApp.sendAction(action, to: isolation.target, from: isolation)
            check(s.engine.pluginHost.isEmpty, "Safety off: plug-ins load in the app again")
        } else { check(false, "the Safety setting is available (dalnok-plughost next to the app)") }
        for pane in SettingsController.Pane.allCases { w.settings.show(pane) }
        check(w.settings.pane == .shortcuts && w.shortcutsEditor.table.window === w.settings.window,
              "Settings has every pane, keyboard shortcuts included")
        w.settings.show(.general)
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

    // MARK: Track header scrolling (regression: scrolling over the headers did nothing or moved a knob)

    private func scrollEvent(dy: Int32, at window: CGPoint) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0) else { return nil }
        cg.flags = [] // not whatever modifiers the system thinks are held (⌥/⌘ would zoom instead)
        if let win = w.window { cg.location = CGPoint(x: win.frame.minX + window.x, y: (NSScreen.screens.first?.frame.height ?? 0) - (win.frame.minY + window.y)) }
        return NSEvent(cgEvent: cg)
    }

    private func trackHeaderScrolling() async {
        let e = s.engine
        var added = 0
        w.window?.layoutIfNeeded()
        let visible = max(w.timeline.bounds.height, 400)
        while CGFloat(s.tracks.count) * Theme.trackHeight < visible * 2, added < 40 { s.addTrack("Scroll \(added)"); added += 1 }
        w.window?.layoutIfNeeded()
        await wait(0.1)
        print("INFO  header scrolling: timeline \(w.timeline.bounds.height) pt, \(s.tracks.count) tracks, max offset \(w.timeline.maxScrollY), hidden \(w.timeline.isHidden)")
        w.timeline.scrollY = 0
        guard let row = w.headers.rows.first, let ev = scrollEvent(dy: -60, at: .zero) else {
            check(false, "header scrolling: rows and scroll events exist"); return
        }
        let before = row.gain.db
        w.headers.scrollWheel(with: ev)
        check(w.timeline.scrollY > 0, "scrolling over the track headers scrolls the tracks (\(w.timeline.scrollY) pt)")
        check(w.headers.scrollY == w.timeline.scrollY && w.launcher.scrollY == w.timeline.scrollY,
              "headers, launcher and arrangement share one vertical offset")
        let y = w.timeline.scrollY
        row.gain.scrollWheel(with: ev)
        check(row.gain.db == before && w.timeline.scrollY > y, "scrolling over a header knob scrolls instead of changing gain")
        // Hit-testing: the view under the cursor in the header column hands scrolling to the column.
        if let content = w.window?.contentView {
            let p = w.headers.convert(CGPoint(x: w.headers.bounds.midX, y: w.headers.bounds.midY), to: nil)
            var v = content.hitTest(content.convert(p, from: nil)), reaches = false
            while let x = v { if x === w.headers { reaches = true; break }; v = x.superview }
            check(reaches, "the view under the cursor over the headers belongs to the header column")
        }
        w.timeline.scrollY = 1e6
        w.timeline.clampScrollY()
        check(w.timeline.scrollY == w.timeline.maxScrollY && w.headers.scrollY == w.timeline.scrollY, "vertical scrolling stops at the last track")
        for _ in 0..<added { e.undo() }
        s.refresh(onDisplayTick: true); w.window?.layoutIfNeeded()
        check(w.timeline.scrollY <= w.timeline.maxScrollY && w.headers.scrollY == w.timeline.scrollY,
              "removing tracks keeps the viewport valid and aligned (\(w.timeline.scrollY))")
        w.timeline.scrollY = 0
    }

    // MARK: Keyboard shortcuts (registry, presets, conflicts, dispatch, editor)

    private func keyEvent(_ chars: String, code: UInt16, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: w.window!.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    private func shortcutSystem() async {
        let r = ShortcutRegistry.shared
        w.window?.makeKeyAndOrderFront(nil)
        r.selectPreset("dalnok")
        // Parsing and text forms.
        let samples = ["cmd+shift+t", "kp*", "ctrl+space", "f9", "opt+x", "cmd+=", "shift+up", "cmd+["]
        let parsed = samples.compactMap(KeyCombo.init(parsing:))
        check(parsed.count == samples.count && parsed.allSatisfy { KeyCombo(parsing: $0.storage) == $0 },
              "shortcut text round-trips (\(parsed.map(\.description).joined(separator: " ")))")
        check(KeyCombo(parsing: "⇧⌘T") == KeyCombo(parsing: "cmd+shift+t") && KeyCombo(parsing: "Cmd Shift Z")?.description == "⇧⌘Z",
              "symbol and word forms parse to the same shortcut")
        // Every command is registered once, with a category; the brief's named commands exist.
        let ids = r.actions.map(\.id)
        check(Set(ids).count == ids.count && r.actions.count > 70 && r.actions.allSatisfy { !$0.category.isEmpty },
              "registry: \(r.actions.count) commands, unique ids, all categorized")
        let named = ["transport.play_pause", "transport.record", "track.create_audio", "track.create_midi", "track.delete",
                     "edit.split_at_playhead", "mixer.toggle", "plugin.open_browser", "plugin.bypass_track", "view.toggle_analog_mode",
                     "midi.quantize", "edit.undo", "view.full_screen", "app.keyboard_shortcuts"]
        check(named.allSatisfy { r.action($0) != nil }, "named commands are registered (\(named.filter { r.action($0) == nil }))")
        // No preset has conflicts; presets change the menu.
        for p in ShortcutPreset.all {
            r.selectPreset(p.id)
            let c = r.allConflicts()
            check(c.isEmpty, "\(p.title) preset has no conflicts \(c.map { "\($0.0): \($0.1.map(\.id))" })")
        }
        r.selectPreset("ableton")
        check(menuItem("Split at Playhead")?.keyEquivalent == "e" && r.keys("view.clip_launcher") == [KeyCombo("tab")],
              "Ableton preset: Split ⌘E, launcher Tab")
        r.selectPreset("cubase")
        check(r.keys("transport.record").contains(KeyCombo("kp*")) && r.action("transport.record")?.item?.keyEquivalent == "",
              "Cubase preset: Record on keypad * (dispatched by the registry, not the menu)")
        r.selectPreset("dalnok")
        // Owner override: shown in the menu, persisted, dispatched by a real key event; the old key is free.
        let combo = KeyCombo("y", [.command, .option, .shift])
        r.setKeys("transport.metronome", [combo])
        check(menuItem("Metronome")?.keyEquivalent == "y" && menuItem("Metronome")?.keyEquivalentModifierMask == [.command, .option, .shift],
              "a changed shortcut appears in the menu")
        let stored = UserDefaults.standard.dictionary(forKey: ShortcutRegistry.overridesKey) as? [String: [String]]
        check(stored?["transport.metronome"] == ["opt+shift+cmd+y"], "the change is saved (\(stored ?? [:]))")
        r.attach(NSApp.mainMenu)
        check(r.keys("transport.metronome") == [combo], "it survives re-reading the menu (as after a relaunch)")
        let m0 = MainWindowController.metronomeOn
        _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("y", code: 16, [.command, .option, .shift]))
        check(MainWindowController.metronomeOn != m0, "⌥⇧⌘Y toggles the metronome")
        _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("k", code: 40))
        check(MainWindowController.metronomeOn != m0, "K no longer toggles it")
        r.add(KeyCombo("f8"), to: "transport.metronome")
        _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent(String(UnicodeScalar(NSF8FunctionKey)!), code: 100))
        check(MainWindowController.metronomeOn == m0, "a second shortcut (F8) runs the same command")
        // Conflicts: detected, then resolved by reassigning.
        r.add(combo, to: "transport.loop")
        check(r.conflicts(for: combo, in: .global).count == 2 && !r.allConflicts().isEmpty, "giving the key to Cycle too is reported as a conflict")
        r.reassign(combo, to: "transport.loop")
        check(r.keys("transport.loop").contains(combo) && !r.keys("transport.metronome").contains(combo) && r.allConflicts().isEmpty,
              "reassigning moves the key and clears the conflict")
        // Context: ↑ selects the previous track in the arrangement and transposes in the piano roll; not a conflict.
        check(r.resolve(KeyCombo("up"), context: .arrangement)?.id == "track.select_previous" &&
              r.resolve(KeyCombo("up"), context: .pianoRoll)?.id == "midi.transpose_up" && r.allConflicts().isEmpty,
              "the same key does different things in the arrangement and the piano roll")
        check(ShortcutRegistry.reservedBySystem(KeyCombo("space", .command)) != nil, "⌘Space is flagged as belonging to macOS")
        // While renaming a track, ⌃ and ⌥ keys edit and type; only ⌘ shortcuts run (regression: ⌃F/⌃H/⌥' were taken).
        if let row = w.headers.rows.first {
            let fades0 = s.engine.undoName
            row.beginRename()
            await wait(0.1)
            check(MainWindowController.isTyping, "renaming puts a field editor in charge")
            _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("h", code: 4, .control))
            _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("'", code: 39, .option))
            check(s.tracks.count > 0 && s.engine.undoName == fades0 && s.hiddenCount == 0, "⌃H and ⌥' reach the text field, not Hide Track or Add Marker")
            row.cancelRename()
            await wait(0.1)
            // Clicking outside the name field commits the typed name (as Return does).
            let oldName = s.track(row.trackId)?.name ?? ""
            row.beginRename()
            await wait(0.1)
            (w.window?.firstResponder as? NSTextView)?.string = "Renamed By Click"
            let outside = w.timeline.convert(CGPoint(x: w.timeline.bounds.midX, y: w.timeline.bounds.maxY - 4), to: nil)
            w.window?.sendEvent(mouse(.leftMouseDown, outside)); w.window?.sendEvent(mouse(.leftMouseUp, outside))
            await wait(0.1)
            check(s.track(row.trackId)?.name == "Renamed By Click" && !MainWindowController.isTyping, "clicking outside a track name being edited keeps the new name")
            s.renameTrack(row.trackId, oldName)
        }
        // A dialog owns Return and Escape: shortcuts stay out of its way (regression: Return ran Go to Start under an alert).
        let alert = NSAlert(); alert.messageText = "Shortcut test"; alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: w.window!) { _ in }
        await wait(0.3)
        let returnKey = keyEvent("\r", code: 36)
        check(ShortcutRegistry.dialogInFront && !r.handle(returnKey), "with a sheet open, Return is left to the dialog")
        w.window?.endSheet(alert.window)
        await wait(0.2)
        check(!ShortcutRegistry.dialogInFront, "after the sheet closes, shortcuts work again")
        // Export and import round-trip.
        if let data = r.exportData() {
            r.restoreAll()
            let res = try? r.importData(data)
            check(res?.skipped == 0 && r.keys("transport.loop").contains(combo) && r.keys("transport.metronome").contains(KeyCombo("f8")),
                  "export then import restores the changes (\(res.map { "\($0.applied) applied" } ?? "failed"))")
        } else { check(false, "shortcuts export") }
        // Track navigation commands.
        if s.tracks.count >= 2 {
            w.headers.select(s.tracks[0].id)
            check(perform("Select Next Track") && w.selectedTrack == s.tracks[1].id, "Track ▸ Select Next Track")
            check(perform("Select Previous Track") && w.selectedTrack == s.tracks[0].id, "Track ▸ Select Previous Track")
        }
        // The editor: search by name and by key, record, resolve a conflict, restore.
        check(perform("Keyboard Shortcuts…") && w.shortcutsEditor.window?.isVisible == true, "Dalnok ▸ Keyboard Shortcuts… opens the editor")
        let ed = w.shortcutsEditor
        ed.search.stringValue = "split"; ed.reload()
        check(ed.visibleActionIds.contains("edit.split_at_playhead") && !ed.visibleActionIds.contains("transport.play_pause"), "editor search by name")
        ed.search.stringValue = combo.description; ed.reload()
        check(ed.visibleActionIds == ["transport.loop"], "editor search by key (\(combo.description) → \(ed.visibleActionIds))")
        ed.search.stringValue = ""; ed.reload()
        if let metro = r.action("transport.metronome") {
            ed.select(metro)
            ed.beginRecording(replacing: true)
            check(ShortcutRegistry.capturing && ed.window?.firstResponder === ed.recorder, "recording captures the keyboard")
            let m1 = MainWindowController.metronomeOn
            _ = ed.recorder.performKeyEquivalent(with: keyEvent("j", code: 38, [.command, .option]))
            check(r.keys("transport.metronome") == [KeyCombo("j", [.command, .option])] && MainWindowController.metronomeOn == m1 && !ShortcutRegistry.capturing,
                  "a recorded ⌥⌘J replaces the shortcut and runs nothing")
            ed.select(metro)
            ed.beginRecording(replacing: false)
            _ = ed.recorder.performKeyEquivalent(with: keyEvent("k", code: 40, [.command, .option])) // ⌥⌘K: Keyboard Shortcuts…
            check(ed.pending == KeyCombo("k", [.command, .option]) && !r.keys("transport.metronome").contains(ed.pending!),
                  "recording a key in use asks before taking it")
            ed.resolveTake()
            check(r.keys("transport.metronome").contains(KeyCombo("k", [.command, .option])) && r.keys("app.keyboard_shortcuts").isEmpty,
                  "Use It Here takes the key from the other command")
        }
        ed.restoreAll()
        check(r.overrides.isEmpty && r.action("transport.metronome")?.item?.keyEquivalent == "k" && r.action("app.keyboard_shortcuts")?.item?.keyEquivalent == "k",
              "Restore All Defaults brings back the preset (\(r.overrides.keys.sorted()), metronome \(r.display("transport.metronome")), shortcuts \(r.display("app.keyboard_shortcuts")))")
        ed.window?.close()
        if MainWindowController.metronomeOn != m0 { _ = perform("Metronome", exact: true) } // through the command, so the engine follows
        check(MainWindowController.metronomeOn == m0, "metronome back to where it was")
    }

    // MARK: Markers, duplicate track, zoom to selection, vertical zoom

    /// ADR-0013: an opened project is shown before its plug-ins load; they load one per run-loop turn with progress,
    /// Stop leaves the rest unloaded with their settings, and the track menu loads one later.
    private func deferredPluginLoading() async {
        let e = s.engine
        e.pause()
        let restore = workdir.appendingPathComponent("before-deferred.dalnok")
        check(w.saveProject(to: restore), "save before the deferred-loading check")
        e.newProject(); s.refresh()
        let t = dalnok_track_add(e.handle, "Deferred")
        for _ in 0..<3 { _ = dalnok_plugin_add(e.handle, t, "dalnok:channel-eq", nil, nil, 0) }
        let project = workdir.appendingPathComponent("deferred.dalnok")
        check(w.saveProject(to: project), "save a project with three plug-ins")
        e.newProject(); s.refresh()
        let previous = s.onPluginLoadProgress
        var shownFirst = false, sawProgress = false, stopVisible = false, statusText = ""
        s.onPluginLoadProgress = { [weak self] p in
            previous?(p)
            guard let self, let p else { return }
            if p.done == 0 {
                shownFirst = self.s.tracks.count == 1 && self.s.tracks[0].plugins.allSatisfy { $0.loading && !$0.loaded }
                stopVisible = !self.w.transport.stopLoadingButton.isHidden
                statusText = self.w.transport.statusLabel.stringValue
            } else if p.done == 1 {
                sawProgress = self.s.tracks[0].plugins.map(\.loaded) == [true, false, false]
                self.w.transport.stopLoadingButton.performClick(nil) // Stop after the first plug-in
            }
        }
        let opened = await withCheckedContinuation { cont in w.openProject(project) { cont.resume(returning: $0) } }
        s.onPluginLoadProgress = previous
        check(opened, "deferred open completed")
        check(shownFirst, "the project is shown before its plug-ins load, each marked loading")
        check(stopVisible && statusText == "Loading plug-ins 1 of 3…", "status shows progress with a Stop button (\(statusText))")
        check(sawProgress, "plug-ins load one at a time")
        let plugins = s.tracks.first?.plugins ?? []
        check(plugins.map(\.loaded) == [true, false, false] && plugins.dropFirst().allSatisfy { $0.error.contains("cancelled") && !$0.loading },
              "Stop leaves the remaining plug-ins unloaded with their settings")
        check(w.transport.stopLoadingButton.isHidden && !e.isDirty, "Stop button hidden afterwards; loading is not an edit")
        if let track = s.tracks.first {
            let menu = w.pluginsMenu(for: track)
            if let load = menu.items.first(where: { $0.title == "Load \(plugins[1].name)" }), let action = load.action {
                _ = NSApp.sendAction(action, to: load.target, from: load)
                check(s.tracks.first?.plugins.map(\.loaded) == [true, true, false], "track menu ▸ Load loads one stopped plug-in")
            } else { check(false, "track menu offers Load for a stopped plug-in") }
            check(!menu.items.contains { $0.title == "Load \(plugins[0].name)" && $0.representedObject as? Int32 == plugins[0].id },
                  "no Load item for a loaded plug-in")
        }
        _ = await withCheckedContinuation { cont in w.openProject(restore) { cont.resume(returning: $0) } }
    }

    /// ADR-0014 stage 2 (closes the A-08 gap): with Safety on, plug-ins whose own initialization blocks for seconds load
    /// in their hosts while the window keeps running, and Stop ends the load at once. Needs DALNOK_TEST_VST3 (the
    /// test plug-in from scripts/ci/plugin-isolation.sh, whose "slow" mode sleeps in initialize) and dalnok-plughost.
    private func slowIsolatedPluginLoading() async {
        guard let bundle = ProcessInfo.processInfo.environment["DALNOK_TEST_VST3"], !bundle.isEmpty, Engine.pluginHostAvailable else {
            return print("SKIP  slow isolated plug-in loading (set DALNOK_TEST_VST3; dalnok-plughost next to the app)")
        }
        let e = s.engine
        e.pause()
        let restore = workdir.appendingPathComponent("before-slow.dalnok")
        check(w.saveProject(to: restore), "save before the slow-loading check")
        e.newProject(); s.refresh()
        dalnok_plugins_set_host(e.handle, nil)
        let t = dalnok_track_add(e.handle, "Slow")
        for _ in 0..<3 { _ = dalnok_plugin_add(e.handle, t, bundle, "44616C6E6F6B546573744761696E3031", nil, 0) }
        let project = workdir.appendingPathComponent("slow.dalnok")
        check(w.saveProject(to: project), "save a project with three test plug-ins")
        e.newProject(); s.refresh()
        dalnok_plugins_set_host(e.handle, Engine.pluginHostPath)
        let realStop = await realInputReady("Stop during slow isolated loading")
        setenv("DALNOK_TEST_INIT_FAILURE", "slow", 1); setenv("DALNOK_TEST_INIT_SLOW_MS", "4000", 1)
        // The main thread's longest stall while loading, measured by a 5 ms timer.
        final class Probe: @unchecked Sendable {
            var last: UInt64 = 0, started: UInt64 = 0, clicked: UInt64 = 0, worstAt: UInt64 = 0
            var worst = 0.0, first = 0.0, ticks = 0
        }
        let m = Probe()
        let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
            let now = DispatchTime.now().uptimeNanoseconds
            // Until Stop, after the first tick: that one also waits for the window to draw the newly opened project
            // (no plug-in code runs in this process), which is the open's cost, not loading's.
            if m.clicked == 0 && m.started > 0 {
                let gap = Double(now - m.last) / 1e6
                if m.ticks == 0 { m.first = gap } else if gap > m.worst { m.worst = gap; m.worstAt = now }
                m.ticks += 1
            }
            m.last = now
        }
        RunLoop.main.add(timer, forMode: .common)
        let previous = s.onPluginLoadProgress
        var stopVisible = false, statusText = ""
        s.onPluginLoadProgress = { [weak self] p in
            previous?(p)
            guard let self, let p, p.done == 0 else { return }
            stopVisible = !self.w.transport.stopLoadingButton.isHidden
            statusText = self.w.transport.statusLabel.stringValue
            m.last = DispatchTime.now().uptimeNanoseconds; m.started = m.last
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { // the plug-ins are 0.6 s into their 4 s initialization
                m.clicked = DispatchTime.now().uptimeNanoseconds
                let b = self.w.transport.stopLoadingButton
                if realStop { RealInput.click(self.screenPoint(b, NSPoint(x: b.bounds.midX, y: b.bounds.midY))) } else { b.performClick(nil) }
            }
        }
        let opened = await withCheckedContinuation { cont in w.openProject(project) { cont.resume(returning: $0) } }
        let stopToDone = Double(DispatchTime.now().uptimeNanoseconds &- m.clicked) / 1e6
        timer.invalidate()
        s.onPluginLoadProgress = previous
        unsetenv("DALNOK_TEST_INIT_FAILURE"); unsetenv("DALNOK_TEST_INIT_SLOW_MS")
        print(String(format: "MEASURE slow isolated load: worst main-thread gap %.1f ms over %d ticks before Stop (at %.0f ms; first tick after the open %.1f ms); Stop to done %.1f ms",
                     m.worst, m.ticks, Double(m.worstAt &- m.started) / 1e6, m.first, stopToDone))
        check(opened && stopVisible && statusText == "Loading plug-ins 1 of 3…", "slow isolated plug-ins show progress with Stop (\(statusText))")
        check(m.clicked > 0 && m.worst < 50 && m.ticks > 60, // 0.6 s of loading: ≥ 60 of 120 possible 5 ms ticks
              "the window keeps running while plug-ins sleep 4 s in initialization (worst gap \(String(format: "%.1f", m.worst)) ms)")
        check(stopToDone < 250, "\(realStop ? "a real click on " : "")Stop ends the load at once (\(String(format: "%.1f", stopToDone)) ms)")
        let plugins = s.tracks.first?.plugins ?? []
        check(plugins.count == 3 && plugins.allSatisfy { !$0.loaded && !$0.loading && $0.error.contains("cancelled") },
              "Stop leaves all three unloaded with their settings")
        check(w.transport.stopLoadingButton.isHidden && !e.isDirty, "Stop button hidden; loading is not an edit")
        if let track = s.tracks.first, let first = plugins.first {
            let menu = w.pluginsMenu(for: track)
            if let load = menu.items.first(where: { $0.title == "Load \(first.name)" }), let action = load.action {
                _ = NSApp.sendAction(action, to: load.target, from: load)
                let now = s.tracks.first?.plugins.first
                check(now?.loaded == true && now?.isolated == true, "track menu ▸ Load starts it in its own process")
            } else { check(false, "track menu offers Load for a stopped isolated plug-in") }
        }
        e.applyPluginIsolation()
        _ = await withCheckedContinuation { cont in w.openProject(restore) { cont.resume(returning: $0) } }
    }

    /// ADR-0015: an isolated plug-in's editor opens in a floating window of its own process, beside the plug-in window,
    /// without taking activation from Dalnok; it hides while another application is active and returns with Dalnok;
    /// closing the plug-in window closes it. The test VST3 (DALNOK_TEST_EDITOR=1) and Apple's AUDelay.
    private func isolatedPluginEditors() async {
        guard let bundle = ProcessInfo.processInfo.environment["DALNOK_TEST_VST3"], !bundle.isEmpty, Engine.pluginHostAvailable,
              let track = s.tracks.first?.id else {
            return print("SKIP  isolated plug-in editors (set DALNOK_TEST_VST3; dalnok-plughost next to the app)")
        }
        let e = s.engine
        dalnok_plugins_set_host(e.handle, Engine.pluginHostPath)
        setenv("DALNOK_TEST_EDITOR", "1", 1)
        defer { unsetenv("DALNOK_TEST_EDITOR"); e.applyPluginIsolation() }
        let frontBefore = NSWorkspace.shared.frontmostApplication
        for (path, cls, label) in [(bundle, "44616C6E6F6B546573744761696E3031", "test VST3"), ("au:aufx:dely:appl", "", "AUDelay")] {
            var err = [CChar](repeating: 0, count: 256)
            let slot = dalnok_plugin_add(e.handle, track, path, cls.isEmpty ? nil : cls, &err, 256)
            s.refresh()
            guard slot != 0 else { check(false, "\(label) loads isolated (\(cString(err)))"); continue }
            w.openPluginWindow(track: track, slot: slot)
            guard let pw = w.pluginWindows[slot] else { check(false, "\(label): plug-in window opens"); continue }
            await wait(0.4)
            var ed = DalnokPluginEditorWindow()
            _ = dalnok_plugin_editor_window(e.handle, slot, &ed)
            let frame = pw.window?.frame ?? .zero
            check(pw.isolated && pw.hostEditorOpen && ed.open && ed.visible && ed.process_id != getpid() && ed.process_id > 0,
                  "\(label): the editor opens in its host's window (pid \(ed.process_id))")
            let roomRight = frame.maxX + 212 < (pw.window?.screen?.visibleFrame.maxX ?? 0)
            check(!roomRight || (abs(ed.x - Double(frame.maxX + 12)) < 1 && abs(ed.y + ed.height - Double(frame.maxY)) < 1),
                  "\(label): beside the plug-in window (editor x \(Int(ed.x)), window right \(Int(frame.maxX)))")
            check(pw.tabs.selectedSegment == 1 && pw.tabs.isEnabled(forSegment: 0),
                  "\(label): Dalnok's plug-in window keeps the parameter panel; its Editor tab brings the host's window forward")
            check(NSWorkspace.shared.frontmostApplication?.processIdentifier != ed.process_id, "\(label): showing the editor does not activate the host")
            let png = workdir.appendingPathComponent("isolated-editor-\(label.replacingOccurrences(of: " ", with: "-")).png").path
            check(dalnok_plugin_editor_snapshot(e.handle, slot, png) == DALNOK_OK, "\(label): editor snapshot written (\(png))")
            if label == "AUDelay", ProcessInfo.processInfo.environment["DALNOK_REAL_INPUT"] == "1" { await typeIntoIsolatedEditor(slot, ed) }
            if label == "test VST3", ProcessInfo.processInfo.environment["DALNOK_REAL_INPUT"] == "1" { await spaceThroughIsolatedEditor(ed) }
            if label == "AUDelay", let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                // Follows Dalnok: hidden while another application is active, back when Dalnok is.
                NSApp.activate(ignoringOtherApps: true); await wait(0.5)
                finder.activate(); await wait(0.6)
                _ = dalnok_plugin_editor_window(e.handle, slot, &ed)
                let hidden = !ed.visible && ed.open
                NSApp.activate(ignoringOtherApps: true); await wait(0.6)
                _ = dalnok_plugin_editor_window(e.handle, slot, &ed)
                check(hidden && ed.visible, "AUDelay: the editor hides while Finder is active and returns with Dalnok (hidden \(hidden), back \(ed.visible))")
            }
            pw.window?.performClose(nil)
            await wait(0.2)
            _ = dalnok_plugin_editor_window(e.handle, slot, &ed)
            check(!ed.open && !ed.visible && w.pluginWindows[slot] == nil, "\(label): closing the plug-in window closes the editor")
            _ = dalnok_plugin_remove(e.handle, track, slot)
            s.refresh()
        }
        frontBefore?.activate()
    }

    /// DALNOK_REAL_INPUT=1: a real click in an isolated editor gives its window the keyboard; a real Space then still
    /// plays and stops Dalnok (keys the editor does not use are passed back, API 39).
    private func spaceThroughIsolatedEditor(_ ed: DalnokPluginEditorWindow) async {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
            return print("SKIP  Space through the isolated editor (the screen is locked)")
        }
        NSApp.activate(ignoringOtherApps: true); await wait(0.5)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            return print("SKIP  Space through the isolated editor (Dalnok could not be made frontmost)")
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let inside = CGPoint(x: ed.x + ed.width / 2, y: screenHeight - (ed.y + ed.content_height / 2)) // the editor's view
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(15_000) }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] { post(CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: inside, mouseButton: .left)) }
        await wait(0.3)
        let e = s.engine, wasPlaying = e.isPlaying
        func space() { for down in [true, false] { post(CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: down)) } }
        space(); await wait(0.5)
        let started = e.isPlaying
        space(); await wait(0.5)
        let stopped = !e.isPlaying
        print("MEASURE Space through the isolated editor: was playing \(wasPlaying), after first Space \(started), after second \(!stopped)")
        check(!wasPlaying && started && stopped, "Space pressed in an isolated editor's window plays and stops Dalnok")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), "clicking in the editor leaves Dalnok active")
    }

    /// DALNOK_REAL_INPUT=1 (unlocked screen, Accessibility): real OS-level clicks and typing reach an isolated editor.
    /// Clicks AUDelay's Dry/Wet value field in the host's window, types 25 and Return, and reads the parameter back.
    /// Dalnok is made frontmost first, so a key that missed the editor would land in Dalnok, never another app.
    private func typeIntoIsolatedEditor(_ slot: Int32, _ ed: DalnokPluginEditorWindow) async {
        // Never post input at a lock screen (it would type into the password field).
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
            return print("SKIP  real typing into the isolated editor (the screen is locked)")
        }
        NSApp.activate(ignoringOtherApps: true); await wait(0.5)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            return print("SKIP  real typing into the isolated editor (Dalnok could not be made frontmost)")
        }
        func dryWet() -> String {
            for i in 0..<dalnok_plugin_parameter_count(s.h, slot) {
                var p = DalnokPluginParameter()
                if dalnok_plugin_parameter(s.h, slot, i, &p) == DALNOK_OK, fixedString(p.title).contains("Dry/Wet") { return fixedString(p.display) }
            }
            return ""
        }
        let before = dryWet()
        // The value field sits at (405, 201) points from the content's top-left in AUDelay's 484 × 255 view.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let contentTop = screenHeight - (ed.y + ed.height - (ed.height - ed.content_height))
        let field = CGPoint(x: ed.x + 405 * ed.content_width / 484, y: contentTop + 201 * ed.content_height / 255)
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(15_000) }
        func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
            if flags.contains(.maskCommand) { let d = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true); d?.type = .flagsChanged; d?.flags = .maskCommand; post(d) }
            let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = flags; post(d)
            let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = flags; post(u)
            if flags.contains(.maskCommand) { let r = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false); r?.type = .flagsChanged; post(r) }
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: field, mouseButton: .left); post(e)
        }
        await wait(0.3)
        key(0, .maskCommand)                 // ⌘A selects the field's text
        for code: CGKeyCode in [19, 23] { key(code) } // 2, 5
        key(36)                              // Return
        await wait(0.6)
        let after = dryWet(), front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        print("MEASURE real input into isolated AUDelay editor at \(field): Dry/Wet \(before) → \(after)")
        check(after.hasPrefix("25"), "real clicks and typing reach the isolated editor (Dry/Wet \(before) → \(after))")
        check(front == getpid(), "typing into the editor leaves Dalnok the active application")
    }

    // ---- Real OS-level input (DALNOK_REAL_INPUT=1) ------------------------------------------------------------

    /// True when real input may be posted: asked for, the screen unlocked, and Dalnok frontmost (input goes to
    /// whatever application is in front, so a missed target lands in Dalnok, never another app).
    private func realInputReady(_ what: String) async -> Bool {
        guard ProcessInfo.processInfo.environment["DALNOK_REAL_INPUT"] == "1" else { return false }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
            print("SKIP  \(what) with real input (the screen is locked)"); return false
        }
        NSApp.activate(ignoringOtherApps: true); w.window?.makeKeyAndOrderFront(nil); await wait(0.5)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            print("SKIP  \(what) with real input (Dalnok could not be made frontmost)"); return false
        }
        return true
    }

    /// A point in `view` as a global screen point (top-left origin), where CGEvents are posted.
    private func screenPoint(_ view: NSView, _ p: NSPoint) -> CGPoint {
        guard let win = view.window else { return .zero }
        let q = win.convertPoint(toScreen: view.convert(p, to: nil))
        return CGPoint(x: q.x, y: (NSScreen.screens.first?.frame.height ?? 0) - q.y)
    }

    private enum RealInput {
        static var src: CGEventSource? { CGEventSource(stateID: .hidSystemState) }
        static func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(12_000) }
        static func mouse(_ t: CGEventType, _ p: CGPoint) {
            post(CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left))
        }
        static func click(_ p: CGPoint) { mouse(.mouseMoved, p); mouse(.leftMouseDown, p); mouse(.leftMouseUp, p) }
        static func drag(_ a: CGPoint, _ b: CGPoint) {
            mouse(.mouseMoved, a); mouse(.leftMouseDown, a)
            for k in 1...20 {
                let t = Double(k) / 20
                mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
            mouse(.leftMouseUp, b)
        }
        /// Presses and releases the modifiers around the key, like a hand on the keyboard, so none stays latched.
        static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
            let mods: [(CGEventFlags, CGKeyCode)] = [(.maskShift, 56), (.maskCommand, 55)]
            var held: CGEventFlags = []
            for (m, c) in mods where flags.contains(m) {
                held.insert(m)
                let e = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: true); e?.type = .flagsChanged; e?.flags = held; post(e)
            }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down); e?.flags = flags; post(e)
            }
            for (m, c) in mods.reversed() where flags.contains(m) {
                held.remove(m)
                let e = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: false); e?.type = .flagsChanged; e?.flags = held; post(e)
            }
        }
    }

    /// This branch's work driven by real mouse and keyboard events: a clip drag redraws one lane correctly and ⌘Z / ⇧⌘Z
    /// move it back and forth (A-03 deltas); Space plays a streamed file and a ruler click seeks into blocks that were
    /// never resident (A-09).
    private func realInputChecks() async {
        guard await realInputReady("timeline drag, undo and streamed playback") else { return }
        let tl = w.timeline, e = s.engine
        e.pause()
        if s.tracks.count >= 2, let clip = s.tracks[1].clips.first, let win = tl.window {
            for _ in 0..<2 { tl.needsDisplay = true; win.displayIfNeeded(); CATransaction.flush(); await wait(0.05) }
            let baseline = timelineMismatch()
            let r = tl.clipRect(clip, laneY: tl.laneY(1)), visible = tl.visibleRect
            let x0 = max(r.minX, visible.minX) + 10, x1 = min(r.maxX, visible.maxX) - 10
            guard x1 > x0 + 4 else { return check(false, "real drag: the second track's clip is on screen") }
            let from = screenPoint(tl, NSPoint(x: (x0 + x1) / 2, y: r.midY + 4))
            RealInput.drag(from, CGPoint(x: from.x + 60, y: from.y))
            await wait(0.4)
            let moved = s.tracks[1].clips.first { $0.id == clip.id }?.start ?? clip.start
            win.displayIfNeeded(); CATransaction.flush()
            let lanes = tl.lanesDrawn, partial = timelineMismatch()
            if partial > baseline { dumpTimeline("real-drag") }
            print("MEASURE real clip drag: start \(clip.start) → \(moved); \(lanes) lane(s) redrawn; \(partial) vs \(baseline) differing bytes")
            check(moved > clip.start && s.tracks[1].clips.count == s.tracks[1].clips.count, "a real mouse drag moves the clip right (\(clip.start) → \(moved))")
            check(partial <= baseline, "after the real drag the timeline matches a full redraw (\(partial) vs \(baseline) differing bytes)")
            guard await realInputReady("⌘Z / ⇧⌘Z") else { return }
            RealInput.key(6, .maskCommand); await wait(0.4) // ⌘Z
            let undone = s.tracks[1].clips.first { $0.id == clip.id }?.start
            RealInput.key(6, [.maskCommand, .maskShift]); await wait(0.4) // ⇧⌘Z
            let redone = s.tracks[1].clips.first { $0.id == clip.id }?.start
            check(undone == clip.start && redone == moved, "real ⌘Z / ⇧⌘Z undo and redo the drag exactly (\(undone ?? -1), \(redone ?? -1))")
            RealInput.key(6, .maskCommand); await wait(0.4)
            check(s.tracks[1].clips.first { $0.id == clip.id }?.start == clip.start, "and ⌘Z restores it")
        } else { check(false, "real drag needs two tracks with clips") }

        // A-09: a 90 s file (streamed above 30 s here) played with Space; a ruler click seeks far into it.
        let rate = 48_000, seconds = 90, wav = workdir.appendingPathComponent("long-tone.wav")
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = rate * seconds * 2
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(UInt32(bytes))
        data.reserveCapacity(44 + bytes)
        for i in 0..<(rate * seconds) { le(Int16(sin(Double(i) * 2 * .pi * 220 / Double(rate)) * 8_000)) }
        try? data.write(to: wav)
        let streamDir = workdir.appendingPathComponent("stream")
        setenv("DALNOK_STREAM_DIR", streamDir.path, 1)
        dalnok_stream_set_limits(30, 64)
        defer { dalnok_stream_set_limits(60, 256); unsetenv("DALNOK_STREAM_DIR") }
        let before = s.tracks.count
        await withCheckedContinuation { cont in s.importFiles([wav]) { cont.resume() } }
        s.refresh()
        guard s.tracks.count == before + 1, let clip = s.tracks.last?.clips.first, let media = dalnok_pool_media(s.h, clip.media) else {
            return check(false, "the 90 s file imports as a new track")
        }
        check(dalnok_media_streamed(media), "a 90 s file above the 30 s limit is streamed from disk")
        func stats() -> DalnokStreamStats { var o = DalnokStreamStats(); dalnok_stream_stats(&o); return o }
        e.seek(0); await wait(0.3)
        guard await realInputReady("streamed playback") else { return }
        let s0 = stats()
        RealInput.key(49); await wait(3.0) // Space
        let playing = e.isPlaying, p1 = e.position, s1 = stats()
        check(playing && Double(p1) > 2.5 * e.sampleRate, "real Space plays the streamed file (\(String(format: "%.2f", Double(p1) / e.sampleRate)) s)")
        check(s1.missed_frames == s0.missed_frames && s1.blocks_loaded > s0.blocks_loaded,
              "3 s of streamed playback misses no frames (missed \(s1.missed_frames - s0.missed_frames), blocks loaded \(s1.blocks_loaded - s0.blocks_loaded))")
        // The ruler's lower half seeks; aim as far right as the view shows, capped at 80 s.
        let visible = tl.visibleRect
        let x = min(tl.xPos(forFrame: 80 * e.sampleRate), visible.maxX - 20)
        RealInput.click(screenPoint(tl, NSPoint(x: x, y: Theme.rulerHeight * 0.75)))
        await wait(0.3)
        let landed = e.position
        let s2 = stats()
        await wait(2.0)
        let s3 = stats(), p3 = e.position
        print(String(format: "MEASURE real seek into streamed audio: landed %.2f s; missed %llu frames while the seek settled, then %llu in 2 s; resident %.1f of %.1f MB",
                     Double(landed) / e.sampleRate, s2.missed_frames - s1.missed_frames, s3.missed_frames - s2.missed_frames,
                     Double(s3.resident_bytes) / 1_048_576, Double(s3.budget_bytes) / 1_048_576))
        check(Double(landed) > 10 * e.sampleRate && p3 > landed, "a real ruler click seeks deep into the file and playback continues")
        check(s3.missed_frames == s2.missed_frames, "after the seek settles, streamed playback misses nothing")
        check(s3.resident_bytes <= s3.budget_bytes, "the block cache stays within its budget")
        RealInput.key(49); await wait(0.3)
        check(!e.isPlaying, "real Space stops playback")
        _ = perform("Undo")
        check(s.tracks.count == before, "undo removes the imported track")
    }

    /// Writes the timeline's committed layer and a fresh full draw as PNGs (diagnosing a redraw mismatch).
    private func dumpTimeline(_ name: String) {
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
    private func timelineMismatch() -> Int {
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
    private func partialTimelineRedraw() async {
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

    private func markersAndTrackTools() async {
        let e = s.engine
        e.pause()
        e.seek(Int64(e.sampleRate * 2)); await wait(0.15)
        check(perform("Add Marker", exact: true) && s.markers.count == 1 && e.undoName == "Add Marker", "Transport ▸ Add Marker adds one at the playhead")
        e.seek(Int64(e.sampleRate * 6)); await wait(0.15)
        _ = perform("Add Marker", exact: true)
        e.seek(0); await wait(0.15)
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
        e.seek(0); await wait(0.15)
        tl.mouseDown(with: mouse(.leftMouseDown, flag)); tl.mouseUp(with: mouse(.leftMouseUp, flag))
        await wait(0.15)
        check(abs(e.position - m0.frame) < 2, "clicking a marker flag moves the playhead there")
        s.renameMarker(m0.id, "Verse")
        check(fixedString(s.markers[0].name) == "Verse", "markers can be renamed")
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
        // A long instrument name never runs over the pan knob.
        if let row = w.headers.rows.first {
            let saved = row.inputButton.title
            row.inputButton.title = "A Very Long Instrument Name · 3 FX"
            row.layoutSubtreeIfNeeded()
            check(row.inputButton.frame.minX >= row.pan.frame.maxX + 7, "the input label stops before the pan knob (truncating)")
            row.inputButton.title = saved
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

    private func deadControls() {
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
            if !v.isHidden, let c = v as? NSControl, !(c is NSScroller), c.isEnabled, !(c is NSTextField && !(c as! NSTextField).isEditable) {
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

    private func tapeMachine() async {
        let e = s.engine
        e.pause(); e.seek(0); await wait(0.15)
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
        e.seek(0); await wait(0.1)
        // Warm Analog: the same keys live in the control bar, so the window is optional.
        if Analog.on {
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

    private func clipEditing() async {
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
        e.seek(c.end + 24_000); await wait(0.15)
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
        e.seek(0); await wait(0.1)
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
        print("STATE countIn=\(UserDefaults.standard.bool(forKey: "countIn")) metronome=\(MainWindowController.metronomeOn) playing=\(e.isPlaying) recording=\(e.isRecording) tracks=\(s.tracks.map(\.name)) armed=\(s.tracks.filter(\.armed).map(\.name)) key=\(NSApp.keyWindow?.title ?? "nil")")
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
        let exact = pm.all.filter { "\($0.name) \($0.vendor)".lowercased().contains("apple") }.count
        check(exact > 0 && pm.rows.count < pm.all.count && pm.rows.prefix(exact).allSatisfy { "\($0.name) \($0.vendor)".lowercased().contains("apple") },
              "search narrows the list; exact matches come before fuzzy ones (\(pm.rows.count))")
        check(pm.summary.stringValue.contains("VST3, Audio Unit and CLAP plug-ins can be added"), "the list says which formats can be added")
        pm.filter("")
        // Taxonomy: Apple's Audio Units by subtype, and declared VST3 subcategories / CLAP features.
        let cls = { (n: String, k: String, f: String, p: String, c: [String]) in PluginTaxonomy.classify(name: n, kind: k, format: f, path: p, categories: c) }
        let cases: [((PluginGroup, String), (PluginGroup, String))] = [
            (cls("AUDelay", "effect", "AU", "aufx:dely:appl", []), (.effects, "Delay / Echo")),
            (cls("AUPeakLimiter", "effect", "AU", "aufx:lmtr:appl", []), (.effects, "Limiting")),
            (cls("AUMatrixReverb", "effect", "AU", "aufx:mrev:appl", []), (.effects, "Reverb")),
            (cls("DLSMusicDevice", "instrument", "AU", "aumu:dls :appl", []), (.instruments, "Synthesizers")),
            (cls("Squash", "effect", "VST3", "/x.vst3", ["Fx", "Dynamics", "Stereo"]), (.effects, "Compression")),
            (cls("Wide", "effect", "VST3", "/x.vst3", ["Fx", "Stereo"]), (.effects, "Other Effects")),
            (cls("Lead", "instrument", "CLAP", "/x.clap", ["instrument", "synthesizer", "stereo"]), (.instruments, "Synthesizers")),
            (cls("Arp", "unknown", "CLAP", "/x.clap", ["note-effect", "arpeggiator"]), (.midi, "Arpeggiators")),
            (cls("Grand Piano", "instrument", "VST3", "/x.vst3", ["Instrument"]), (.instruments, "Pianos")),
            (cls("Clean Sample Trim", "effect", "VST3", "/x.vst3", ["Fx"]), (.effects, "Utility / Gain")),
        ]
        let wrong = cases.filter { $0.0 != $0.1 }.map { "\($0.0) ≠ \($0.1)" }
        check(wrong.isEmpty, "plug-in categories come from what plug-ins declare (\(wrong))")
        // Sidebar categories and fuzzy search.
        pm.select(source: .category(.effects, "Delay / Echo"))
        check(!pm.rows.isEmpty && pm.rows.allSatisfy { $0.category == "Delay / Echo" } && pm.rows.contains { $0.name == "AUDelay" },
              "the Delay / Echo category lists AUDelay (\(pm.rows.map(\.name)))")
        pm.select(source: .all)
        pm.filter("audly")
        check(pm.rows.first?.name == "AUDelay", "fuzzy search: 'audly' finds AUDelay first (\(pm.rows.prefix(3).map(\.name)))")
        pm.filter("reverb apple")
        check(!pm.rows.isEmpty && pm.rows.allSatisfy { $0.category == "Reverb" || $0.name.lowercased().contains("reverb") }, "search by capability and vendor")
        pm.filter("")
        // Built-in plug-ins (ADR-0011) are listed, always valid, and insert through their dalnok: path.
        if let eq = pm.all.first(where: { $0.format == "DALNOK" && $0.path == "channel-eq" }) {
            check(eq.addPath == "dalnok:channel-eq" && eq.group == .effects && !eq.failed, "Dalnok Channel EQ is listed as an effect (\(eq.addPath), \(eq.category))")
            let track = s.tracks.first { !$0.isInstrument }?.id ?? 0
            let before = dalnok_track_plugin_count(s.engine.handle, track)
            let slot = (try? s.addPlugin(track, path: eq.addPath)) ?? 0
            check(slot != 0 && dalnok_track_plugin_count(s.engine.handle, track) == before + 1, "the browser's path inserts Dalnok Channel EQ")
            if slot != 0 { s.removePlugin(track, slot) }
        } else { check(false, "Dalnok Channel EQ is listed in the plug-in browser") }
        // Favourites, collections, tags, format filter.
        if let delay = pm.all.first(where: { $0.name == "AUDelay" }) {
            pm.toggleFavorite(delay)
            pm.select(source: .favorites)
            check(pm.rows.map(\.name) == ["AUDelay"], "a starred plug-in appears in Favorites")
            pm.toggleFavorite(delay)
            check(pm.rows.isEmpty, "unstarring removes it")
            var c = PluginLibrary.collections; c["Mix Bus"] = []; PluginLibrary.collections = c
            pm.addToCollection("Mix Bus", delay)
            pm.select(source: .collection("Mix Bus"))
            check(pm.rows.map(\.name) == ["AUDelay"], "collections hold the plug-ins you put in them")
            var t = PluginLibrary.tags; t[delay.addPath] = ["slapback"]; PluginLibrary.tags = t
            pm.select(source: .all); pm.filter("slapback")
            check(pm.rows.map(\.name) == ["AUDelay"], "your tags are searchable")
            pm.filter("")
        }
        pm.formatControl.selectedSegment = 2; pm.filtersChanged()
        check(!pm.rows.isEmpty && pm.rows.allSatisfy { $0.format == "AU" }, "the format filter shows only Audio Units")
        pm.formatControl.selectedSegment = 0; pm.filtersChanged()
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
        // Duplicate track names must remain distinct choices in a sidechain menu.
        let duplicate1 = s.addTrack("Sidechain duplicate")
        let duplicate2 = s.addTrack("Sidechain duplicate")
        let namedNone = s.addTrack("None")
        if let fixture = ProcessInfo.processInfo.environment["DALNOK_TEST_CLAP"], !fixture.isEmpty {
            let sidechainSlot = (try? s.addPlugin(track, path: fixture)) ?? 0
            if let device = panel.devices.first(where: { $0.slot == sidechainSlot }), sidechainSlot != 0 {
                let accepted = dalnok_plugin_set_sidechain(s.engine.handle, track, sidechainSlot, duplicate2) == DALNOK_OK
                device.refreshControls()
                check(accepted && !device.sidechain.isHidden && device.sidechain.selectedTag() == Int(duplicate2),
                      "a hosted sidechain restores the selected duplicate-name track")
                s.removePlugin(track, sidechainSlot)
            } else { check(false, "sidechain fixture loads and opens its device") }
        }
        guard let delay = panel.devices.first else { return }
        let sidechainWasHidden = delay.sidechain.isHidden
        delay.sidechain.isHidden = false // AUDelay need not expose a sidechain to exercise the menu.
        delay.refreshControls()
        let duplicates = delay.sidechain.itemArray.filter { $0.title == "SC: Sidechain duplicate" }
        check(duplicates.count == 2 && Set(duplicates.map(\.tag)) == Set([Int(duplicate1), Int(duplicate2)]),
              "sidechain menu retains duplicate track names with distinct track IDs")
        let noneChoices = delay.sidechain.itemArray.filter { $0.title == "SC: None" }
        check(noneChoices.count == 2 && Set(noneChoices.map(\.tag)) == Set([0, Int(namedNone)]),
              "a track named None remains distinct from no sidechain")
        delay.sidechain.selectItem(withTag: Int(duplicate2))
        check(delay.sidechain.selectedTag() == Int(duplicate2), "a duplicate-name sidechain can be selected by track ID")
        delay.sidechain.isHidden = sidechainWasHidden
        s.removeTrack(namedNone); s.removeTrack(duplicate2); s.removeTrack(duplicate1)
        let names = delay.knobs.map { $0.label.stringValue }
        check(delay.knobs.count == 4 && names.contains { $0.caseInsensitiveCompare("Dry/Wet Mix") == .orderedSame }, "controller shows AUDelay's parameters (\(names))")
        if let lim = panel.devices.last {
            let limNames = lim.knobs.map { $0.label.stringValue }
            check(lim.knobs.count == lim.controlIds.count && !limNames.contains(""), "every limiter control has a named knob (\(limNames))")
        }
        // Bypass (power button in Graphite, footswitch on the Warm Analog pedal): real, undoable, nulls the effect.
        let delayName = "AUDelay"
        if let pedal = delay.pedal {
            check(Analog.on && pedal.controls.count == delay.knobs.count, "Warm Analog shows AUDelay as a pedal with \(pedal.controls.count) controls")
            check(PedalStore.look(delayName) == PedalStore.look(delayName) && PedalLook.random("A#0") != PedalLook.random("B#0"),
                  "a pedal's look is stable for its plug-in and differs between plug-ins")
            panel.layoutSubtreeIfNeeded()
            if let lim = panel.devices.last?.pedal {
                check(lim.controls.count < pedal.controls.count ? lim.frame.width < pedal.frame.width : lim.frame.width >= pedal.frame.width,
                      "pedal size follows the number of controls (\(lim.controls.count): \(lim.frame.width) pt, \(pedal.controls.count): \(pedal.frame.width) pt)")
            }
            let up = mouse(.leftMouseUp, pedal.footswitch.convert(CGPoint(x: pedal.footswitch.bounds.midX, y: pedal.footswitch.bounds.midY), to: nil))
            pedal.footswitch.mouseDown(with: mouse(.leftMouseDown, up.locationInWindow)); pedal.footswitch.mouseUp(with: up)
            check(s.pluginBypassed(track, slot) && !pedal.engaged && s.engine.undoName == "Bypass Plug-in", "stomping the footswitch bypasses AUDelay (LED off, undoable)")
            _ = perform("Undo"); panel.refreshValues()
            check(!s.pluginBypassed(track, slot) && pedal.engaged, "undo turns it back on")
            // Each control's kind can be changed and is remembered for that plug-in.
            if let c = pedal.controls.first, let item = c.menu(for: mouse(.rightMouseDown, .zero))?.items.first(where: { $0.title == "Slider" }) {
                _ = item.target?.perform(item.action, with: item)
                check(c.kind == .slider && PedalStore.kind(delayName, delay.knobs[0].id) == .slider, "a pedal control can become a slider and keeps that choice")
                PedalStore.setKind(delayName, delay.knobs[0].id, nil)
            } else { check(false, "pedal controls offer their kinds") }
            let before = pedal.look
            PedalStore.reroll(delayName)
            check(PedalStore.look(delayName) != before, "New Random Look changes the pedal")
            PedalStore.reset(delayName); UserDefaults.standard.removeObject(forKey: "pedal." + delayName)
        } else {
            delay.toggleBypass()
            check(s.pluginBypassed(track, slot) && s.engine.undoName == "Bypass Plug-in", "the device power button bypasses AUDelay (undoable)")
            delay.toggleBypass()
            check(!s.pluginBypassed(track, slot), "pressing it again turns it back on")
            // Graphite faceplate: controls suited to each parameter, printed scales, sections, meters.
            let faces = delay.knobs.compactMap { $0.knob as? FaceplateControl }
            check(faces.count == delay.knobs.count, "Graphite draws AUDelay's controls on a faceplate (\(faces.count) of \(delay.knobs.count))")
            if let time = faces.first(where: { $0.name.caseInsensitiveCompare("Delay Time") == .orderedSame }) {
                check(time.kind == .knob && time.legends == ["0", "2"], "the delay-time knob's scale is printed with the plug-in's own end values (\(time.legends))")
            } else { check(false, "AUDelay's faceplate has a Delay Time knob") }
            delay.toggleBypass()
            let scale = delay.layer?.affineTransform().a ?? 1
            check(faces.allSatisfy(\.dimmed) && delay.inMeter.poweredOff && (delay.display as? FaceplateScreen)?.poweredOff == true
                  && abs(scale - DeviceView.recessedScale) < 1e-6, "bypassing turns the unit's lights and screen off and sets it back (scale \(scale))")
            check(faces.allSatisfy { $0.light == 0 } && delay.inMeter.light == 0, "its lights are out once the fade ends")
            // The power key turns a shrunk unit back on from a press anywhere on the key, released a little off it.
            if let power = delay.powerKey {
                let at = power.convert(CGPoint(x: power.bounds.maxX - 2, y: power.bounds.maxY - 2), to: nil)
                NSApp.postEvent(mouse(.leftMouseUp, CGPoint(x: at.x + 6, y: at.y - 5)), atStart: true)
                power.mouseDown(with: mouse(.leftMouseDown, at))
                check(!s.pluginBypassed(track, slot), "a press at the edge of the power key turns the bypassed unit back on")
                delay.toggleBypass()
            } else { check(false, "the unit has a power key") }
            delay.toggleBypass()
            check(faces.allSatisfy { !$0.dimmed && $0.light == 1 } && !delay.inMeter.poweredOff && (delay.layer?.affineTransform().a ?? 0) == 1,
                  "turning it on lights them again")
            // Selection: pressing a unit selects it (white outline); the others are not selected.
            delay.onSelect?()
            check(panel.selectedSlot == delay.slot && delay.isSelected && (delay.layer?.borderWidth ?? 0) > 0
                  && panel.devices.filter(\.isSelected).count == 1, "pressing a unit selects it with a white outline")
            // Wear: a setting, remembered, drawn into the plate and glass.
            let wearBefore = UserDefaults.standard.object(forKey: "faceplateWear")
            Faceplate.wear = 0.9
            check(abs(Faceplate.wear - 0.9) < 1e-9 && Faceplate.seed("AUDelay") == Faceplate.seed("AUDelay") && Faceplate.seed("A") != Faceplate.seed("B"),
                  "plug-in wear is a remembered setting with a stable pattern per unit")
            if let wearBefore { UserDefaults.standard.set(wearBefore, forKey: "faceplateWear") } else { UserDefaults.standard.removeObject(forKey: "faceplateWear") }
            let eqSections = Faceplate.sections([(0, "Low Cut On/Off"), (1, "Low Cut Frequency"), (2, "Low Cut Slope"), (3, "Feedback"), (4, "Mix")])
            check(eqSections.map(\.title) == ["Low Cut", ""] && eqSections[0].items.map(\.label) == ["On", "Frequency", "Slope"]
                  && eqSections[1].items.count == 2, "related parameters share an engraved section (\(eqSections.map(\.title)))")
            let toggle = FaceplateControl(name: "On", steps: 1), selector = FaceplateControl(name: "Slope", steps: 8)
            var pressed: Double?
            toggle.onChange = { pressed = $0 }
            _ = toggle.accessibilityPerformPress()
            check(toggle.kind == .toggle && selector.kind == .selector && pressed == 1, "on/off parameters are push switches, short choices are selectors")
            check(Faceplate.legend("20000 Hz") == "20k" && Faceplate.legend("0.10") == "0.1", "scale legends are short (20k, 0.1)")
            check(!delay.inMeter.isHidden && !delay.outMeter.isHidden, "each unit shows input and output meters")
            // Displays chosen by category: energy history for the delay, a VU gain-reduction meter for the limiter, and so on.
            check(delay.displayKind == .history && delay.display is HistoryScreen, "AUDelay gets an energy-history screen")
            if let lim = panel.devices.last {
                check(lim.displayKind == .gainReduction && (lim.display as? MovingCoilMeter)?.mode == .gainReduction, "AUPeakLimiter gets a gain-reduction meter")
            }
            var kinds: [(String, String, FaceplateDisplay.Kind)] = [
                ("Dalnok Channel EQ", "channel-eq", .response), ("AUNBandEQ", "aufx:nbeq:appl", .response), ("AUHipass", "aufx:hpas:appl", .response),
                ("AUDynamicsProcessor", "aufx:dcmp:appl", .gainReduction), ("AUMultibandCompressor", "aufx:mcmp:appl", .gainReduction),
                ("AUDistortion", "aufx:dist:appl", .transfer), ("AUMatrixReverb", "aufx:mrev:appl", .history), ("AUDelay", "aufx:dely:appl", .history),
                ("Stereo Chorus", "", .goniometer), ("Wide Imager", "", .goniometer), ("MFlanger", "", .goniometer), ("MCompressor", "", .gainReduction), ("AUPitch", "aufx:tmpt:appl", .analyzer),
                ("Spectrum Analyzer", "", .analyzer), ("Gain Utility", "", .vu), ("Mystery Box", "", .scope)]
            let named: [(String, String, FaceplateDisplay.Kind)] = [("MDelay", "", .history), ("MAutoDynamicEq", "", .response), ("kHs Haas", "", .goniometer),
                ("T-De-Esser 2", "", .gainReduction), ("MStereoExpander", "", .goniometer), ("MCharmVerb", "", .history), ("kHs Ring Mod", "", .goniometer),
                ("MWaveShaper", "", .transfer), ("MAnalyzer", "", .analyzer)]
            kinds += named
            let wrong = kinds.filter { FaceplateDisplay.kind(name: $0.0, path: $0.1, instrument: false) != $0.2 }.map(\.0)
            check(wrong.isEmpty, "every category gets its display (wrong: \(wrong))")
            // Plug-ins that declare nothing specific and have unhelpful names: their parameters decide.
            let byParams: [([String], FaceplateDisplay.Kind?)] = [
                (["Input", "Threshold", "Ratio", "Attack", "Release"], .gainReduction), (["Low Freq", "Low Gain", "High Freq", "High Gain"], .response),
                (["Decay", "Size", "Pre-Delay", "Mix"], .history), (["Time", "Feedback", "Mix"], .history),
                (["Rate", "Depth", "Feedback", "Delay"], .goniometer), (["Drive", "Tone", "Output"], .transfer),
                (["Pitch", "Mix"], .analyzer), (["Gain", "Pan"], .vu), (["Foo", "Bar"], nil)]
            let paramWrong = byParams.filter { FaceplateDisplay.kind(parameters: $0.0) != $0.1 }.map { $0.0.joined(separator: "/") }
            check(paramWrong.isEmpty, "parameter names choose the display when nothing else says (wrong: \(paramWrong))")
            check(FaceplateDisplay.kind(name: "Couture", path: "", instrument: false, declared: ["Fx"], parameters: ["Attack", "Sustain", "Threshold", "Ratio"])
                  == .gainReduction, "a plug-in declaring only Fx is sorted by its parameters")
            // EQ bands from parameter names alone (any plug-in), including repeated names and graphic EQs.
            func P(_ id: UInt32, _ t: String, _ steps: Int32 = 0) -> EqBands.Param { EqBands.Param(id: id, title: t, steps: steps, readOnly: false) }
            let nova = EqBands.find([P(1, "Band 1 selected", 1), P(2, "Band 1 Active", 1), P(3, "Band 1 Gain"), P(4, "Band 1 Q"), P(5, "Band 1 Frequency"),
                                     P(6, "Band 1 Threshold"), P(7, "Band 2 Gain"), P(8, "Band 2 Frequency"), P(9, "HP Frequency"), P(10, "HP Active", 1)])
            check(nova.count == 3 && nova[0] == EqBand(label: "1", freq: 5, gain: 3, enable: 2, q: 4) && nova[1].gain == 7 && nova[2].gain == nil && nova[2].enable == 10,
                  "EQ bands are found by name: frequency with its gain, on switch and Q (\(nova))")
            let nband = EqBands.find([P(1, "Global Gain"), P(2, "Bypass", 1), P(3, "Frequency"), P(4, "Gain"), P(5, "Bypass", 1), P(6, "Frequency"), P(7, "Gain")])
            check(nband.count == 2 && nband[1].freq == 6 && nband[1].gain == 7 && nband[1].enable == 5 && nband[1].enableInverted,
                  "bands with repeated names pair by position, and a Bypass switch counts inverted")
            let graphic = EqBands.find((0..<10).map { P(UInt32($0), String(format: "%.1f Hz", 20 * pow(2, Double($0)))) })
            check(graphic.count == 10 && graphic[3].freq == nil && graphic[3].fixedHz == 160 && graphic[3].gain == 3, "graphic EQ sliders are fixed-frequency gain bands")
            check(EqBands.find([P(1, "LFO Rate"), P(2, "Crossover Freq"), P(3, "Mix")]).isEmpty, "crossovers and LFOs are not EQ bands")
            check(EqBands.hz("1.20 kHz") == 1200 && EqBands.hz("80 Hz") == 80 && EqBands.hz("2,5k") == 2500 && EqBands.db("-4.5 dB") == -4.5 && EqBands.db("+3") == 3,
                  "frequency and gain value texts parse")
            check(FaceplateDisplay.kind(parameters: ["Band 1 Gain", "Band 1 Frequency", "Band 1 Threshold", "Band 1 Ratio", "Band 1 Split", "Band 2 Gain", "Band 2 Frequency",
                                                     "Band 3 Gain", "Band 3 Frequency"]) == .response, "a dynamic EQ gets the EQ screen, not a compressor meter")
            FaceplateDisplay.setOverride("Mystery Box", .goniometer)
            check(FaceplateDisplay.kind(name: "Mystery Box", path: "", instrument: false) == .goniometer, "an owner's display choice wins and is remembered")
            FaceplateDisplay.setOverride("Mystery Box", nil)
            check(MovingCoilMeter.position(3) == 1 && abs(MovingCoilMeter.position(0) - 0.708) < 0.001
                  && abs(MovingCoilMeter.position(-20) - 0.0708) < 0.001, "the VU scale is proportional to voltage (0 VU about two-thirds across)")
            let gr = MovingCoilMeter(mode: .gainReduction)
            gr.update(reported: 6, inRms: 0, outRms: 0)
            check(abs(gr.reductionDb - 6) < 1e-9, "a reported reduction drives the needle")
            gr.update(reported: nil, inRms: 0.5, outRms: 0.5); gr.update(reported: nil, inRms: 0.5, outRms: 0.25)
            check(abs(gr.reductionDb - 6.02) < 0.1, "otherwise the reduction is measured through the plug-in (\(gr.reductionDb) dB)")
            let vu = MovingCoilMeter(mode: .output)
            vu.update(rms: Float(pow(10, -18.0 / 20)))
            check(abs(vu.levelVu) < 0.01, "an output VU reads 0 VU at −18 dBFS RMS")
            let gonio = GoniometerScreen()
            let sine = (0..<1_024).map { Float(sin(Double($0) * 0.07)) * 0.5 }
            gonio.push(left: sine, right: sine)
            check(gonio.correlation > 0.99, "a mono signal reads +1 correlation")
            gonio.push(left: sine, right: sine.map { -$0 }); for _ in 0..<12 { gonio.push(left: sine, right: sine.map { -$0 }) }
            check(gonio.correlation < -0.9, "an out-of-phase signal reads −1 (\(gonio.correlation))")
            let history = HistoryScreen()
            history.push(inRms: 0, outRms: 0.1)
            check(abs(history.latest.output + 20) < 0.01 && history.latest.input == -90, "the history screen records output energy after the input stops")
            let transfer = TransferScreen()
            transfer.push(input: sine, output: sine.map { tanh(3 * $0) })
            check(transfer.pointCount == 512, "the transfer screen plots output against input")
            Faceplate.showMeters = false
            check(delay.inMeter.isHidden && delay.outMeter.isHidden, "Settings can turn the device meters off")
            Faceplate.showMeters = true
            check(!delay.inMeter.isHidden, "and on again")
            UserDefaults.standard.removeObject(forKey: "deviceMeters")
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
        // Chain order: Move Right from the device menu, then undo; a browser drop inserts at the drop position.
        let order0 = s.track(track)?.plugins.map(\.id) ?? []
        guard let delay = panel.devices.first else { return check(false, "devices for chain order") }
        delay.onMove?(1)
        check(s.track(track)?.plugins.map(\.id) == [order0[1], order0[0]] && s.engine.undoName == "Move Plug-in", "Move Right reorders the chain (one undo step)")
        _ = perform("Undo"); panel.rebuild()
        check(s.track(track)?.plugins.map(\.id) == order0, "undo restores the order")
        check(delay.deviceMenu().items.contains { $0.title.hasPrefix("Move Left") && !$0.isEnabled }, "the first unit can't move left")
        panel.onDropPlugin?("au:aufx:dist:appl", track, 1)
        let afterDrop = s.track(track)?.plugins ?? []
        check(afterDrop.count == 3 && afterDrop[1].name == "AUDistortion" && s.engine.undoName == "Add Plug-in",
              "dropping a plug-in between two units inserts it there (\(afterDrop.map(\.name)))")
        _ = perform("Undo"); panel.rebuild()
        check(s.track(track)?.plugins.map(\.id) == order0, "undo removes the dropped plug-in")
        // EQ screen: a band handle drags its band (Dalnok Channel EQ, with real mouse events on the screen).
        if !Analog.on, let eqSlot = try? s.addPlugin(track, path: "dalnok:channel-eq") {
            panel.rebuild(); panel.layoutSubtreeIfNeeded()
            if let eq = panel.devices.first(where: { $0.slot == eqSlot }), let screen = eq.display as? ResponseScreen {
                screen.display()
                let freqBefore = eq.current(17).map(\.value) ?? -1 // Peak 3 Frequency
                if let i = screen.markers.firstIndex(where: { $0.label == "5" }) {
                    screen.display()
                    let m = screen.markers[i]
                    let plot = screen.bounds.insetBy(dx: 6, dy: 7)
                    let at = CGPoint(x: plot.minX + plot.width * CGFloat(log10(m.hz / 20) / 3), y: plot.midY - plot.height / 2 * CGFloat((m.db ?? 0) / ResponseScreen.range))
                    let to = CGPoint(x: at.x + 30, y: at.y - 20)
                    screen.mouseDown(with: mouse(.leftMouseDown, screen.convert(at, to: nil)))
                    screen.mouseDragged(with: mouse(.leftMouseDragged, screen.convert(to, to: nil)))
                    screen.mouseUp(with: mouse(.leftMouseUp, screen.convert(to, to: nil)))
                    let freqAfter = eq.current(17).map(\.value) ?? -1, gain = eq.current(18).flatMap { EqBands.db(fixedString($0.display)) } ?? 0
                    check(freqAfter > freqBefore && gain > 0.5, "dragging an EQ handle on the screen moves its band (freq \(freqBefore) → \(freqAfter), gain \(gain) dB, screen \(screen.frame), at \(at))")
                } else { check(false, "Channel EQ's screen shows its band handles (\(screen.markers.map(\.label)))") }
            } else { check(false, "Channel EQ gets a response screen") }
            s.removePlugin(track, eqSlot); panel.rebuild()
        }
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
        e.seek(Int64(e.sampleRate * 60 / 96 * 3) + Int64(e.sampleRate * 60 / 96)) // bar 2, beat 2
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
