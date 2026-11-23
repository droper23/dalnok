// Self-test steps (Plugins), split out of SelfTest.swift (A-18). The harness (check, perform, mouse) lives there.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import DalnokEngine

extension SelfTest {
    // MARK: Markers, duplicate track, zoom to selection, vertical zoom

    /// ADR-0013: an opened project is shown before its plug-ins load; they load one per run-loop turn with progress,
    /// Stop leaves the rest unloaded with their settings, and the track menu loads one later.
    func deferredPluginLoading() async {
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
    func slowIsolatedPluginLoading() async {
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
    func isolatedPluginEditors() async {
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
            // The unit's one Open button shows the plug-in's own window, and only that.
            w.openPluginWindow(track: track, slot: slot)
            await wait(0.4)
            var ed = DalnokPluginEditorWindow()
            _ = dalnok_plugin_editor_window(e.handle, slot, &ed)
            check(ed.open && ed.visible && ed.process_id != getpid() && ed.process_id > 0 && w.pluginWindows[slot] == nil,
                  "\(label): Open shows the plug-in's own window in its host (pid \(ed.process_id)) and no other window")
            let screen = NSScreen.screens.first?.visibleFrame ?? .zero
            check(screen.contains(CGRect(x: ed.x, y: ed.y, width: ed.width, height: ed.height).insetBy(dx: 1, dy: 1)),
                  "\(label): the plug-in's window is on screen (\(Int(ed.x)), \(Int(ed.y)) \(Int(ed.width)) × \(Int(ed.height)))")
            // Its title bar's Controls arrives as DALNOK_EDITOR_SHOW_CONTROLS through the key ring (the button itself
            // is in the host's process; the engine test presses it there). Dalnok then shows its controls window.
            w.openPluginControls(track: track, slot: slot)
            guard let pw = w.pluginWindows[slot] else { check(false, "\(label): Controls opens Dalnok's controls"); continue }
            check(pw.isolated && pw.tabs.selectedSegment == 1 && pw.tabs.isEnabled(forSegment: 0) && pw.window?.titlebarAccessoryViewControllers.isEmpty == false,
                  "\(label): Controls shows every parameter, with Plug-in in the title bar to go back to the GUI")
            pw.tabs.selectedSegment = 0; pw.tabChanged(pw.tabs)
            await wait(0.2)
            check(pw.tabs.selectedSegment == 1 && pw.hostEditorOpen, "\(label): Plug-in brings the plug-in's own window forward")
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
                check(hidden && ed.visible, "AUDelay: the editor hides while Finder is active and returns with Dalnok (hidden \(hidden), back \(ed.visible))", needs: .frontmost)
            }
            pw.window?.performClose(nil)
            await wait(0.2)
            _ = dalnok_plugin_editor_window(e.handle, slot, &ed)
            check(ed.open && w.pluginWindows[slot] == nil, "\(label): closing the controls leaves the plug-in's own window open")
            dalnok_plugin_close_editor(e.handle, slot)
            await wait(0.2)
            _ = dalnok_plugin_editor_window(e.handle, slot, &ed)
            check(!ed.open && !ed.visible, "\(label): its own close closes it")
            _ = dalnok_plugin_remove(e.handle, track, slot)
            s.refresh()
        }
        frontBefore?.activate()
    }

    /// DALNOK_REAL_INPUT=1: a real click in an isolated editor gives its window the keyboard; a real Space then still
    /// plays and stops Dalnok (keys the editor does not use are passed back, API 39).
    func spaceThroughIsolatedEditor(_ ed: DalnokPluginEditorWindow) async {
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
        check(!wasPlaying && started && stopped, "Space pressed in an isolated editor's window plays and stops Dalnok", needs: .frontmost)
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), "clicking in the editor leaves Dalnok active", needs: .frontmost)
    }

    /// DALNOK_REAL_INPUT=1 (unlocked screen, Accessibility): real OS-level clicks and typing reach an isolated editor.
    /// Clicks AUDelay's Dry/Wet value field in the host's window, types 25 and Return, and reads the parameter back.
    /// Dalnok is made frontmost first, so a key that missed the editor would land in Dalnok, never another app.
    func typeIntoIsolatedEditor(_ slot: Int32, _ ed: DalnokPluginEditorWindow) async {
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

    /// True when real input may be posted: asked for, the screen unlocked, and Dalnok frontmost (input goes to
    /// whatever application is in front, so a missed target lands in Dalnok, never another app).
    func realInputReady(_ what: String) async -> Bool {
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
    func screenPoint(_ view: NSView, _ p: NSPoint) -> CGPoint {
        guard let win = view.window else { return .zero }
        let q = win.convertPoint(toScreen: view.convert(p, to: nil))
        return CGPoint(x: q.x, y: (NSScreen.screens.first?.frame.height ?? 0) - q.y)
    }

    /// This branch's work driven by real mouse and keyboard events: a clip drag redraws one lane correctly and ⌘Z / ⇧⌘Z
    /// move it back and forth (A-03 deltas); Space plays a streamed file and a ruler click seeks into blocks that were
    /// never resident (A-09).
    func realInputChecks() async {
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

    /// Audio > Plug-ins lists what is installed from metadata (no plug-in code is loaded by the self-test).
    func pluginManager() {
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
    func hostedPlugins() {
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
    /// Folding a unit (API 40) and the chain's arrival, departure and fold animations, with motion on.
    func deviceFolding() async {
        guard let track = s.tracks.first(where: { !$0.isInstrument })?.id else { return check(false, "an audio track exists") }
        let saved = Motion.override; Motion.override = true; defer { Motion.override = saved }
        w.headers.select(track)
        let panel = w.devicePanel
        let delay = (try? s.addPlugin(track, path: "au:aufx:dely:appl")) ?? 0
        panel.rebuild()
        await wait(0.6)
        let before = panel.devices.first { $0.slot == delay }?.frame.width ?? 0
        let limiter = (try? s.addPlugin(track, path: "au:aufx:lmtr:appl")) ?? 0
        panel.rebuild()
        let arriving = panel.devices.first { $0.slot == limiter }
        check(arriving?.transitioning == true, "an added plug-in animates into the chain")
        check(panel.devices.first { $0.slot == delay }?.transitioning == false, "units already in the chain are kept, not rebuilt")
        await wait(0.6)
        check(arriving?.transitioning == false && (arriving?.frame.width ?? 0) >= 150, "it settles at full width (\(arriving?.frame.width ?? 0))")
        // Fold from the unit's menu: one undo step, a narrow strip, no change to the audio graph.
        guard let unit = panel.devices.first(where: { $0.slot == delay }) else { return check(false, "AUDelay's unit") }
        if let item = unit.deviceMenu().items.first(where: { $0.title == "Fold" }), let action = item.action { _ = (item.target as? NSObject)?.perform(action, with: item) }
        panel.rebuild()
        check(s.pluginFolded(track, delay) && s.engine.undoName == "Fold Plug-in", "Fold folds the plug-in as one undo step")
        check(unit.folded && unit.transitioning, "the unit animates to its folded strip")
        await wait(0.6)
        check(abs(unit.frame.width - FoldStrip.width) < 1 && unit.strip.superview === unit && !unit.transitioning,
              "folded, the unit is a \(FoldStrip.width) pt strip (\(unit.frame.width))")
        check(unit.strip.name == "AUDelay", "the strip keeps the plug-in's name")
        // On/off stays available folded: the strip's switch bypasses (one undo step) without unfolding, and back on.
        unit.strip.layoutSubtreeIfNeeded()
        check(!unit.strip.power.isHidden && unit.strip.power.isEnabled && unit.strip.power.superview === unit.strip,
              "the folded strip has an on/off switch")
        unit.strip.power.performClick(nil)
        panel.rebuild()
        check(s.pluginBypassed(track, delay) && s.engine.undoName == "Bypass Plug-in" && unit.folded && !unit.strip.engaged,
              "the strip's switch bypasses the plug-in and it stays folded")
        unit.strip.power.performClick(nil)
        panel.rebuild()
        check(!s.pluginBypassed(track, delay) && unit.folded && unit.strip.engaged, "pressing it again turns it back on")
        // A real click on the switch (not elsewhere on the strip) toggles rather than unfolds.
        let sw = unit.strip.convert(CGPoint(x: unit.strip.powerRect.midX, y: unit.strip.powerRect.midY), to: nil)
        check(unit.strip.hitTest(unit.strip.superview!.convert(sw, from: nil)) === unit.strip.power, "the switch takes clicks on it")
        unit.strip.power.performClick(nil); panel.rebuild(); _ = perform("Undo"); panel.rebuild()
        check(!s.pluginBypassed(track, delay) && unit.folded, "undo turns it back on, still folded")
        // Clicking the strip unfolds it; undo folds it again.
        let mid = unit.strip.convert(CGPoint(x: unit.strip.bounds.midX, y: unit.strip.bounds.midY), to: nil)
        unit.strip.mouseDown(with: mouse(.leftMouseDown, mid)); unit.strip.mouseUp(with: mouse(.leftMouseUp, mid))
        panel.rebuild()
        await wait(0.6)
        check(!s.pluginFolded(track, delay) && !unit.folded && abs(unit.frame.width - before) < 2,
              "clicking the strip unfolds it to its width (\(unit.frame.width) vs \(before))")
        check(perform("Undo") && s.pluginFolded(track, delay), "undo folds it again")
        panel.rebuild(); await wait(0.6)
        check(unit.folded && abs(unit.frame.width - FoldStrip.width) < 1, "the panel follows undo")
        _ = perform("Undo"); panel.rebuild(); await wait(0.6)
        // Removing a plug-in: its unit leaves with an animation while the chain closes up.
        s.removePlugin(track, limiter)
        panel.rebuild()
        check(panel.devices.map(\.slot) == [delay] && panel.leaving.count == 1, "a removed unit leaves the chain at once and animates out")
        await wait(0.7)
        check(panel.leaving.isEmpty && arriving?.superview == nil, "it is gone once its animation ends")
        s.removePlugin(track, delay)
        panel.rebuild(); await wait(0.5)
        check(panel.devices.isEmpty && panel.leaving.isEmpty, "the chain is empty again")
    }

    func devicePanel() {
        guard let track = s.tracks.first(where: { !$0.isInstrument })?.id else { return check(false, "an audio track exists") }
        w.headers.select(track)
        let slot = (try? s.addPlugin(track, path: "au:aufx:dely:appl")) ?? 0
        check(slot != 0, "AUDelay loads as an insert")
        let limiter = (try? s.addPlugin(track, path: "au:aufx:lmtr:appl")) ?? 0
        let panel = w.devicePanel
        check(!panel.isHidden && panel.devices.map(\.slot) == [slot, limiter], "device panel shows the track's plug-ins in order")
        check(panel.subviewsDeep.contains { ($0 as? NSButton)?.title.contains("Add Plug-in") == true && !$0.isHiddenOrHasHiddenAncestor },
              "device panel offers Add Plug-in after the chain")
        if (Theme.activeStyle == .warmAnalog) {
            panel.layoutCables()
            check(panel.cableCount == 3, "Warm Analog patches IN → AUDelay → AUPeakLimiter → OUT with \(panel.cableCount) cables")
        }
        // Plug-in parameter automation: the controls' Automate shows the lane; a click adds points.
        w.openPluginControls(track: track, slot: slot)
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
            check((Theme.activeStyle == .warmAnalog) && pedal.controls.count == delay.knobs.count, "Warm Analog shows AUDelay as a pedal with \(pedal.controls.count) controls")
            check(PedalStore.look(delayName) == PedalStore.look(delayName) && PedalLook.random("A#0") != PedalLook.random("B#0"),
                  "a pedal's look is stable for its plug-in and differs between plug-ins")
            panel.layoutSubtreeIfNeeded()
            if let lim = panel.devices.last?.pedal {
                check(lim.controls.count < pedal.controls.count ? lim.frame.width < pedal.frame.width : lim.frame.width >= pedal.frame.width,
                      "pedal size follows the number of controls (\(lim.controls.count): \(lim.frame.width) pt, \(pedal.controls.count): \(pedal.frame.width) pt)")
            }
            // The readout window: under the controls, clear of the name and footswitch; it shows a turned control's
            // name and value, and the trace or reduction otherwise.
            pedal.layoutSubtreeIfNeeded()
            check(!pedal.screen.isHidden && pedal.screen.frame.minY >= (pedal.controls.map(\.frame.maxY).max() ?? 0)
                  && pedal.screen.frame.maxY < pedal.footswitch.frame.minY - 14 && pedal.screen.frame.width > 60,
                  "the pedal has a readout window under its controls (\(pedal.screen.frame))")
            delay.pollMeters(); delay.pollMeters()
            check(pedal.screen.mode == .scope, "AUDelay's window shows its output trace (\(pedal.screen.mode))")
            if let knob = pedal.controls.first {
                knob.onChange?(0.3)
                check(pedal.screen.showingValue && pedal.screen.text.lowercased().contains("dry/wet") && pedal.screen.text.contains("30"),
                      "turning a control shows its name and value in the window (\(pedal.screen.text))")
                _ = perform("Undo"); panel.rebuild()
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
        if !(Theme.activeStyle == .warmAnalog), let eqSlot = try? s.addPlugin(track, path: "dalnok:channel-eq") {
            panel.rebuild(); panel.layoutSubtreeIfNeeded()
            if let eq = panel.devices.first(where: { $0.slot == eqSlot }), let screen = eq.display as? ResponseScreen {
                screen.display()
                let freqBefore = eq.current(17).map(\.value) ?? -1 // Peak 3 Frequency
                if let i = screen.markers.firstIndex(where: { $0.label == "5" }) {
                    screen.display()
                    let m = screen.markers[i]
                    let at = screen.center(of: m) // where the handle is drawn (each theme lays its plot out its own way)
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
        // Dalnok Compressor (built-in): a gain-reduction display, a sidechain menu that keys it from another track
        // (one undo step), and a read-only Gain Reduction meter.
        if let other = s.tracks.first(where: { $0.id != track })?.id, let comp = try? s.addPlugin(track, path: "dalnok:compressor") {
            panel.rebuild(); panel.layoutSubtreeIfNeeded()
            if let unit = panel.devices.first(where: { $0.slot == comp }) {
                check(unit.automaticKind() == .gainReduction, "Dalnok Compressor gets a gain-reduction display (\(unit.automaticKind()))")
                // Atelier: the governor's collar is the threshold; dragging it up raises the threshold.
                if Theme.look.devices == .schematic, let screen = unit.display as? FaceplateScreen {
                    if let rep = screen.bitmapImageRepForCachingDisplay(in: screen.bounds) { screen.cacheDisplay(in: screen.bounds, to: rep) } // draws: places the parts
                    if screen.atelierFigure == .governor, let h = screen.figureHandles.first(where: { $0.role == .threshold }),
                       let id = screen.figureLink?.ids[.threshold] {
                        let before = unit.current(id)?.value ?? -1
                        let to = CGPoint(x: h.point.x, y: h.point.y - 20)
                        screen.mouseDown(with: mouse(.leftMouseDown, screen.convert(h.point, to: nil)))
                        screen.mouseDragged(with: mouse(.leftMouseDragged, screen.convert(to, to: nil)))
                        screen.mouseUp(with: mouse(.leftMouseUp, screen.convert(to, to: nil)))
                        let after = unit.current(id)?.value ?? -1
                        check(after > before + 0.05, "dragging the governor's collar raises the threshold (\(before) → \(after))")
                        unit.set(id, before)
                        // Motion: the governor spins (it holds still under the pointer); its part and key row light together.
                        let a0 = screen.figureAngle
                        screen.advanceFigure(0.1)
                        check(screen.figureAngle > a0, "the governor spins (\(a0) → \(screen.figureAngle))")
                        screen.hoverRole = .threshold
                        let held = screen.figureAngle
                        screen.advanceFigure(0.1)
                        let row = unit.knobs.first { $0.id == id }?.knob as? FaceplateControl
                        check(screen.figureAngle == held && row?.linked == true, "pointing at the collar holds the governor and lights its key row")
                        screen.hoverRole = nil
                        check(row?.linked == false, "and the row goes dark again")
                        row?.onHover?(true)
                        check(screen.highlightRole == .threshold, "pointing at the Threshold row lights the collar")
                        row?.onHover?(false)
                        screen.figureAngle = 0
                    } else { check(false, "Atelier draws the compressor as a governor with a threshold collar (\(String(describing: screen.atelierFigure)))") }
                }
                check(!unit.sidechain.isHidden && unit.sidechain.itemTitles.first == "SC: None" && unit.sidechain.indexOfItem(withTag: Int(other)) > 0,
                      "the compressor shows a sidechain menu with None and the other tracks (\(unit.sidechain.itemTitles))")
                unit.sidechain.selectItem(withTag: Int(other))
                _ = unit.sidechain.sendAction(unit.sidechain.action, to: unit.sidechain.target)
                check(dalnok_plugin_sidechain(s.engine.handle, track, comp) == other && s.engine.undoName == "Sidechain",
                      "choosing a track in the menu keys the compressor from it (undo: \(s.engine.undoName))")
                var gr = DalnokPluginParameter()
                check(dalnok_plugin_parameter(s.engine.handle, comp, 12, &gr) == DALNOK_OK && gr.read_only && fixedString(gr.title) == "Gain Reduction",
                      "the compressor reports a read-only Gain Reduction meter")
                _ = perform("Undo")
                check(dalnok_plugin_sidechain(s.engine.handle, track, comp) == 0, "undo disconnects the sidechain")
            } else { check(false, "Dalnok Compressor appears in the device panel") }
            s.removePlugin(track, comp); panel.rebuild()
        } else { check(false, "Dalnok Compressor inserts on a track") }
        // The panel's top edge resizes it (every theme): taller units, remembered, and back.
        if let comp = try? s.addPlugin(track, path: "dalnok:compressor") {
            panel.rebuild(); w.window?.contentView?.layoutSubtreeIfNeeded()
            // The Inspector marks the plug-ins in view in the device panel (its list, and Atelier's Fig. 3), and the one clicked.
            w.inspector.track = track; w.inspector.reload()
            if let unit = panel.devices.first(where: { $0.slot == comp }) { unit.scrollToVisible(unit.bounds) }
            panel.selectedSlot = comp; panel.reportViewing()
            let mark = w.inspector.insertRows.first { $0.slot == comp }
            let index = s.track(track)?.effects.firstIndex { $0.id == comp }
            check(mark?.inView == true && index.map { w.inspector.figure.inView.contains($0) && w.inspector.figure.focused == $0 } == true,
                  "the Inspector marks the plug-in shown and clicked in the device panel (view \(panel.viewingSlots), comp \(comp), rows \(w.inspector.insertRows.map(\.slot)), fig \(w.inspector.figure.inView), index \(String(describing: index)), hidden \(panel.isHidden))")
            panel.selectedSlot = nil
            let was = DevicePanel.extra, edge = panel.resizeEdge, h0 = panel.frame.height
            edge.onDrag?(edge.currentHeight() + 90); edge.onEnd?()
            w.window?.contentView?.layoutSubtreeIfNeeded()
            let unit = panel.devices.first { $0.slot == comp }
            check(abs(panel.frame.height - (h0 + 90)) < 1 && abs(DevicePanel.extra - (was + 90)) < 1
                  && abs((unit?.frame.height ?? 0) - DevicePanel.unitHeight) < 1,
                  "dragging the device panel's top edge makes it and its units taller (\(h0) → \(panel.frame.height), unit \(unit?.frame.height ?? 0))")
            edge.onDrag?(10); edge.onEnd?()
            w.window?.contentView?.layoutSubtreeIfNeeded()
            check(abs(panel.frame.height - DevicePanel.baseHeight) < 1, "the panel never gets shorter than its base height (\(panel.frame.height))")
            DevicePanel.extra = was; edge.onDrag?(DevicePanel.baseHeight + was); edge.onEnd?()
            s.removePlugin(track, comp); panel.rebuild()
        }
        check(perform("Device Panel") && w.devicePanel.isHidden, "View > Device Panel hides it")
        _ = perform("Device Panel")
        s.removePlugin(track, limiter)
        s.removePlugin(track, slot)
        check(w.devicePanel.devices.isEmpty, "removing the plug-ins clears the panel")
    }
}
