// End-to-end UI self-test: drives real menu items (through the responder
// chain) and synthesized mouse gestures, then verifies the engine model.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class SelfTest {
    static var running = false
    let app: AppDelegate
    let files: [URL]
    let workdir: URL
    private var failures = 0
    /// Preferences the test changes; all are restored at the end so a run never alters the owner's settings.
    private static let restoredKeys = ["copyAudioOnSave", "comingFrom", "onboardingDone", "recordingInputUID", "rulerBarsAndBeats", "metronome", "showDevicePanel"]
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
        check(s.tracks[0].clips.count == 2, "split made 2 clips")
        check(menuItem("Undo")?.title == "Undo Split at Playhead", "undo title is \"\(menuItem("Undo")?.title ?? "-")\"")
        check(perform("Undo"), "menu Edit > Undo")
        check(s.tracks[0].clips.count == 1 && s.tracks[0].clips[0].length == first.length, "undo restored the clip")
        check(perform("Redo"), "menu Edit > Redo")
        check(s.tracks[0].clips.count == 2, "redo re-split")
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
        check(e.undoName == "Move Clip", "drag is one undo step (\(e.undoName))")
        _ = perform("Undo")
        check(s.clip(first.id)?.start == 0, "undo returns clip to 0")

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
        w.timeline.selectedClip = first.id
        e.seek(s.clip(first.id)!.start + s.clip(first.id)!.length / 2)
        await wait(0.3)
        let before = s.tracks[0].clips.count
        w.palette.runSelected()
        check(!w.palette.isVisible, "palette closes after running")
        check(s.tracks[0].clips.count == before + 1, "palette ran Split at Playhead")
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
        check(w.headers.rows.contains { $0.gain.meterDb > -60 }, "gain halo receives live track level")
        e.pause()
        check(master.0 > -60, String(format: "master meter live (%.1f dBFS)", master.0))
        check(trackLevels.contains { $0 > -60 }, "track meters live (\(trackLevels.map { Int($0) }) dBFS)")
        await wait(0.05) // one UI tick sees the stop
        let litAtStop = w.headers.rows.filter { $0.gain.release != nil }.count
        await wait(RotaryKnob.meterReleaseSeconds + 0.1)
        let after = w.headers.rows.map(\.gain.meterDb)
        check(litAtStop > 0 && after.allSatisfy { $0 <= -60 },
              "gain rings all go dark together after stop (\(litAtStop) lit at stop; \(after.map { Int($0) }) dB after \(RotaryKnob.meterReleaseSeconds) s)")
        do { // Exact timing: a loud and a quiet ring are each halfway at half the release time, and both empty at the end.
            let loud = RotaryKnob(frame: NSRect(x: 0, y: 0, width: 30, height: 30)), quiet = RotaryKnob(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
            for (k, db) in [(loud, Float(-3)), (quiet, Float(-45))] { k.showsMeter = true; k.updateMeter(db); k.transportChanged(playing: false) }
            let t0 = loud.release?.start ?? -1, q0 = quiet.release?.start ?? -1
            check(t0 >= 0 && q0 >= 0, "ring release starts on stop")
            let half = RotaryKnob.meterReleaseSeconds / 2
            loud.updateMeter(-15, now: t0 + half); quiet.updateMeter(-57, now: q0 + half) // the meter's own 24 dB/s fall is ignored
            let mid = (loud.meterDb, quiet.meterDb)
            let midScale = loud.faceScale, expected = RotaryKnob.revealScale + (1 - RotaryKnob.revealScale) * 0.5
            loud.updateMeter(-22, now: t0 + 2 * half); quiet.updateMeter(-120, now: q0 + 2 * half)
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
        let t0 = s.tracks[0].id
        w.headers.select(t0)
        check(perform("Solo Track"), "menu Track > Solo Track")
        check(s.track(t0)?.solo == true, "track soloed")
        _ = perform("Solo Track")
        check(s.track(t0)?.solo == false, "track unsoloed")
        check(perform("Move Track Down"), "menu Track > Move Track Down")
        check(s.tracks[1].id == t0, "track moved down")
        _ = perform("Undo")
        if let row = w.headers.row(t0), s.tracks.count >= 2 {
            let target = w.headers.convert(CGPoint(x: 20, y: Theme.rulerHeight + Theme.trackHeight * 2), to: nil)
            w.headers.dragUpdate(row: row, windowPoint: target)
            w.headers.dragEnd(row: row)
            check(s.tracks[1].id == t0, "drag header reorders (now index \(s.tracks.firstIndex { $0.id == t0 } ?? -1))")
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
        check(typing && !consumed && !e.isPlaying,
              "Space types into the rename field instead of starting playback (typing=\(typing), menu consumed=\(consumed))")
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
        w.settings.themePicker.selectItem(at: 1)
        _ = NSApp.sendAction(#selector(SettingsController.themeChanged(_:)), to: w.settings, from: w.settings.themePicker)
        check(Theme.preferredStyle == .warmAnalog, "settings saves the Warm Analog theme")
        let otherStyle = Theme.activeStyle == .graphite ? 1 : 0
        w.settings.themePicker.selectItem(at: otherStyle)
        _ = NSApp.sendAction(#selector(SettingsController.themeChanged(_:)), to: w.settings, from: w.settings.themePicker)
        check(w.settings.appearanceNote.stringValue.contains("Reopen"), "settings explains when the new theme applies")
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
        let track = s.tracks[0].id
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

        // Interrupted take: pausing ends it with an explanation; nothing is placed.
        check(perform("Record", exact: true) && e.isRecording, "second take starts")
        for _ in 0..<5 { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        e.pause()
        for _ in 0..<3 { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        w.updateRecording()
        check(!e.isRecording && w.lastRecordingProblem == "The take was interrupted", "interrupted take is reported (\(w.lastRecordingProblem ?? "-"))")
        check(s.track(track)?.clips.count == clipsBefore + 1, "interrupted take is not placed")

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
        if Analog.on {
            panel.layoutCables()
            check(panel.cableCount == 3, "Warm Analog patches IN → AUDelay → AUPeakLimiter → OUT with \(panel.cableCount) cables")
        }
        guard let delay = panel.devices.first else { return }
        let names = delay.knobs.map { $0.label.stringValue }
        check(delay.knobs.count == 4 && names.contains("Dry/Wet Mix"), "controller shows AUDelay's parameters (\(names))")
        if let lim = panel.devices.last {
            let limNames = lim.knobs.map { $0.label.stringValue }
            check(lim.knobs.count == lim.controlIds.count && !limNames.contains(""), "every limiter control has a named knob (\(limNames))")
        }
        // Turning a knob changes the plug-in.
        let mix = delay.knobs[0]
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
        _ = s.setTempo(96, 3, 4)
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
