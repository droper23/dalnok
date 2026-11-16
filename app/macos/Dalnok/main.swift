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
        main = MainWindowController(session: session)
        NSApp.mainMenu = buildMenu(target: main)
        main.showWindow(nil)
        main.window?.center()
        NSApp.activate()

        do { try engine.startDevice() } catch {
            main.flash("Audio device unavailable: \(error)")
        }

        let args = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let flagValues = Set(["--snapshot", "--selftest", "--screenshots"].compactMap(value))
        let files = args.filter { !$0.hasPrefix("-") && !flagValues.contains($0) }.map { URL(fileURLWithPath: $0) }
        let snapshot = value("--snapshot").map { URL(fileURLWithPath: $0) }

        if let dir = value("--screenshots") {
            Screenshots.run(app: self, files: files, dir: URL(fileURLWithPath: dir))
            return
        }
        if let dir = value("--selftest") {
            SelfTest(app: self, files: files, workdir: URL(fileURLWithPath: dir)).run()
            return
        }
        let projects = files.filter { $0.pathExtension == "dalnok" }
        let audio = files.filter { $0.pathExtension != "dalnok" }
        if let p = projects.first { main.openProject(p) }
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
        if audio.isEmpty { finish() } else { session.importFiles(audio, completion: finish) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine.isDirty, session.length > 0, main.window?.attachedSheet == nil, !SelfTest.running else {
            return .terminateNow
        }
        main.confirmDiscard { NSApp.reply(toApplicationShouldTerminate: true) }
        // confirmDiscard's Cancel path never calls back; reply false then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if self?.main.window?.attachedSheet == nil, self?.engine.isDirty == true {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { engine.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        main?.openProject(URL(fileURLWithPath: filename))
        return true
    }
}

@MainActor
/// Window commands target the (single) window controller directly, so they work
/// and validate regardless of which window is key.
func buildMenu(target: MainWindowController) -> NSMenu {
    let bar = NSMenu()
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
        .separator(),
        item("Hide Dalnok", #selector(NSApplication.hide(_:)), "h"),
        item("Quit Dalnok", #selector(NSApplication.terminate(_:)), "q"),
    ])
    menu("File", [
        item("New", #selector(W.newDocument(_:)), "n"),
        item("Open…", #selector(W.openDocument(_:)), "o"),
        .separator(),
        item("Save", #selector(W.saveDocument(_:)), "s"),
        item("Save As…", #selector(W.saveDocumentAs(_:then:)), "s", [.command, .shift]),
        .separator(),
        item("Import Audio…", #selector(W.importAudio), "i"),
        item("Export Mix…", #selector(W.exportMix(_:)), "b"),
    ])
    menu("Edit", [
        item("Undo", #selector(W.undo(_:)), "z"),
        item("Redo", #selector(W.redo(_:)), "z", [.command, .shift]),
        .separator(),
        item("Delete", #selector(W.delete(_:)), "\u{8}", []),
        item("Split at Playhead", #selector(W.splitAtPlayhead), "t"),
    ])
    menu("Transport", [
        item("Play / Pause", #selector(W.togglePlay), " ", []),
        item("Go to Start", #selector(W.goToStart), "\r", []),
    ])
    let outputMenu = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
    outputMenu.submenu = NSMenu(title: "Output Device")
    outputMenu.submenu?.delegate = target
    menu("Audio", [outputMenu])
    menu("View", [
        item("Command Palette…", #selector(W.showCommandPalette(_:)), "k"),
        .separator(),
        item("Zoom In", #selector(W.zoomIn), "="),
        item("Zoom Out", #selector(W.zoomOut), "-"),
        item("Zoom to Fit", #selector(W.zoomToFit), "0"),
    ])
    menu("Window", [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
    ])
    return bar
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
