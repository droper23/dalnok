// Dalnok — application entry point.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Usage: Dalnok [audio files... | project.dalnok] [--play] [--snapshot out.png] [--selftest workdir]
//   --snapshot  render the window to a PNG after loading, then quit (UI checks)
//   --selftest  drive menus and mouse gestures end-to-end, print PASS/FAIL, then quit
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()
    lazy var session = Session(engine: engine)
    var main: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args0 = CommandLine.arguments
        // Captures and tests need settled frames; the self-test turns motion back on for its own checks.
        if args0.contains("--snapshot") || args0.contains("--screenshots") || args0.contains("--selftest") { Motion.override = false }
        main = MainWindowController(session: session)
        NSApp.mainMenu = buildMenu(target: main)
        Migration.applyKeymap(SourceDAW.preferred, to: NSApp.mainMenu)
        main.showWindow(nil)
        main.window?.center()
        // Open filling the screen's usable area (like double-clicking the title bar), not in full-screen mode.
        // Captures and tests keep the fixed default size so their images stay comparable.
        if !args0.contains("--snapshot") && !args0.contains("--screenshots") && !args0.contains("--selftest"),
           let screen = main.window?.screen ?? NSScreen.main {
            main.window?.setFrame(screen.visibleFrame, display: true)
        }
        NSApp.activate()

        do { try engine.startDevice() } catch {
            main.flash("Audio device unavailable: \(error)")
        }
        main.connectMidiInputs()
        let unfinished = MainWindowController.unfinishedTakes(in: MainWindowController.scratchRecordingFolder)
        if !unfinished.isEmpty && !args0.contains("--selftest") {
            main.flash("\(unfinished.count) unfinished recording(s) found — choose File ▸ Recover Recordings…")
        }

        let args = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let flagValues = Set(["--snapshot", "--selftest", "--screenshots", "--plugin-snapshot", "--uiwalk"].compactMap(value))
        let files = args.filter { !$0.hasPrefix("-") && !flagValues.contains($0) }.map { URL(fileURLWithPath: $0) }
        let snapshot = value("--snapshot").map { URL(fileURLWithPath: $0) }

        // Developer check: --plugin-snapshot <bundle.vst3> <out.png> opens the plug-in's editor and captures it.
        if let i = args.firstIndex(of: "--plugin-snapshot"), i + 2 < args.count {
            let bundle = args[i + 1], out = URL(fileURLWithPath: args[i + 2])
            let track = session.addInstrumentTrack("Plug-in")
            do {
                let slot = try session.addPlugin(track, path: bundle)
                main.openPluginWindow(track: track, slot: slot)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let pw = self.main.pluginWindows[slot], w = pw?.window
                    // GPU-drawn editors need a window capture; screencapture may require Screen Recording access.
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l", "\(w?.windowNumber ?? 0)", out.path]
                    try? p.run()
                    p.waitUntilExit()
                    print("plug-in window: \(Int(w?.frame.width ?? 0))×\(Int(w?.frame.height ?? 0)) pt, editor \(pw?.editorOpen == true ? "open" : "not open"), \(pw?.parameters.count ?? 0) parameters, capture exit \(p.terminationStatus)")
                    fflush(stdout)
                    exit(0) // skip the unsaved-changes prompt
                }
            } catch {
                print("plug-in failed: \(error)")
                NSApp.terminate(nil)
            }
            return
        }
        if let dir = value("--screenshots") {
            Screenshots.run(app: self, files: files, dir: URL(fileURLWithPath: dir))
            return
        }
        if let dir = ProcessInfo.processInfo.environment["DALNOK_WINDOW_DUMP"] { WindowDump.install(dir: URL(fileURLWithPath: dir)) }
        if let dir = value("--uiwalk") {
            Motion.override = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { UIWalk(app: self, dir: URL(fileURLWithPath: dir)).run() }
        }
        if let dir = value("--selftest") {
            SelfTest(app: self, files: files, workdir: URL(fileURLWithPath: dir)).run()
            return
        }
        let projects = files.filter { $0.pathExtension == "dalnok" }
        let foreign = files.filter { MainWindowController.foreignExtensions.contains($0.pathExtension.lowercased()) }
        let audio = files.filter { $0.pathExtension != "dalnok" && !foreign.contains($0) }

        if let f = foreign.first { main.importProject(f, confirm: false) }
        if interactiveLaunch { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.main.offerCrashRecovery() } }
        if interactiveLaunch && Analog.on && !Motion.reduced { main.vfdTestUntil = Date().addingTimeInterval(0.6) }
        if files.isEmpty && snapshot == nil && !args.contains("--no-welcome") && !WelcomeController.hasCompleted {
            main.welcome.show()
        }
        let finish = { [weak self] in
            guard let self else { return }
            if args.contains("--play") { engine.play() }
            if let snapshot {
                DispatchQueue.main.asyncAfter(deadline: .now() + (args.contains("--play") ? 1.5 : 0.4)) {
                    do { try self.main.snapshot(to: snapshot); print("snapshot: \(snapshot.path)") }
                    catch { print("snapshot failed: \(error)") }
                    let s = self.engine.stats()
                    print("engine: callbacks=\(s.callbacks) overloads=\(s.overloads) position=\(self.engine.position)")
                    NSApp.terminate(nil)
                }
            }
        }
        if let p = projects.first {
            main.openProject(p) { _ in finish() } // snapshots wait until the project (and its plug-ins) loaded
        } else if audio.isEmpty { finish() } else { session.importFiles(audio, completion: finish) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine.isDirty, main.window?.attachedSheet == nil, !SelfTest.running,
              !CommandLine.arguments.contains("--snapshot"), !CommandLine.arguments.contains("--screenshots") else {
            return .terminateNow
        }
        main.confirmDiscard({ NSApp.reply(toApplicationShouldTerminate: true) }, cancelled: { [weak self] in
            self?.relaunchOnQuit = false
            NSApp.reply(toApplicationShouldTerminate: false)
        })
        return .terminateLater
    }

    /// A normal launch (not a snapshot, screenshot, self-test or UI walk run).
    var interactiveLaunch: Bool {
        let a = CommandLine.arguments
        return !["--snapshot", "--screenshots", "--selftest", "--uiwalk", "--plugin-snapshot"].contains { a.contains($0) }
    }
    /// Set by Settings ▸ "Relaunch Now": start a fresh instance (with the saved project) once this one quits.
    var relaunchOnQuit = false
    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
        if interactiveLaunch { main.endSessionMarker() }
        guard relaunchOnQuit else { return }
        let bundle = Bundle.main.bundleURL
        let p = Process()
        if bundle.pathExtension == "app" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", bundle.path] + (session.projectURL.map { ["--args", $0.path] } ?? [])
        } else if let exe = Bundle.main.executableURL {
            p.executableURL = exe // development build run from .build
            p.arguments = (session.projectURL.map { [$0.path] } ?? []) + ["--no-welcome"]
        }
        try? p.run()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        main?.openProject(URL(fileURLWithPath: filename))
        return true
    }
}

/// Unmodified shortcuts (Space, ↩, ⌫) belong to the text being edited while a
/// field has focus. AppKit consumes matching key equivalents even when the item
/// is disabled, so they must not match at all.
final class MainMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, MainActor.assumeIsolated({ MainWindowController.isTyping }) { return false }
        if mods.isEmpty, (event.keyCode == 123 || event.keyCode == 124),
           MainActor.assumeIsolated({ (NSApp.delegate as? AppDelegate)?.main?.pianoRollIsKey == true }) { return false }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
/// Window commands target the (single) window controller directly, so they work
/// and validate regardless of which window is key.
func buildMenu(target: MainWindowController) -> NSMenu {
    let bar = MainMenu()
    func menu(_ title: String, _ items: [NSMenuItem]) {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach { m.addItem($0) }
        top.submenu = m
        bar.addItem(top)
    }
    func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        if target.responds(to: action) { it.target = target }
        return it
    }
    typealias W = MainWindowController
    menu("Dalnok", [
        item("About Dalnok", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
        item("Settings…", #selector(W.showSettings(_:)), ","),
        .separator(),
        item("Hide Dalnok", #selector(NSApplication.hide(_:)), "h"),
        item("Quit Dalnok", #selector(NSApplication.terminate(_:)), "q"),
    ])
    menu("File", [
        item("New", #selector(W.newDocument(_:)), "n"),
        item("Open…", #selector(W.openDocument(_:)), "o"),
        item("Recover Snapshot…", #selector(W.recoverSnapshot(_:)), ""),
        item("Recover Recordings…", #selector(W.recoverRecordings(_:)), ""),
        .separator(),
        item("Save", #selector(W.saveDocument(_:)), "s"),
        item("Save As…", #selector(W.saveDocumentAs(_:)), "s", [.command, .shift]),
        .separator(),
        item("Import Audio…", #selector(W.importAudio), "i"),
        item("Export Mix…", #selector(W.exportMix(_:)), "b"),
        .separator(),
        item("Relink Missing Audio…", #selector(W.relinkMissingAudio(_:)), ""),
        item("Copy Audio into Project on Save", #selector(W.toggleCopyAudioOnSave(_:)), ""),
    ])
    menu("Edit", [
        item("Undo", #selector(W.undo(_:)), "z"),
        item("Redo", #selector(W.redo(_:)), "z", [.command, .shift]),
        .separator(),
        item("Delete", #selector(W.delete(_:)), "\u{8}", []),
        item("Split at Playhead", #selector(W.splitAtPlayhead), "t"),
        item("Nudge Clips Left", #selector(W.nudgeClipsLeft(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), []),
        item("Nudge Clips Right", #selector(W.nudgeClipsRight(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), []),
    ])
    let colorItem = NSMenuItem(title: "Track Color", action: nil, keyEquivalent: "")
    colorItem.submenu = target.colorMenu()
    menu("Track", [
        item("New Track", #selector(W.newTrack(_:)), "n", [.command, .option]),
        item("New Instrument Track", #selector(W.newInstrumentTrack(_:)), "n", [.command, .option, .shift]),
        item("New Bus", #selector(W.newBus(_:)), "n", [.command, .option, .control]),
        item("Create Track Stack", #selector(W.createTrackStack(_:)), "d", [.command, .shift]),
        item("Ungroup Track Stack", #selector(W.ungroupTrackStack(_:)), ""),
        item("Clear Automation", #selector(W.clearAutomation(_:)), ""),
        item("Rename Track", #selector(W.renameTrack(_:)), ""),
        item("Delete Track", #selector(W.deleteTrack(_:)), "\u{8}", [.command]),
        .separator(),
        item("Move Track Up", #selector(W.moveTrackUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
        item("Move Track Down", #selector(W.moveTrackDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
        .separator(),
        item("Mute Track", #selector(W.toggleMuteTrack(_:)), "m", [.control]),
        item("Solo Track", #selector(W.toggleSoloTrack(_:)), "s", [.control]),
        item("Record Enable Track", #selector(W.toggleArmTrack(_:)), "r", [.control]),
        .separator(),
        colorItem,
        item("Recolor Tracks as Gradient", #selector(W.recolorTracksAsGradient(_:)), ""),
    ])
    let curve = NSMenuItem(title: "Fade Curve", action: nil, keyEquivalent: "")
    curve.submenu = NSMenu(title: "Fade Curve")
    for (title, sel) in [("Linear", #selector(W.setFadeCurveLinear(_:))), ("Equal Power", #selector(W.setFadeCurveEqualPower(_:)))] {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = target
        curve.submenu?.addItem(it)
    }
    let quantize = NSMenuItem(title: "Quantize", action: nil, keyEquivalent: "")
    quantize.submenu = NSMenu(title: "Quantize")
    for division in [4, 8, 16, 32] {
        let it = NSMenuItem(title: "1/\(division) Notes", action: #selector(W.quantizeClip(_:)), keyEquivalent: "")
        it.tag = division
        it.target = target
        quantize.submenu?.addItem(it)
    }
    menu("Clip", [
        item("New MIDI Clip", #selector(W.newMidiClip(_:)), "m", [.command, .shift]),
        item("Piano Roll", #selector(W.openPianoRoll(_:)), "p", []),
        item("Open Take Folder", #selector(W.openTakeFolder(_:)), ""),
        item("Make Take Folder", #selector(W.makeTakeFolder(_:)), ""),
        quantize,
        .separator(),
        item("Add Short Fades", #selector(W.addShortFades(_:)), "f", [.control]),
        item("Remove Fades", #selector(W.removeFades(_:)), ""),
        curve,
        .separator(),
        item("Double Speed", #selector(W.doubleSpeed(_:)), ""),
        item("Half Speed", #selector(W.halfSpeed(_:)), ""),
        item("Transpose Up a Semitone", #selector(W.transposeUp(_:)), ""),
        item("Transpose Down a Semitone", #selector(W.transposeDown(_:)), ""),
        item("Preserve Pitch When Stretching", #selector(W.togglePreservePitch(_:)), ""),
        item("Reset Speed and Pitch", #selector(W.resetSpeedAndPitch(_:)), ""),
    ])
    menu("Transport", [
        item("Play / Pause", #selector(W.togglePlay), " ", []),
        item("Go to Start", #selector(W.goToStart), "\r", []),
        item("Record", #selector(W.toggleRecord(_:)), "r", []),
        item("Metronome", #selector(W.toggleMetronome(_:)), "k", []),
        item("Cycle", #selector(W.toggleCycle(_:)), "c", []),
        item("Set Cycle to Selection", #selector(W.setCycleToSelection(_:)), "u"),
        item("Count-In", #selector(W.toggleCountIn(_:)), "k", [.shift]),
        item("Autopunch", #selector(W.toggleAutopunch(_:)), ""),
        item("Set Punch to Cycle", #selector(W.setPunchToCycle(_:)), ""),
        item("Edit Tempo", #selector(W.editTempo(_:)), "t", [.command, .option]),
        .separator(),
        item("Add Tempo Change at Playhead", #selector(W.addTempoChange(_:)), "t", [.command, .option, .shift]),
        item("Add Time Signature Change at Playhead", #selector(W.addMeterChange(_:)), ""),
        item("Remove Tempo Change at Playhead", #selector(W.removeTempoChange(_:)), ""),
        item("Remove Time Signature Change at Playhead", #selector(W.removeMeterChange(_:)), ""),
    ])
    let outputMenu = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
    outputMenu.submenu = NSMenu(title: "Output Device")
    outputMenu.submenu?.delegate = target
    let inputMenu = NSMenuItem(title: "Recording Input", action: nil, keyEquivalent: "")
    inputMenu.submenu = NSMenu(title: "Recording Input")
    inputMenu.submenu?.delegate = target
    let midiMenu = NSMenuItem(title: "MIDI Inputs", action: nil, keyEquivalent: "")
    midiMenu.submenu = NSMenu(title: "MIDI Inputs")
    midiMenu.submenu?.delegate = target
    menu("Audio", [outputMenu, inputMenu,
                   item("Input Monitoring", #selector(W.toggleInputMonitoring(_:)), ""),
                   .separator(), midiMenu,
                   .separator(), item("Plug-ins…", #selector(W.showPlugins(_:)), "p", [.command, .option])])
    menu("View", [
        item("Command Palette…", #selector(W.showCommandPalette(_:)), "k"),
        .separator(),
        item("Zoom In", #selector(W.zoomIn), "="),
        item("Zoom Out", #selector(W.zoomOut), "-"),
        item("Zoom to Fit", #selector(W.zoomToFit), "0"),
        .separator(),
        item("Bars and Beats Ruler", #selector(W.toggleBarsAndBeats(_:)), "b", [.command, .option]),
        item("Device Panel", #selector(W.toggleDevicePanel(_:)), "d", [.command, .option]),
        item("Mixer", #selector(W.toggleMixer(_:)), "x", []),
        item("Show Automation", #selector(W.toggleAutomation(_:)), "a", []),
        item("Automate Volume", #selector(W.automateVolume(_:)), ""),
        item("Automate Pan", #selector(W.automatePan(_:)), ""),
    ])
    menu("Window", [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
    ])
    menu("Help", [
        item("Migration Assistant…", #selector(W.showMigrationAssistant(_:)), ""),
        item("Concept Guide", #selector(W.showConceptGuide(_:)), ""),
        item("Command Palette…", #selector(W.showCommandPalette(_:)), ""),
    ])
    return bar
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()


/// Development aid for driving the real app with OS-level input: on SIGUSR1 every visible window draws itself to `<dir>/<n>-<title>.png` and
/// `<dir>/windows.json` lists window frames in screen points (top-left origin) plus the key window. The app
/// renders its own views, so no Screen Recording permission is needed. Off unless DALNOK_WINDOW_DUMP is set.
@MainActor enum WindowDump {
    nonisolated(unsafe) static var source: DispatchSourceSignal?
    static func install(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { dump(dir) }
        s.resume()
        source = s
    }
    static func dump(_ dir: URL) {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var list: [[String: Any]] = []
        for (i, w) in NSApp.windows.enumerated() where w.isVisible {
            guard let view = w.contentView?.superview ?? w.contentView else { continue }
            let name = "\(i)-" + (w.title.isEmpty ? String(describing: type(of: w)) : w.title).replacingOccurrences(of: "/", with: "-")
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            }
            let f = w.frame
            list.append(["file": name + ".png", "title": w.title, "key": w.isKeyWindow,
                         "x": f.minX, "y": screenHeight - f.maxY, "w": f.width, "h": f.height])
        }
        let info: [String: Any] = ["windows": list, "frontmost": NSApp.isActive, "time": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent("windows.json"))
        }
    }
}
