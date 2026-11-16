// Atrium — application entry point.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Usage: Atrium [audio files...] [--snapshot out.png] [--play]
//   --snapshot  after importing, render the window to a PNG and quit (UI checks)
//   --play      start playback after importing
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()
    lazy var session = Session(engine: engine)
    var main: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        main = MainWindowController(session: session)
        main.showWindow(nil)
        main.window?.center()
        NSApp.activate()

        do { try engine.startDevice() } catch {
            main.transport.statusLabel.stringValue = "Audio device unavailable: \(error)"
        }

        let args = Array(CommandLine.arguments.dropFirst())
        var files: [URL] = []
        var snapshot: URL?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--snapshot" where i + 1 < args.count: snapshot = URL(fileURLWithPath: args[i + 1]); i += 1
            case "--play": break
            case let a where !a.hasPrefix("-"): files.append(URL(fileURLWithPath: a))
            default: break
            }
            i += 1
        }
        let play = args.contains("--play")
        if !files.isEmpty {
            session.importFiles(files) { [weak self] in
                guard let self else { return }
                if play { engine.play() }
                if let snapshot {
                    // Let layout and a few playhead ticks happen first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + (play ? 1.5 : 0.4)) {
                        do { try self.main.snapshot(to: snapshot); print("snapshot: \(snapshot.path)") }
                        catch { print("snapshot failed: \(error)") }
                        let s = self.engine.stats()
                        print("engine: callbacks=\(s.callbacks) overloads=\(s.overloads) position=\(self.engine.position)")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { engine.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem()
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            top.submenu = m
            bar.addItem(top)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            return it
        }
        menu("Atrium", [
            item("About Atrium", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide Atrium", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Atrium", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [item("Import Audio…", #selector(MainWindowController.importAudio), "i")])
        menu("Transport", [
            item("Play / Pause", #selector(MainWindowController.togglePlay), " ", []),
            item("Go to Start", #selector(MainWindowController.goToStart), "\r", []),
        ])
        menu("View", [
            item("Zoom In", #selector(MainWindowController.zoomIn), "="),
            item("Zoom Out", #selector(MainWindowController.zoomOut), "-"),
            item("Zoom to Fit", #selector(MainWindowController.zoomToFit), "0"),
        ])
        menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        NSApp.mainMenu = bar
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
