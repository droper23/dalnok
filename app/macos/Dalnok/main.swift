// Dalnok — application entry point.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Usage: Dalnok [audio files... | project.dalnok] [--play] [--snapshot out.png] [--selftest workdir]
//   --snapshot  render the window to a PNG after loading, then quit (UI checks)
//   --selftest  drive menus and mouse gestures end-to-end, print PASS/FAIL, then quit
import AppKit
import DalnokEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()
    lazy var session = Session(engine: engine)
    var main: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.installControlTint()
        let args0 = CommandLine.arguments
        // Match System: Prism and Atelier follow macOS between light and dark.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard Theme.variantPreference == "system", let app = NSApp.delegate as? AppDelegate else { return }
                app.switchTheme(to: Theme.activeStyle)
            }
        }
        // Captures and tests need settled frames; the self-test turns motion back on for its own checks.
        if args0.contains("--snapshot") || args0.contains("--screenshots") || args0.contains("--gallery") || args0.contains("--selftest") { Motion.override = false }
        main = MainWindowController(session: session)
        NSApp.mainMenu = buildMenu(target: main)
        ShortcutRegistry.shared.attach(NSApp.mainMenu)
        main.showWindow(nil)
        main.window?.center()
        // Open filling the screen's usable area (like double-clicking the title bar), not in full-screen mode.
        // Captures and tests keep the fixed default size so their images stay comparable.
        if !args0.contains("--snapshot") && !args0.contains("--screenshots") && !args0.contains("--gallery") && !args0.contains("--selftest") && !args0.contains("--tour"),
           let screen = main.window?.screen ?? NSScreen.main {
            main.window?.setFrame(screen.visibleFrame, display: true)
        }
        NSApp.activate()

        do { try engine.startDevice() } catch {
            main.flash("Audio device unavailable: \(error)")
        }
        main.connectMidiInputs()
        main.syncInputDevice()
        let unfinished = MainWindowController.unfinishedTakes(in: MainWindowController.scratchRecordingFolder)
        if !unfinished.isEmpty && !args0.contains("--selftest") {
            main.flash("\(unfinished.count) unfinished recording(s) found — choose File ▸ Recover Recordings…")
        }

        let args = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let flagValues = Set(["--perf", "--snapshot", "--selftest", "--screenshots", "--gallery", "--plugin-snapshot", "--uiwalk", "--plugin-report", "--tour"].compactMap(value))
        let files = args.filter { !$0.hasPrefix("-") && !flagValues.contains($0) }.map { URL(fileURLWithPath: $0) }
        let snapshot = value("--snapshot").map { URL(fileURLWithPath: $0) }

        // Developer check: --plugin-report <out.tsv> lists every installed plug-in with its declared categories, the
        // browser category Dalnok gives it and the faceplate display it gets, then quits.
        if let out = value("--plugin-report") {
            print("plugin report: \(PluginManagerController.writeReport(to: out)) plug-ins -> \(out)")
            exit(0)
        }
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
        if let dir = value("--gallery") {
            Screenshots.gallery(app: self, project: files.first, dir: URL(fileURLWithPath: dir))
            return
        }
        if let dir = value("--screenshots") {
            Screenshots.run(app: self, files: files, dir: URL(fileURLWithPath: dir))
            return
        }
        if let dir = ProcessInfo.processInfo.environment["DALNOK_WINDOW_DUMP"] { WindowDump.install(dir: URL(fileURLWithPath: dir)) }
        if let dir = value("--selftest") {
            SelfTest(app: self, files: files, workdir: URL(fileURLWithPath: dir)).run()
            return
        }
        // Record the new session before opening a project: plug-in activation can
        // crash or hang before the delayed recovery alert is presented.
        let previousRecovery = interactiveLaunch ? main.unfinishedSessionSnapshots() : []
        if interactiveLaunch {
            main.beginSessionMarker(carrying: previousRecovery)
            engine.setRecoveryDirectory(main.recoveryDirectory)
        }
        let projects = files.filter { $0.pathExtension == "dalnok" }
        let foreign = files.filter { MainWindowController.foreignExtensions.contains($0.pathExtension.lowercased()) }
        let audio = files.filter { $0.pathExtension != "dalnok" && !foreign.contains($0) }

        if let f = foreign.first { main.importProject(f, confirm: false) }
        let offerRecovery = { [weak self] in
            guard let self, interactiveLaunch, !previousRecovery.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.main.offerCrashRecovery(previousRecovery) }
        }
        if interactiveLaunch && Theme.look.tapeDeck && !Motion.reduced { main.vfdTestUntil = Date().addingTimeInterval(0.6) }
        if files.isEmpty && snapshot == nil && !args.contains("--no-welcome") && !WelcomeController.hasCompleted {
            // First launch asks its questions first; a recovery offer waits until they are answered or closed.
            main.shortcutChooser.onFinished = offerRecovery
            main.shortcutChooser.show()
        } else { offerRecovery() }
        let finish = { [weak self] in
            guard let self else { return }
            if let dir = value("--uiwalk") {
                Motion.override = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    UIWalk(app: self, dir: URL(fileURLWithPath: dir)).run()
                }
                return
            }
            // Developer: --tour <dir> plays a scripted walk through the window and writes its frames (README GIFs).
            if let dir = value("--tour") { return Screenshots.tour(app: self, dir: URL(fileURLWithPath: dir)) }
            if let s = value("--perf"), let seconds = Double(s) { return PerfProbe.run(app: self, seconds: seconds) }
            if args.contains("--play") { engine.play() }
            if let snapshot {
                let wait = Double(ProcessInfo.processInfo.environment["DALNOK_SNAPSHOT_DELAY"] ?? "") ?? (args.contains("--play") ? 1.5 : 0.4) // seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    do { try self.main.snapshot(to: snapshot); print("snapshot: \(snapshot.path)") }
                    catch { print("snapshot failed: \(error)") }
                    let s = self.engine.stats()
                    print("engine: callbacks=\(s.callbacks) overloads=\(s.overloads) position=\(self.engine.position)")
                    NSApp.terminate(nil)
                }
            }
        }
        if let p = projects.first {
            main.openProject(p) { ok in
                if !ok && args.contains("--uiwalk") { exit(2) }
                finish()
            } // snapshots and UI walks wait until the project (and its plug-ins) loaded
        } else if audio.isEmpty { finish() } else { session.importFiles(audio, completion: finish) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine.hasUnsavedChanges, main.window?.attachedSheet == nil, !SelfTest.running,
              !CommandLine.arguments.contains("--snapshot"), !CommandLine.arguments.contains("--screenshots"), !CommandLine.arguments.contains("--gallery") else {
            return .terminateNow
        }
        main.confirmDiscard({ NSApp.reply(toApplicationShouldTerminate: true) }, cancelled: { [weak self] in
            self?.relaunchOnQuit = false
            NSApp.reply(toApplicationShouldTerminate: false)
        })
        return .terminateLater
    }

    /// Switches the appearance live: rebuilds the main window (and closes secondary windows) around the same
    /// session, keeping the window frame, the open project, undo history and MIDI inputs. Refused while recording.
    /// `force` rebuilds the windows in the same style (View ▸ Illustrated Controls changes control sizes).
    @discardableResult func switchTheme(to style: Theme.Style, variant: Theme.Variant? = nil, force: Bool = false, keeping extra: [NSWindow] = []) -> Bool {
        let variant = variant ?? Theme.resolvedVariant(for: style)
        guard force || style != Theme.activeStyle || variant != Theme.activeVariant else { return true }
        guard !engine.isRecording else { return false }
        let old = main!
        let frame = old.window?.frame
        // A picture of the old style, faded out over the new window so the switch reads as one change (as macOS does
        // for Light and Dark), not as a window closing and another opening.
        var before: NSImage?
        if !Motion.reduced, let v = old.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            let image = NSImage(size: v.bounds.size)
            image.addRepresentation(rep)
            before = image
        }
        let settings = old.settings
        old.tearDown(keeping: [settings.window].compactMap { $0 } + extra)
        Theme.activeStyle = style
        Theme.activeVariant = variant
        session.forceRefresh() // track colours come from the style's palette
        let next = MainWindowController(session: session)
        // The arrangement keeps its zoom and scroll position: the same view, drawn in the other style.
        next.fitOnNextChange = false
        next.timeline.keepView(framesPerPoint: old.timeline.framesPerPoint, scrollFrame: old.timeline.scrollFrame, scrollY: old.timeline.scrollY)
        next.settings = settings
        next.openedMidiSources = old.openedMidiSources
        main = next
        NSApp.mainMenu = buildMenu(target: next)
        ShortcutRegistry.shared.attach(NSApp.mainMenu)
        if let frame { next.window?.setFrame(frame, display: false) }
        next.showWindow(nil)
        old.window?.delegate = nil
        old.window?.close()
        if settings.window?.isVisible == true { settings.window?.orderFront(nil) }
        if let before, let content = next.window?.contentView {
            let cover = NSImageView(frame: content.bounds)
            cover.image = before
            cover.imageScaling = .scaleAxesIndependently
            cover.autoresizingMask = [.width, .height]
            content.addSubview(cover, positioned: .above, relativeTo: nil)
            Motion.views(0.35, { cover.animator().alphaValue = 0 }, completion: {
                DispatchQueue.main.async { cover.removeFromSuperview() }
            })
        }
        next.flash("Appearance: \(style.title)")
        return true
    }

    /// A normal launch (not a snapshot, screenshot, self-test or UI walk run).
    var interactiveLaunch: Bool {
        let a = CommandLine.arguments
        return !["--snapshot", "--screenshots", "--gallery", "--selftest", "--uiwalk", "--plugin-snapshot", "--tour", "--perf"].contains { a.contains($0) }
    }
    /// Set by Settings ▸ "Relaunch Now": start a fresh instance (with the saved project) once this one quits.
    var relaunchOnQuit = false
    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
        if interactiveLaunch { main.endSessionMarker() }
        defer {
            // Some plug-ins (seen with a Qt-based VST3) crash in their own static destructors during exit().
            // Everything Dalnok owns is saved and shut down by now, so leave without running library teardown.
            UserDefaults.standard.synchronize()
            fflush(stdout); fflush(stderr)
            _exit(0)
        }
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
        // While a text field is being edited, it owns every key without ⌘: plain keys type, ⌥ keys type characters
        // (⌥' is æ), and ⌃ keys edit (⌃H deletes backward, ⌃F moves forward).
        if !event.modifierFlags.contains(.command), MainActor.assumeIsolated({ MainWindowController.isTyping }) { return false }
        nonisolated(unsafe) let e = event
        // A focused tape key owns its activation keys, including keys also bound to transport commands.
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           [36, 49, 76].contains(event.keyCode), MainActor.assumeIsolated({ (NSApp.keyWindow ?? e.window)?.firstResponder is DeckKey }) { return false }
        // Keyboard focus on a view that takes keys (the launcher grid) or on any control: its keys, and Tab / ⇧Tab
        // (which move focus to the next control even where a preset binds Tab, as Ableton's does), go to it.
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           MainActor.assumeIsolated({ () -> Bool in
               let r = (NSApp.keyWindow ?? e.window)?.firstResponder
               if let owner = r as? KeyOwner, owner.ownsKey(e) { return true }
               return e.keyCode == 48 && r is NSView && !(r is NSTextView)
           }) { return false }
        // The registry decides: it runs the command bound in the active context, leaves piano-roll keys to the
        // piano roll, and never lets a menu item fire a key that belongs to another context.
        let verdict: Bool? = MainActor.assumeIsolated {
            let r = ShortcutRegistry.shared
            if ShortcutRegistry.capturing { return false }
            if ShortcutRegistry.dialogInFront { return nil } // the dialog's own buttons answer Return and Escape
            if r.handle(e) { return true }
            if let k = KeyCombo(event: e), r.isBound(k) { return false }
            // Unbound keys: only ⌘/⌃ combinations go on to AppKit (for the items macOS adds, like Emoji & Symbols).
            // AppKit's own matching is looser than ours (a plain K can match a ⇧K item), so nothing else may reach it.
            if !r.actions.isEmpty, e.modifierFlags.intersection([.command, .control]).isEmpty { return false }
            return nil
        }
        if let verdict { return verdict }
        return super.performKeyEquivalent(with: event) // system items (Emoji & Symbols, Dictation)
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
    /// Commands for whichever window is key (responder chain, no fixed target).
    func windowItem(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        return it
    }
    let fullScreen = windowItem("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
    menu("Dalnok", [
        item("About Dalnok", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
        item("Settings…", #selector(W.showSettings(_:)), ","),
        item("Keyboard Shortcuts…", #selector(W.showKeyboardShortcuts(_:)), "k", [.command, .option]),
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
        item("Export Stems…", #selector(W.exportStems(_:)), "b", [.command, .shift]),
        item("Export as DAWproject…", #selector(W.exportDawproject(_:)), ""),
        .separator(),
        item("Relink Missing Audio…", #selector(W.relinkMissingAudio(_:)), ""),
        item("Copy Audio into Project on Save", #selector(W.toggleCopyAudioOnSave(_:)), ""),
    ])
    menu("Edit", [
        item("Undo", #selector(W.undo(_:)), "z"),
        item("Redo", #selector(W.redo(_:)), "z", [.command, .shift]),
        .separator(),
        windowItem("Cut", #selector(NSText.cut(_:)), "x"),
        windowItem("Copy", #selector(NSText.copy(_:)), "c"),
        windowItem("Paste", #selector(NSText.paste(_:)), "v"),
        item("Duplicate", #selector(W.duplicateClips(_:)), "d"),
        windowItem("Select All", #selector(NSText.selectAll(_:)), "a"),
        .separator(),
        item("Delete", #selector(W.delete(_:)), "\u{8}", []),
        item("Split at Playhead", #selector(W.splitAtPlayhead), "t"),
        item("Nudge Clips Left", #selector(W.nudgeClipsLeft(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), []),
        item("Nudge Clips Right", #selector(W.nudgeClipsRight(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), []),
        item("Select Previous Clip", #selector(W.selectPreviousClip(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.option]),
        item("Select Next Clip", #selector(W.selectNextClip(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.option]),
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
        item("Automation: Read", #selector(W.automationRead(_:)), ""),
        item("Automation: Touch", #selector(W.automationTouch(_:)), ""),
        item("Automation: Latch", #selector(W.automationLatch(_:)), ""),
        item("Rename Track", #selector(W.renameTrack(_:)), ""),
        item("Delete Track", #selector(W.deleteTrack(_:)), "\u{8}", [.command]),
        item("Duplicate Track", #selector(W.duplicateTrack(_:)), "d", [.control, .shift]),
        item("Bounce Track in Place", #selector(W.bounceTrackInPlace(_:)), "b", [.control, .command]),
        item("Hide Track", #selector(W.hideTrack(_:)), "h", [.control]),
        item("Show All Tracks", #selector(W.showAllTracks(_:)), "h", [.control, .shift]),
        .separator(),
        item("Move Track Up", #selector(W.moveTrackUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
        item("Move Track Down", #selector(W.moveTrackDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
        .separator(),
        item("Select Previous Track", #selector(W.selectPreviousTrack(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), []),
        item("Select Next Track", #selector(W.selectNextTrack(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), []),
        .separator(),
        item("Mute Track", #selector(W.toggleMuteTrack(_:)), "m", [.control]),
        item("Solo Track", #selector(W.toggleSoloTrack(_:)), "s", [.control]),
        item("Record Enable Track", #selector(W.toggleArmTrack(_:)), "r", [.control]),
        item("Input Monitoring", #selector(W.toggleSelectedInputMonitor(_:)), "i", [.control]),
        item("Suspend Groups", #selector(W.toggleGroupClutch(_:)), "g", [.command]),
        item("Bypass Plug-ins", #selector(W.toggleTrackBypass(_:)), "b", [.control]),
        .separator(),
        colorItem,
        item("Recolor Tracks as Gradient", #selector(W.recolorTracksAsGradient(_:)), ""),
    ])
    let curve = NSMenuItem(title: "Fade Curve", action: nil, keyEquivalent: "")
    // View ▸ Theme: every theme by name (the checked one is on); ⌥⌘A steps to the next.
    let themeMenu = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
    themeMenu.submenu = NSMenu(title: "Theme")
    for (i, style) in Theme.Style.allCases.enumerated() {
        let it = NSMenuItem(title: style.title, action: #selector(W.chooseTheme(_:)), keyEquivalent: "")
        it.tag = i + 1
        it.target = target
        it.toolTip = style.summary
        themeMenu.submenu?.addItem(it)
    }
    themeMenu.submenu?.addItem(.separator())
    for (i, title) in ["Match System", "Light", "Dark"].enumerated() {
        let it = NSMenuItem(title: title, action: #selector(W.chooseThemeVariant(_:)), keyEquivalent: "")
        it.tag = 101 + i
        it.target = target
        themeMenu.submenu?.addItem(it)
    }
    curve.submenu = NSMenu(title: "Fade Curve")
    for (title, sel) in [("Linear", #selector(W.setFadeCurveLinear(_:))), ("Equal Power", #selector(W.setFadeCurveEqualPower(_:)))] {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = target
        curve.submenu?.addItem(it)
    }
    let quantize = NSMenuItem(title: "Quantize", action: nil, keyEquivalent: "")
    quantize.submenu = NSMenu(title: "Quantize")
    let qNow = NSMenuItem(title: "Quantize Selection", action: #selector(W.quantizeSelection(_:)), keyEquivalent: "q")
    qNow.keyEquivalentModifierMask = []
    qNow.target = target
    quantize.submenu?.addItem(qNow)
    quantize.submenu?.addItem(.separator())
    for division in [4, 8, 12, 16, 24, 32] {
        let it = NSMenuItem(title: division % 3 == 0 ? "1/\(division / 3 * 2) Triplets" : "1/\(division) Notes", action: #selector(W.quantizeClip(_:)), keyEquivalent: "")
        it.tag = division
        it.target = target
        quantize.submenu?.addItem(it)
    }
    // MIDI Functions (Logic's Functions menu): each item carries [function, a, b] for dalnok_midi_transform.
    let functions = NSMenuItem(title: "MIDI Functions", action: nil, keyEquivalent: "")
    functions.submenu = NSMenu(title: "MIDI Functions")
    func fn(_ title: String, _ op: DalnokMidiFunction, _ a: Double = 0, _ b: Double = 0, into m: NSMenu?) {
        let it = NSMenuItem(title: title, action: #selector(W.midiFunction(_:)), keyEquivalent: "")
        it.representedObject = [Double(op.rawValue), a, b]
        it.target = target
        m?.addItem(it)
    }
    fn("Legato", DALNOK_MIDI_LEGATO, into: functions.submenu)
    let lengths = NSMenuItem(title: "Fixed Length", action: nil, keyEquivalent: "")
    lengths.submenu = NSMenu(title: "Fixed Length")
    for (t, beats) in [("1/32 Note", 0.125), ("1/16 Note", 0.25), ("1/8 Note", 0.5), ("1/4 Note", 1.0), ("1/2 Note", 2.0), ("Whole Note", 4.0)] {
        fn(t, DALNOK_MIDI_FIXED_LENGTH, beats, into: lengths.submenu)
    }
    functions.submenu?.addItem(lengths)
    let scales = NSMenuItem(title: "Scale Quantize", action: nil, keyEquivalent: "")
    scales.submenu = NSMenu(title: "Scale Quantize")
    let roots = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    for (k, name) in ["Major", "Minor", "Dorian", "Mixolydian", "Major Pentatonic", "Minor Pentatonic", "Harmonic Minor", "Blues"].enumerated() {
        let sub = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        sub.submenu = NSMenu(title: name)
        for (r, root) in roots.enumerated() { fn("\(root) \(name)", DALNOK_MIDI_SCALE_QUANTIZE, Double(r), Double(k), into: sub.submenu) }
        scales.submenu?.addItem(sub)
    }
    functions.submenu?.addItem(scales)
    fn("Humanize", DALNOK_MIDI_HUMANIZE, 10, 8, into: functions.submenu)
    functions.submenu?.addItem(.separator())
    for v in [127.0, 100, 64] { fn("Set Velocity to \(Int(v))", DALNOK_MIDI_SET_VELOCITY, v, into: functions.submenu) }
    fn("Louder (+10%)", DALNOK_MIDI_SCALE_VELOCITY, 110, into: functions.submenu)
    fn("Softer (−10%)", DALNOK_MIDI_SCALE_VELOCITY, 90, into: functions.submenu)
    menu("Clip", [
        item("New MIDI Clip", #selector(W.newMidiClip(_:)), "m", [.command, .shift]),
        item("Piano Roll", #selector(W.openPianoRoll(_:)), "p", []),
        item("Open Take Folder", #selector(W.openTakeFolder(_:)), ""),
        item("Make Take Folder", #selector(W.makeTakeFolder(_:)), ""),
        item("Mute Clip", #selector(W.toggleClipMute(_:)), ""),
        item("Loop Clip", #selector(W.toggleClipLoop(_:)), "l", []),
        quantize,
        functions,
        item("Step Input", #selector(W.toggleStepInput(_:)), ""),
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
        item("Add Marker", #selector(W.addMarker(_:)), "'", [.option]),
        item("Previous Marker", #selector(W.previousMarker(_:)), ",", [.option]),
        item("Next Marker", #selector(W.nextMarker(_:)), ".", [.option]),
        item("Rename Marker…", #selector(W.renameMarkerAtPlayhead(_:)), ""),
        item("Delete Marker", #selector(W.deleteMarkerAtPlayhead(_:)), ""),
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
                   item("Monitor Armed Tracks", #selector(W.toggleInputMonitoring(_:)), ""),
                   .separator(), midiMenu,
                   .separator(), item("Plug-ins…", #selector(W.showPlugins(_:)), "p", [.command, .option])])
    menu("View", [
        item("Command Palette…", #selector(W.showCommandPalette(_:)), "k"),
        .separator(),
        item("Zoom In", #selector(W.zoomIn), "="),
        item("Zoom Out", #selector(W.zoomOut), "-"),
        item("Zoom to Fit", #selector(W.zoomToFit), "0"),
        item("Zoom to Selection", #selector(W.zoomToSelection(_:)), "z", []),
        item("Taller Tracks", #selector(W.tallerTracks(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command]),
        item("Shorter Tracks", #selector(W.shorterTracks(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command]),
        .separator(),
        item("Bars and Beats Ruler", #selector(W.toggleBarsAndBeats(_:)), "b", [.command, .option]),
        item("Secondary Clock", #selector(W.toggleSecondaryClock(_:)), "", []),
        item("Device Panel", #selector(W.toggleDevicePanel(_:)), "d", [.command, .option]),
        item("Clip Editor", #selector(W.toggleClipEditor(_:)), "e", [.command, .option]),
        item("Library", #selector(W.toggleLibrary(_:)), "y", []),
        item("Inspector", #selector(W.toggleInspector(_:)), "i", []),
        item("Mixer", #selector(W.toggleMixer(_:)), "x", []),
        item("Clip Launcher", #selector(W.toggleLauncher(_:)), "l", [.command]),
        item("Stop All Clips", #selector(W.stopAllClips(_:)), ""),
        item("Record Launcher to Arrangement", #selector(W.toggleLauncherRecording(_:)), ""),
        item("Show Automation", #selector(W.toggleAutomation(_:)), "a", []),
        item("Automate Volume", #selector(W.automateVolume(_:)), ""),
        item("Automate Pan", #selector(W.automatePan(_:)), ""),
        .separator(),
        item("Composition Overview", #selector(W.toggleCompositionOverview(_:)), "o", [.command, .option]),
        themeMenu,
        item("Next Theme", #selector(W.toggleAnalogStyle(_:)), "a", [.command, .option]),
        item("Illustrated Controls", #selector(W.toggleIllustrated(_:)), ""),
        item("Tape Machine", #selector(W.showTapeDeck(_:)), "t", [.command, .shift]),
        fullScreen,
    ])
    menu("Window", [
        windowItem("Close Window", #selector(NSWindow.performClose(_:)), "w"),
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
// DALNOK_BACKGROUND (self-test matrix, galleries): no Dock icon and no menu bar, so parallel test runs don't crowd the
// screen; the windows and menus still work for the tests.
if ProcessInfo.processInfo.environment["DALNOK_BACKGROUND"] != nil {
    // (AppKit then adds its own Dictation and Emoji items to Edit; the tests check the app's menus only.)
    UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true, "NSDisabledCharacterPaletteMenuItem": true])
    app.setActivationPolicy(.accessory)
} else { app.setActivationPolicy(.regular) }
BundledFonts.registerAll() // theme typefaces, before any view asks for a font
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
        // Worst main-thread gap between dumps: a 5 ms timer in the common modes notices any stall longer than that.
        lastTickNs = DispatchTime.now().uptimeNanoseconds
        let t = Timer(timeInterval: 0.005, repeats: true) { _ in
            MainActor.assumeIsolated { // the main run loop's timer
                let now = DispatchTime.now().uptimeNanoseconds
                worstGapNs = max(worstGapNs, now - lastTickNs); lastTickNs = now
                // Peaks since the last dump: meter reads reset them, and the UI reads every frame, so sample them often.
                guard let e = (NSApp.delegate as? AppDelegate)?.main?.session.engine.handle else { return }
                var l: Float = 0, r: Float = 0
                dalnok_meter_master(e, &l, &r); peaks[0] = max(peaks[0] ?? 0, l, r)
                for i in 0..<dalnok_track_count(e) {
                    let id = dalnok_track_at(e, i)
                    if dalnok_meter_track(e, id, &l, &r) == DALNOK_OK { peaks[Int(id)] = max(peaks[Int(id)] ?? 0, l, r) }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }
    static var worstGapNs: UInt64 = 0, lastTickNs: UInt64 = 0
    static var peaks: [Int: Float] = [:] // track id (0 = master) -> peak since the last dump
    /// Engine diagnostics for real-input checks: transport, callback stats, meters, undo, and every plug-in slot with
    /// its isolation stats, editor window and parameter values.
    static func diagnostics() -> [String: Any] {
        var info: [String: Any] = ["mainThreadWorstGapMs": Double(worstGapNs) / 1e6,
                                   "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                                   "frontmostPid": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)]
        worstGapNs = 0
        guard let main = (NSApp.delegate as? AppDelegate)?.main else { return info }
        let e = main.session.engine.handle
        var st = DalnokStats(); dalnok_engine_stats(e, &st)
        info["engine"] = ["callbacks": st.callbacks, "overloads": st.overloads, "maxCallbackNs": st.max_callback_ns,
                          "lastCallbackNs": st.last_callback_ns, "maxFrames": st.max_frames_per_callback]
        info["playing"] = dalnok_transport_is_playing(e)
        info["position"] = dalnok_transport_position(e)
        var ml: Float = 0, mr: Float = 0; dalnok_meter_master(e, &ml, &mr)
        info["masterMeter"] = [ml, mr]
        info["peaksSinceLastDump"] = Dictionary(uniqueKeysWithValues: peaks.map { (String($0.key), Double($0.value)) })
        peaks = [:]
        var name = [CChar](repeating: 0, count: 256); dalnok_undo_name(e, &name, name.count)
        info["undo"] = String(cString: name)
        info["dirty"] = dalnok_project_dirty(e)
        info["windowEdited"] = main.window?.isDocumentEdited ?? false
        var tracks: [[String: Any]] = []
        for i in 0..<dalnok_track_count(e) {
            let tr = dalnok_track_at(e, i)
            var tl: Float = 0, trr: Float = 0; dalnok_meter_track(e, tr, &tl, &trr)
            var slots: [[String: Any]] = []
            for j in 0..<dalnok_track_plugin_count(e, tr) {
                var p = DalnokPluginSlotInfo(); guard dalnok_track_plugin_info(e, tr, j, &p) == DALNOK_OK else { continue }
                var slot: [String: Any] = ["id": p.id, "name": withUnsafeBytes(of: p.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
                                           "loaded": p.loaded, "loading": p.loading, "isolated": p.isolated,
                                           "error": withUnsafeBytes(of: p.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }]
                var iso = DalnokPluginIsolationStats()
                if dalnok_plugin_isolation_stats(e, p.id, &iso) == DALNOK_OK {
                    slot["isolation"] = ["missed": iso.missed_blocks, "budgetSkips": iso.budget_skips,
                                         "workgroupJoined": iso.workgroup_joined, "workgroupError": iso.workgroup_error]
                }
                var ed = DalnokPluginEditorWindow()
                if dalnok_plugin_editor_window(e, p.id, &ed) == DALNOK_OK {
                    slot["editor"] = ["open": ed.open, "visible": ed.visible, "x": ed.x, "y": ed.y, "w": ed.width, "h": ed.height,
                                      "pid": ed.process_id, "window": ed.window_number]
                }
                var params: [[String: Any]] = []
                for k in 0..<dalnok_plugin_parameter_count(e, p.id) {
                    var q = DalnokPluginParameter(); guard dalnok_plugin_parameter(e, p.id, k, &q) == DALNOK_OK else { continue }
                    params.append(["id": q.id, "v": q.value,
                                   "t": withUnsafeBytes(of: q.title) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
                                   "d": withUnsafeBytes(of: q.display) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }])
                }
                slot["params"] = params
                slots.append(slot)
            }
            tracks.append(["id": tr, "meter": [tl, trr], "plugins": slots])
        }
        info["tracks"] = tracks
        return info
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
        let info: [String: Any] = ["windows": list, "frontmost": NSApp.isActive, "time": Date().timeIntervalSince1970,
                                   "diagnostics": diagnostics()]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent("windows.json"))
        }
        lastTickNs = DispatchTime.now().uptimeNanoseconds // the dump's own time is not a stall
    }
}
