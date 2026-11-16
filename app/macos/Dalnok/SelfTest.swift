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
    private var w: MainWindowController { app.main }
    private var s: Session { app.session }

    init(app: AppDelegate, files: [URL], workdir: URL) {
        self.app = app
        self.files = files
        self.workdir = workdir
    }

    private func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    private func menuItem(_ title: String, in menu: NSMenu? = NSApp.mainMenu, submenuOnly: Bool = false) -> NSMenuItem? {
        for it in menu?.items ?? [] {
            if let sub = it.submenu {
                if submenuOnly && it.title == title { return it }
                sub.update() // runs validateMenuItem, which sets dynamic titles
                if let found = menuItem(title, in: sub, submenuOnly: submenuOnly) { return found }
            } else if !submenuOnly && it.title.hasPrefix(title) {
                return it
            }
        }
        return nil
    }

    /// Fires a menu item exactly as a click would (validation + responder chain).
    private func perform(_ title: String) -> Bool {
        guard let it = menuItem(title), let m = it.menu else { return false }
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
    private func dragClip(_ id: DalnokClipId, zone: String, fraction: CGFloat) {
        guard let c = s.clip(id) else { return check(false, "clip exists") }
        dragClip(id, zone: zone, dx: CGFloat(Double(c.length) / w.timeline.framesPerPoint) * fraction)
    }

    private func dragClip(_ id: DalnokClipId, zone: String, dx: CGFloat) {
        guard let p = w.timeline.windowPoint(ofClip: id, zone: zone) else { return check(false, "clip on screen") }
        w.timeline.mouseDown(with: mouse(.leftMouseDown, p))
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

        // Drag the clip body right: moves (snapped), one undo step.
        dragClip(first.id, zone: "body", fraction: 0.5)
        let moved = s.clip(first.id)!
        check(moved.start > 0, "drag moved clip to \(moved.start)")
        let q = Int64(w.timeline.gridStep() / 4 * e.sampleRate)
        check(q > 0 && moved.start % q == 0, "move snapped to grid (\(q) frames)")
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
        e.pause()
        check(master.0 > -60, String(format: "master meter live (%.1f dBFS)", master.0))
        check(trackLevels.contains { $0 > -60 }, "track meters live (\(trackLevels.map { Int($0) }) dBFS)")

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
        e.pause()
        check(s.track(t0)?.name == "Lead Vox", "renamed track (\(s.track(t0)?.name ?? "-"))")

        // Save, New (via menu), reopen.
        let project = workdir.appendingPathComponent("selftest.dalnok")
        check(w.saveProject(to: project), "save project")
        check(!e.isDirty && w.window?.isDocumentEdited == false, "saved state is clean")
        check(perform("New"), "menu File > New")
        check(s.tracks.isEmpty, "new project is empty")
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

        try? w.snapshot(to: workdir.appendingPathComponent("selftest.png"))
        finish()
    }

    private func finish() {
        print(failures == 0 ? "SELFTEST: PASS" : "SELFTEST: FAIL (\(failures))")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
