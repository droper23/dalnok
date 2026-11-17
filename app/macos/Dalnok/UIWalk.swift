// Visual review walk: `Dalnok <project> --uiwalk <dir>` drives the app with real NSEvents sent through
// each window (hit-testing, responder chain and key equivalents included) and writes a PNG of every
// visible window after each step, including in the middle of drags. For design review, not a test.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class UIWalk {
    let app: AppDelegate
    let dir: URL
    private var step = 0
    private var w: MainWindowController { app.main }
    private var s: Session { app.session }

    init(app: AppDelegate, dir: URL) {
        self.app = app
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func run() {
        Task { @MainActor in
            await walk()
            NSApp.terminate(nil)
        }
    }

    // MARK: Events

    private func pause(_ ms: Int = 120) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private func shot(_ name: String) {
        step += 1
        let prefix = String(format: "%02d-%@", step, name)
        for win in NSApp.windows where win.isVisible {
            guard let view = win.contentView?.superview ?? win.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let title = win === w.window ? "main" : (win.title.isEmpty ? String(describing: type(of: win)) : win.title)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("\(prefix)-\(title.replacingOccurrences(of: "/", with: "-")).png"))
        }
    }

    private func point(_ view: NSView, _ p: CGPoint) -> CGPoint { view.convert(p, to: nil) }

    private func mouse(_ type: NSEvent.EventType, _ win: NSWindow, _ p: CGPoint, mods: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                         pressure: 1) else { return }
        // With the screen locked the window can't become key and AppKit swallows clicks as activation clicks,
        // so deliver like a key window would: hit-test on mouse-down, then send the gesture to that view.
        if win.isKeyWindow { win.sendEvent(e); return }
        switch type {
        case .leftMouseDown:
            mouseTarget = (win.contentView?.superview ?? win.contentView)?.hitTest(p) // window coordinates
            if let t = mouseTarget, t.acceptsFirstResponder { win.makeFirstResponder(t) }
            mouseTarget?.mouseDown(with: e)
        case .leftMouseDragged: mouseTarget?.mouseDragged(with: e)
        case .leftMouseUp: mouseTarget?.mouseUp(with: e); mouseTarget = nil
        default: win.sendEvent(e)
        }
    }
    private var mouseTarget: NSView?

    private func click(_ view: NSView, _ p: CGPoint, mods: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        guard let win = view.window else { return }
        let at = point(view, p)
        if ProcessInfo.processInfo.environment["DALNOK_WALK_DEBUG"] != nil {
            let hit = win.contentView?.superview?.hitTest(at) ?? win.contentView?.hitTest(at)
            print("click \(type(of: view)) at \(at) hits \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nil") key=\(win.isKeyWindow)")
        }
        for c in 1...clicks {
            mouse(.leftMouseDown, win, at, mods: mods, clicks: c)
            mouse(.leftMouseUp, win, at, mods: mods, clicks: c)
        }
    }

    /// Drags in `steps` moves; `shotAt` names a picture taken partway through.
    private func drag(_ view: NSView, _ from: CGPoint, _ to: CGPoint, mods: NSEvent.ModifierFlags = [], shotAt: String? = nil) async {
        guard let win = view.window else { return }
        let a = point(view, from), b = point(view, to)
        mouse(.leftMouseDown, win, a, mods: mods)
        for k in 1...12 {
            mouse(.leftMouseDragged, win, CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / 12, y: a.y + (b.y - a.y) * CGFloat(k) / 12), mods: mods)
            if k == 9, let name = shotAt { await pause(60); shot(name) }
        }
        mouse(.leftMouseUp, win, b, mods: mods)
        await pause()
    }

    private func key(_ chars: String, code: UInt16, mods: NSEvent.ModifierFlags = [], in win: NSWindow? = nil) {
        let front = NSApp.windows.last { $0.isVisible && $0 is NSPanel && $0.canBecomeKey }
        guard let win = win ?? NSApp.keyWindow ?? front ?? w.window,
              let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: win.windowNumber, context: nil, characters: chars,
                                          charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code),
              let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: win.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        if !mods.intersection([.command, .control, .option]).isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: down) == true { return }
        if win.isKeyWindow { NSApp.sendEvent(down); NSApp.sendEvent(up); return }
        if let r = win.firstResponder, r !== win { r.keyDown(with: down); r.keyUp(with: up) }
        else if NSApp.mainMenu?.performKeyEquivalent(with: down) != true { win.keyDown(with: down) }
    }

    private func typeText(_ text: String) {
        for ch in text { key(String(ch), code: 0) }
    }

    private func subviews<T: NSView>(of view: NSView, _ t: T.Type) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + subviews(of: $0, t) }
    }

    // MARK: The walk

    private func walk() async {
        guard let win = w.window else { return }
        win.makeKeyAndOrderFront(nil)
        await pause(600)
        shot("arrangement")
        let tl = w.timeline

        // Select a clip, then marquee across tracks (picture mid-drag).
        if let track = s.tracks.first, let clip = track.clips.first {
            let r = tl.clipRect(clip, laneY: tl.laneY(0))
            click(tl, CGPoint(x: r.midX, y: r.midY))
            await pause(); shot("clip-selected")
            await drag(tl, CGPoint(x: r.midX, y: r.maxY - 2), CGPoint(x: r.midX, y: r.maxY + 2), shotAt: nil) // tiny: should not move much
            key("z", code: 6, mods: .command)
        }
        let lanesBottom = tl.laneY(min(3, max(0, s.tracks.count - 1))) + Theme.trackHeight - 6
        await drag(tl, CGPoint(x: tl.bounds.maxX - 40, y: tl.laneY(0) + 4), CGPoint(x: tl.bounds.midX * 0.6, y: lanesBottom), shotAt: "marquee")
        shot("marquee-done")
        click(tl, CGPoint(x: tl.bounds.maxX - 30, y: tl.bounds.maxY - 30)) // empty: deselect + seek

        // Fade handle drag on the first audio clip.
        if let (i, track) = s.tracks.enumerated().first(where: { !$0.element.isInstrument && !$0.element.clips.isEmpty }),
           let clip = track.clips.first {
            let r = tl.clipRect(clip, laneY: tl.laneY(i))
            await drag(tl, CGPoint(x: r.minX + 2, y: r.minY + 3), CGPoint(x: r.minX + 80, y: r.minY + 3), shotAt: "fade-drag")
            key("z", code: 6, mods: .command)
        }

        // Track header controls: arm, mute, solo, gain knob drag (mid-drag picture), rename.
        if let row = w.headers.rows.first {
            for chip in subviews(of: row, ToggleChip.self) { click(chip, CGPoint(x: chip.bounds.midX, y: chip.bounds.midY)) }
            await pause(); shot("header-chips-on")
            for chip in subviews(of: row, ToggleChip.self) { click(chip, CGPoint(x: chip.bounds.midX, y: chip.bounds.midY)) }
            let g = row.gain
            await drag(g, CGPoint(x: g.bounds.midX, y: g.bounds.midY), CGPoint(x: g.bounds.midX, y: g.bounds.midY + 40), shotAt: "gain-drag")
            key("z", code: 6, mods: .command)
            click(row.nameLabel, CGPoint(x: row.nameLabel.bounds.midX, y: row.nameLabel.bounds.midY), clicks: 2)
            await pause(); shot("rename")
            key("\u{1b}", code: 53)
        }

        // Command palette with a query.
        key("k", code: 40, mods: .command)
        await pause(200)
        typeText("tempo")
        await pause(150); shot("palette")
        key("\u{1b}", code: 53)
        await pause()

        // Tempo and meter changes on the ruler.
        s.engine.seek(Int64(s.beatToFrame(16)))
        await pause()
        _ = s.setTempoMap([DalnokTempoPoint(beat: 0, bpm: 120), DalnokTempoPoint(beat: 16, bpm: 90)],
                          [DalnokMeterPoint(bar: 0, numerator: 4, denominator: 4), DalnokMeterPoint(bar: 8, numerator: 7, denominator: 8)])
        await pause(); shot("tempo-changes")
        key("z", code: 6, mods: .command)

        // Playback (meters, playhead, LCD).
        s.engine.seek(0)
        key(" ", code: 49)
        await pause(1_500); shot("playing")
        key(" ", code: 49)
        await pause(300)

        // Zoom in and out.
        for _ in 0..<3 { w.zoomIn() }
        await pause(); shot("zoomed-in")
        w.zoomToFit()
        for _ in 0..<2 { w.zoomOut() }
        await pause(); shot("zoomed-out")
        w.zoomToFit()

        // Piano roll: double-click a MIDI clip, select notes by marquee, drag velocity.
        if let (i, track) = s.tracks.enumerated().first(where: { $0.element.clips.contains { $0.isMidi } }),
           let clip = track.clips.first(where: { $0.isMidi }) {
            let r = tl.clipRect(clip, laneY: tl.laneY(i))
            click(tl, CGPoint(x: r.minX + 30, y: r.midY), clicks: 2)
            await pause(500)
            if let pr = w.pianoRoll.window, pr.isVisible {
                shot("piano-roll")
                let roll = w.pianoRoll.roll
                let g = roll.grid
                await drag(roll, CGPoint(x: g.minX + 10, y: g.minY + 10), CGPoint(x: g.midX, y: g.maxY - 10), shotAt: "piano-marquee")
                let lane = roll.velocityLane
                await drag(roll, CGPoint(x: lane.minX + 60, y: lane.midY), CGPoint(x: lane.minX + 60, y: lane.minY + 8), shotAt: "velocity-drag")
                pr.orderOut(nil)
            }
        }

        // Device panel with an Apple effect, its plug-in window and generic parameters.
        if let first = s.tracks.first {
            w.headers.select(first.id)
            let added = (try? s.addPlugin(first.id, path: "au:aufx:dely:appl")) ?? 0
            await pause(600); shot("device-panel")
            if added > 0 { w.openPluginWindow(track: first.id, slot: added); await pause(800); shot("plugin-window") }
            for pw in w.pluginWindows.values { pw.window?.orderOut(nil) }
        }

        // Mixer: strips with routing; drag a fader (mid-drag picture).
        let mixerWasShown = MainWindowController.showMixer
        if !mixerWasShown { w.toggleMixer(nil) }
        await pause(500)
        shot("mixer")
        if let strip = w.mixer.strips.first {
            let f = strip.fader
            await drag(f, CGPoint(x: f.bounds.midX, y: f.bounds.height * 0.3), CGPoint(x: f.bounds.midX, y: f.bounds.height * 0.6), shotAt: "mixer-fader-drag")
            key("z", code: 6, mods: .command)
        }
        if !mixerWasShown { w.toggleMixer(nil) }

        // Secondary windows.
        w.showSettings(nil); await pause(300); shot("settings"); w.settings.window?.orderOut(nil)
        w.showPlugins(nil); await pause(600); shot("plugin-manager"); w.pluginManager.window?.orderOut(nil)
        w.showConceptGuide(nil); await pause(300); shot("concept-guide"); w.conceptGuide.window.orderOut(nil)
        w.welcome.show(); await pause(300); shot("welcome"); w.welcome.window.orderOut(nil)
        s.newProject(); await pause(400); shot("empty-state")
    }
}
