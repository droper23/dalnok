// End-to-end UI self-test: drives real menu items (through the responder
// chain) and synthesized mouse gestures, then verifies the engine model.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import DalnokEngine

@MainActor
final class SelfTest {
    static var running = false
    let app: AppDelegate
    let files: [URL]
    let workdir: URL
    var failures = 0
    /// Preferences the test changes; all are restored at the end so a run never alters the owner's settings.
    static let restoredKeys = ["copyAudioOnSave", "comingFrom", "onboardingDone", "recordingInputUID", "latencyOffsets", "latencyChecks", "rulerBarsAndBeats", "metronome", "showDevicePanel", "countIn", "showMixer", "showLauncher", "showLibrary", "showInspector", "libraryWidth", "inspectorWidth", "atelierIllustrated", "automationMode", "pedal.AUDelay", "shortcuts.preset", "shortcuts.overrides", "shortcuts.userPresets"] + PluginLibrary.keys + ["tapeSpeed", "trackHeight", "secondaryClock", "gainRingLevel", "isolatePlugins", "clipBounce"] + Faceplate.preferenceKeys
    let previousPreferences: [String: Any]
    var w: MainWindowController { app.main }
    var s: Session { app.session }

    init(app: AppDelegate, files: [URL], workdir: URL) {
        self.app = app
        self.files = files
        self.workdir = workdir
        previousPreferences = Self.restoredKeys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
    }

    func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    /// What a check needs from the machine rather than from Dalnok (A-18). When it fails and that need was not met,
    /// it is reported as SKIP with the reason and does not fail the run, so failures are attributable to the product.
    enum Environment: String {
        case frontmost = "Dalnok could not become the active application (screen locked, or someone is using another app)"
        case fullKeyboardAccess = "Keyboard navigation is off in System Settings, so Tab skips buttons and menus in every app"
        @MainActor var met: Bool {
            switch self {
            case .frontmost: NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
            case .fullKeyboardAccess: NSApp.isFullKeyboardAccessEnabled
            }
        }
    }
    private(set) var environmentSkips = 0
    func check(_ ok: Bool, _ what: String, needs env: Environment) {
        if !ok && !env.met {
            environmentSkips += 1
            print("SKIP  \(what) [environment: \(env.rawValue)]")
            return
        }
        check(ok, what)
    }

    func menuItem(_ title: String, in menu: NSMenu? = NSApp.mainMenu, submenuOnly: Bool = false, exact: Bool = false) -> NSMenuItem? {
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
    func perform(_ title: String, exact: Bool = false) -> Bool {
        guard let it = menuItem(title, exact: exact), let m = it.menu else { return false }
        m.update()
        guard it.isEnabled else { return false }
        m.performActionForItem(at: m.index(of: it))
        s.refresh(onDisplayTick: true) // simulate a display tick between scripted menu actions
        return true
    }

    func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: 1)!
    }

    /// Drags by a fraction of the clip's on-screen width (works for any clip length).
    func dragClip(_ id: DalnokClipId, zone: String, fraction: CGFloat, mods: NSEvent.ModifierFlags = []) {
        guard let c = s.clip(id) else { return check(false, "clip exists") }
        dragClip(id, zone: zone, dx: CGFloat(Double(c.length) / w.timeline.framesPerPoint) * fraction, mods: mods)
    }

    func dragClip(_ id: DalnokClipId, zone: String, dx: CGFloat, mods: NSEvent.ModifierFlags = []) {
        guard let p = w.timeline.windowPoint(ofClip: id, zone: zone) else { return check(false, "clip on screen") }
        w.timeline.mouseDown(with: mouse(.leftMouseDown, p, mods))
        for k in 1...10 { w.timeline.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: p.x + dx * CGFloat(k) / 10, y: p.y))) }
        w.timeline.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: p.x + dx, y: p.y)))
    }

    /// DALNOK_SELFTEST_WAIT_SCALE shortens (or lengthens) every fixed pause, to find the ones a step really needs.
    static let waitScale = ProcessInfo.processInfo.environment["DALNOK_SELFTEST_WAIT_SCALE"].flatMap(Double.init) ?? 1
    func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds * Self.waitScale)) }
    /// Waits until `condition` holds (checked every 10 ms), at most `timeout` seconds: as quick as the app is, and
    /// patient when the machine is busy (parallel runs). Returns whether it held.
    /// After a seek: until the audio thread has applied it (the playhead within a quarter second of `frame`, so it also
    /// holds while playing).
    func settle(_ e: Engine, _ frame: Int64) async {
        await waitUntil { abs(e.position - frame) < Int64(e.sampleRate) / 4 }
    }
    @discardableResult
    func waitUntil(timeout: Double = 2, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() { if Date() > end { return false }; try? await Task.sleep(for: .milliseconds(10)) }
        return true
    }

    func run() {
        Self.running = true
        MainWindowController.copyAudioOnSave = true
        // A known layout whatever the owner left open (the mixer would squeeze the tracks to a sliver); restored at the end.
        if MainWindowController.showMixer { w.toggleMixer(nil) }
        if MainWindowController.showLauncher { w.toggleLauncher(nil) }
        if MainWindowController.showLibrary { w.toggleLibrary(nil) }
        if MainWindowController.showInspector { w.toggleInspector(nil) }
        UserDefaults.standard.removeObject(forKey: "secondaryClock")
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        s.importFiles(files) { [self] in Task { await steps() } }
    }

    func steps() async {
        let e = s.engine
        if ProcessInfo.processInfo.environment["DALNOK_A11Y_ONLY"] != nil { await accessibilityPass(); return finish() }
        // Fast iteration on one area (never a substitute for the full run): panels, plugins.
        switch ProcessInfo.processInfo.environment["DALNOK_SELFTEST_ONLY"] {
        case "panels": await sidePanels(); return finish()
        case "plugins": devicePanel(); return finish()
        default: break
        }
        check(s.tracks.count == files.count, "import \(files.count) files -> \(s.tracks.count) tracks")
        check(e.undoName.hasPrefix("Import"), "import is one undo step (\(e.undoName))")
        guard let first = s.tracks.first?.clips.first else { return finish() }

        // Split via menu at 1 s.
        w.timeline.selectedClip = first.id
        e.seek(Int64(e.sampleRate))
        await settle(e, Int64(e.sampleRate)) // under load a fixed pause could split at 0 (a no-op), and the Undos below would undo the import
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
        guard let moved = s.clip(first.id) else { check(false, "the dragged clip still exists (undo \(e.undoName))"); return finish() }
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
            if Theme.look.controls == .glass || Theme.look.controls == .drafted {
                // Glass and drafted dials never cover their ring: the face stays put while the ring falls.
                check(abs(midScale - 0.7) < 0.001 && abs(loud.faceScale - 0.7) < 0.001, String(format: "dial face stays clear of the ring (%.3f, end %.3f)", midScale, loud.faceScale))
            } else if !(Theme.activeStyle == .warmAnalog) {
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
        let quiet = s.soloSilenced()
        let plain = s.allTracks.filter { t in t.id != t0 && t.output == 0 && t.stack == 0 && !s.allTracks.contains { $0.output == t.id || $0.stack == t.id } }
        check(!quiet.contains(t0) && plain.allSatisfy { quiet.contains($0.id) },
              "a solo silences the other tracks, and the arrangement fades their clips (\(quiet.count) silenced of \(s.allTracks.count))")
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
        let panelsWere = (MainWindowController.showLibrary, MainWindowController.showInspector)
        if !MainWindowController.showLibrary { w.toggleLibrary(nil) }
        if !MainWindowController.showInspector { w.toggleInspector(nil) }
        check(perform("New"), "menu File > New")
        check(s.tracks.isEmpty, "new project is empty")
        check(!w.emptyState.isHidden && w.timeline.isHidden, "empty state shown for an empty project")
        w.window?.contentView?.layoutSubtreeIfNeeded()
        check(w.library.isHidden && w.inspector.isHidden && w.library.frame.width < 1 && w.inspector.frame.width < 1
              && MainWindowController.showLibrary && MainWindowController.showInspector && !w.transport.libraryButton.isEnabled,
              "the start page hides the Library and Inspector but remembers them")
        check(menuItem("Library", exact: true).map { !w.validateMenuItem($0) } ?? false, "View > Library is off on the start page")
        await startPage()
        let opened = await withCheckedContinuation { cont in w.openProject(project) { cont.resume(returning: $0) } }
        check(opened, "background open completed")
        w.window?.contentView?.layoutSubtreeIfNeeded()
        check(!w.library.isHidden && !w.inspector.isHidden && w.transport.libraryButton.isEnabled, "the panels come back with the project")
        if !panelsWere.0 { w.toggleLibrary(nil) }
        if !panelsWere.1 { w.toggleInspector(nil) }
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
        let flac = workdir.appendingPathComponent("selftest.flac")
        var flacMedia: OpaquePointer?
        check(w.exportMix(to: flac, format: DALNOK_FORMAT_FLAC) && dalnok_media_load(flac.path, e.sampleRate, &flacMedia, nil, 0) == DALNOK_OK
              && dalnok_media_frames(flacMedia) == s.length, "export as FLAC decodes to the session length")
        if let flacMedia { dalnok_media_release(flacMedia) }
        check(Engine.exportFormats.count == 7 && Engine.exportFormats.allSatisfy { UTType(filenameExtension: $0.ext) != nil },
              "the export panel offers seven formats, each a known file type")
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
        await clipEditorSteps()
        deadControls()
        await sidePanels()
        await tapeMachine()
        await markersAndTrackTools()
        await partialTimelineRedraw()
        await realInputChecks()
        await deferredPluginLoading()
        await slowIsolatedPluginLoading()
        await isolatedPluginEditors()
        try? w.snapshot(to: workdir.appendingPathComponent("selftest.png"))
        await migrationSteps()
        await accessibilityPass()
        // Settings: exercise the menu, appearance selection, and project preference.
        let oldTheme = UserDefaults.standard.object(forKey: "appearanceStyle")
        let oldVariant = UserDefaults.standard.object(forKey: "appearanceVariant")
        let oldCopy = MainWindowController.copyAudioOnSave
        check(perform("Settings…"), "Dalnok > Settings opens")
        check(w.settings.window?.isVisible == true, "settings window is visible")
        // ADR-0014: Settings > Plug-ins > Safety runs plug-ins loaded afterwards in their own processes.
        let isolation = w.settings.isolatePlugins
        if isolation.isEnabled, let action = isolation.action, let track = s.tracks.first?.id {
            let saved = UserDefaults.standard.object(forKey: "isolatePlugins")
            UserDefaults.standard.removeObject(forKey: "isolatePlugins")
            check(Engine.isolatePlugins, "Safety is on by default (nothing chosen yet)")
            UserDefaults.standard.set(saved, forKey: "isolatePlugins")
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
            check(UserDefaults.standard.object(forKey: "isolatePlugins") as? Bool == false && !Engine.isolatePlugins,
                  "turning Safety off is remembered (the off switch survives the new default)")
            isolation.state = .on; _ = NSApp.sendAction(action, to: isolation.target, from: isolation)
            check(s.engine.pluginHost == Engine.pluginHostPath, "Safety back on")
        } else { check(false, "the Safety setting is available (dalnok-plughost next to the app)") }
        var shown: [SettingsController.Pane] = []
        for pane in SettingsController.Pane.allCases { w.settings.show(pane); if w.settings.pane == pane { shown.append(pane) } }
        w.settings.show(.shortcuts)
        check(shown.count == 9 && w.settings.pane == .shortcuts && w.shortcutsEditor.table.window === w.settings.window,
              "Settings has nine pages, keyboard shortcuts included (\(shown.count) shown)")
        w.settings.search.stringValue = "monitoring"
        w.settings.searchChanged(nil)
        check(w.settings.matches == [.recording] && w.settings.pane == .recording, "searching Settings opens the page with the match (\(w.settings.matches))")
        w.settings.search.stringValue = ""; w.settings.searchChanged(nil)
        w.settings.show(.general)
        if let view = w.settings.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: workdir.appendingPathComponent("settings.png"))
        }
        // Live theme switching: the window rebuilds in the other style around the same project and undo history.
        let startStyle = Theme.activeStyle, firstWindow = w.window
        let tracksBefore = s.tracks.map(\.id), undoBefore = e.undoName
        w.timeline.framesPerPoint = 300; w.timeline.scrollFrame = 12_000
        let zoomBefore = w.timeline.framesPerPoint, scrollBefore = w.timeline.scrollFrame
        let other = startStyle == .graphite ? 1 : 0
        w.settings.themePicker.selectItem(at: other)
        _ = NSApp.sendAction(#selector(SettingsController.themeChanged(_:)), to: w.settings, from: w.settings.themePicker)
        await wait(0.2)
        check(Theme.preferredStyle == Theme.Style.allCases[other] && Theme.activeStyle == Theme.Style.allCases[other],
              "settings switches the theme live (\(Theme.activeStyle.title))")
        check(w.window !== firstWindow && w.window?.isVisible == true && firstWindow?.isVisible != true, "the main window is rebuilt and the old one closed")
        check(s.tracks.map(\.id) == tracksBefore && e.undoName == undoBefore, "the project and undo history carry over")
        w.window?.layoutIfNeeded()
        check(w.timeline.framesPerPoint == zoomBefore && w.timeline.scrollFrame == scrollBefore && w.timeline.bounds.width > 400,
              "the arrangement keeps its zoom and position (\(w.timeline.framesPerPoint) vs \(zoomBefore) frames/pt, width \(w.timeline.bounds.width))")
        check((w.transport.reels.superview != nil) == (Theme.activeStyle == .warmAnalog), "the rebuilt window uses the new style's parts (tape reels \((Theme.activeStyle == .warmAnalog) ? "shown" : "hidden"))")
        check(w.settings.window?.isVisible == true && w.settings.relaunch.isHidden, "settings stays open, with no relaunch needed")
        try? w.snapshot(to: workdir.appendingPathComponent("theme-switched.png"))
        // Every theme by name from View ▸ Theme, then ⌥⌘A (Next Theme) steps on: each rebuild uses that theme's
        // families, fonts and system appearance, and keeps the project and zoom.
        for (i, style) in Theme.Style.allCases.enumerated() {
            guard let item = menuItem("Theme", submenuOnly: true, exact: true)?.submenu?.items.first(where: { $0.title == style.title }) else { check(false, "View ▸ Theme lists \(style.title)"); continue }
            item.menu?.update()
            check(item.tag == i + 1 && item.isEnabled, "View ▸ Theme ▸ \(style.title) is available")
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
            await wait(0.2)
            w.window?.layoutIfNeeded()
            let fontFace = Theme.ui(12).fontName, figures = Theme.mono(12).fontName + "/" + Theme.mono(12, .medium).fontName
            if style == .atelier {
                let faces = [Theme.title(12).fontName, Theme.title(12, .regular).fontName, Theme.display(20).fontName, Theme.note(10).fontName]
                check(faces.allSatisfy { $0.hasPrefix("SourceSerif4") }, "Atelier sets titles, the clock and notes in Source Serif 4 (\(faces))")
            }
            let wantFace = [Theme.Style.prism: "Sora", .atelier: "SourceSerif4"][style], wantFigures = [Theme.Style.prism: "GeistMono", .atelier: "SourceSerif4"][style]
            check(Theme.activeStyle == style && Theme.preferredStyle == style && w.window?.isVisible == true
                  && s.tracks.map(\.id) == tracksBefore && w.timeline.framesPerPoint == zoomBefore
                  && (wantFace.map { fontFace.hasPrefix($0) } ?? true) && (wantFigures.map { w in figures.split(separator: "/").allSatisfy { $0.hasPrefix(w) } } ?? true)
                  && (w.window?.appearance?.name == (style.palette.light ? .aqua : .darkAqua)),
                  "\(style.title): rebuilt with its fonts (\(fontFace), \(figures)), appearance and the same project and zoom")
            if style.variants.count > 1 {
                // Light and Dark from View ▸ Theme: the window rebuilds with that version's palette and appearance.
                let savedVariant = Theme.variantPreference
                for (tag, want) in [(102, Theme.Variant.light), (103, .dark)] {
                    guard let v = menuItem("Theme", submenuOnly: true, exact: true)?.submenu?.items.first(where: { $0.tag == tag }) else { check(false, "View ▸ Theme offers \(want.title)"); continue }
                    v.menu?.update()
                    _ = NSApp.sendAction(v.action!, to: v.target, from: v)
                    await wait(0.2)
                    check(Theme.activeVariant == want && Theme.isLight == (want == .light) && w.window?.appearance?.name == (want == .light ? .aqua : .darkAqua)
                          && s.tracks.map(\.id) == tracksBefore && v.isEnabled,
                          "\(style.title) \(want.title): palette, appearance and project after View ▸ Theme ▸ \(want.title)")
                }
                Theme.variantPreference = savedVariant
                _ = (NSApp.delegate as? AppDelegate)?.switchTheme(to: style)
                await wait(0.2)
            } else {
                let only = menuItem("Theme", submenuOnly: true, exact: true)?.submenu?.items.first { $0.tag == 102 }
                only?.menu?.update()
                check(only?.isEnabled == false, "\(style.title) has no light version to choose")
            }
            menuItem("Theme", submenuOnly: true, exact: true)?.submenu?.update()
            check(menuItem("Theme", submenuOnly: true, exact: true)?.submenu?.items.filter { $0.state == .on && $0.tag < 100 }.map(\.title) == [style.title], "only \(style.title) is checked in View ▸ Theme")
        }
        let beforeNext = Theme.activeStyle
        _ = perform("Next Theme")
        await wait(0.2)
        let all = Theme.Style.allCases
        check(Theme.activeStyle == all[((all.firstIndex(of: beforeNext) ?? 0) + 1) % all.count], "Next Theme steps from \(beforeNext.title) to \(Theme.activeStyle.title)")
        w.settings.themePicker.selectItem(at: Theme.Style.allCases.firstIndex(of: startStyle) ?? 0)
        _ = NSApp.sendAction(#selector(SettingsController.themeChanged(_:)), to: w.settings, from: w.settings.themePicker)
        await wait(0.2)
        check(Theme.activeStyle == startStyle, "switching back restores \(startStyle.title)")
        w.window?.layoutIfNeeded()
        check(w.timeline.framesPerPoint == zoomBefore, "and the zoom again (\(w.timeline.framesPerPoint) frames/pt)")
        w.settings.copyAudio.state = .off
        _ = NSApp.sendAction(#selector(SettingsController.copyChanged(_:)), to: w.settings, from: w.settings.copyAudio)
        check(!MainWindowController.copyAudioOnSave, "settings updates copy-audio preference")
        if let oldVariant { UserDefaults.standard.set(oldVariant, forKey: "appearanceVariant") } else { UserDefaults.standard.removeObject(forKey: "appearanceVariant") }
        if let oldTheme { UserDefaults.standard.set(oldTheme, forKey: "appearanceStyle") }
        else { UserDefaults.standard.removeObject(forKey: "appearanceStyle") }
        MainWindowController.copyAudioOnSave = oldCopy
        w.settings.window?.orderOut(nil)
        finish()
    }

    // ---- Real OS-level input (DALNOK_REAL_INPUT=1) ------------------------------------------------------------

    enum RealInput {
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

    func finish() {
        for key in Self.restoredKeys {
            if let value = previousPreferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let skipped = environmentSkips > 0 ? " (\(environmentSkips) skipped: the machine, not Dalnok; see SKIP lines)" : ""
        print((failures == 0 ? "SELFTEST: PASS" : "SELFTEST: FAIL (\(failures))") + skipped)
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}

extension NSView {
    /// Every descendant view (self excluded), depth first.
    var subviewsDeep: [NSView] { subviews.flatMap { [$0] + $0.subviewsDeep } }
}
