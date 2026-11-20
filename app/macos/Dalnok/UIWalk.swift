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
            if ProcessInfo.processInfo.environment["DALNOK_AUDIT_UI"] == "1" { exit(await auditUI() ? 0 : 2) }
            await walk()
            NSApp.terminate(nil)
        }
    }

    // Audit-only: synchronous AppKit event and refresh costs on the loaded project.
    private func auditUI() async -> Bool {
        guard let win = w.window else { print("AUDIT ERROR no window"); return false }
        win.makeKeyAndOrderFront(nil)
        await pause(600)
        let wasShown = MainWindowController.showMixer
        if !wasShown { w.toggleMixer(nil) }
        defer { if !wasShown { w.toggleMixer(nil) } }
        await pause(300)
        guard let strip = w.mixer.strips.first, let track = s.tracks.first else { print("AUDIT ERROR no strip"); return false }
        let clips = s.allTracks.reduce(0) { $0 + $1.clips.count }
        guard s.tracks.count == 16 && clips == 4096 else { print("AUDIT ERROR fixture \(s.tracks.count) tracks \(clips) clips"); return false }
        var initial = DalnokTrackInfo()
        guard dalnok_track_info(s.h, track.id, &initial) == DALNOK_OK else { print("AUDIT ERROR no track"); return false }
        let initialRevision = dalnok_model_revision(s.h)
        let fader = strip.fader
        let start = point(fader, CGPoint(x: fader.bounds.midX, y: fader.bounds.midY))
        mouse(.leftMouseDown, win, start)
        var events: [Double] = [], refreshes: [Double] = []
        for i in 0..<130 {
            let p = CGPoint(x: start.x, y: start.y + CGFloat((i % 80) - 40))
            let t = DispatchTime.now().uptimeNanoseconds
            mouse(.leftMouseDragged, win, p)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
            if i >= 30 { events.append(ms) }
        }
        mouse(.leftMouseUp, win, start)
        var afterDrag = DalnokTrackInfo()
        guard dalnok_track_info(s.h, track.id, &afterDrag) == DALNOK_OK,
              dalnok_model_revision(s.h) >= initialRevision + 100, afterDrag.gain_db != initial.gain_db else {
            print("AUDIT ERROR drag events did not change gain"); return false
        }
        // Change engine values directly to measure the complete refresh callback,
        // independently of the synchronous drag event cost in the old version.
        for i in 0..<130 {
            _ = dalnok_track_set_gain_db(s.h, track.id, Float(-(i % 20)))
            let t = DispatchTime.now().uptimeNanoseconds
            s.refresh(onDisplayTick: true)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
            if i >= 30 { refreshes.append(ms) }
        }
        // A-05: a structural edit to one track, then the full refresh callback (session read + view updates).
        // Baseline: the same edit followed by a rebuild with the per-track cache dropped (every track re-read).
        var oneTrack: [Double] = [], allTracks: [Double] = []
        let clip = s.allTracks[0].clips[0].id
        s.refresh()
        for full in [false, true] { // separate runs: a forced rebuild empties the cache the other series relies on
            for i in 0..<130 {
                var ids = [clip]
                _ = dalnok_clips_nudge(s.h, &ids, 1, i % 2 == 0 ? 480 : -480)
                let t = DispatchTime.now().uptimeNanoseconds
                if full { s.forceRefresh() } else { s.refresh() }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
                if i >= 30 { if full { allTracks.append(ms) } else { oneTrack.append(ms) } }
            }
        }
        // Drawing (the remaining audit gap): the same three cases, each followed by drawing everything that changed in
        // this process (displayIfNeeded) and committing the layer tree to the window server (CATransaction.flush).
        // The window server's own compositing runs in another process and is not included.
        func drawn() { win.displayIfNeeded(); CATransaction.flush() }
        drawn()
        var dragDraw: [Double] = [], refreshDraw: [Double] = [], oneTrackDraw: [Double] = []
        // Main-thread CPU time per tick: what is left of the wall time is waiting (mostly on the window server).
        func cpuMs() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) * 1e3 + Double(t.tv_nsec) / 1e6 }
        var dragCPU: [Double] = [], refreshCPU: [Double] = [], oneTrackCPU: [Double] = []
        mouse(.leftMouseDown, win, start)
        let timelineCallsBefore = w.timeline.drawCalls, timelineSecondsBefore = w.timeline.drawSeconds
        for i in 0..<130 {
            let p = CGPoint(x: start.x, y: start.y + CGFloat((i % 80) - 40))
            let t = DispatchTime.now().uptimeNanoseconds, c = cpuMs()
            mouse(.leftMouseDragged, win, p)
            s.refresh(onDisplayTick: true) // what the display tick does with the drag's edit
            drawn()
            if i >= 30 { dragDraw.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6); dragCPU.append(cpuMs() - c) }
        }
        mouse(.leftMouseUp, win, start)
        // A volume drag must not redraw the arrangement.
        print(String(format: "AUDIT fader drag + draw: the timeline drew %d times (%.1f ms) in 130 ticks",
                     w.timeline.drawCalls - timelineCallsBefore, (w.timeline.drawSeconds - timelineSecondsBefore) * 1000))
        for i in 0..<130 {
            _ = dalnok_track_set_gain_db(s.h, track.id, Float(-(i % 20)))
            let t = DispatchTime.now().uptimeNanoseconds, c = cpuMs()
            s.refresh(onDisplayTick: true)
            drawn()
            if i >= 30 { refreshDraw.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6); refreshCPU.append(cpuMs() - c) }
        }
        for i in 0..<130 {
            var ids = [clip]
            _ = dalnok_clips_nudge(s.h, &ids, 1, i % 2 == 0 ? 480 : -480)
            let t = DispatchTime.now().uptimeNanoseconds, c = cpuMs()
            s.refresh()
            drawn()
            if i >= 30 { oneTrackDraw.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6); oneTrackCPU.append(cpuMs() - c) }
        }
        // Where the structural case's drawing goes: layout, view drawing and the layer commit, timed separately.
        do {
            var lay: [Double] = [], disp: [Double] = [], flush: [Double] = [], timelineDraw: [Double] = [], lanes: [Int] = []
            var calls = 0
            for i in 0..<40 {
                var ids = [clip]
                _ = dalnok_clips_nudge(s.h, &ids, 1, i % 2 == 0 ? 480 : -480)
                s.refresh()
                var t = DispatchTime.now().uptimeNanoseconds
                win.layoutIfNeeded()
                lay.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
                t = DispatchTime.now().uptimeNanoseconds
                win.displayIfNeeded()
                disp.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
                t = DispatchTime.now().uptimeNanoseconds
                let drawnBefore = w.timeline.drawSeconds, callsBefore = w.timeline.drawCalls
                CATransaction.flush()
                flush.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
                timelineDraw.append((w.timeline.drawSeconds - drawnBefore) * 1000)
                calls += w.timeline.drawCalls - callsBefore
                lanes.append(w.timeline.lanesDrawn)
            }
            func med(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
            // Correctness of the partial redraw: after an edit drawn through the normal commit (one lane), the timeline's
            // layer must equal the whole view drawn from scratch into an identical offscreen context.
            let tl = w.timeline
            func context() -> CGContext? {
                let scale = win.backingScaleFactor, pw = Int(tl.bounds.width * scale), ph = Int(tl.bounds.height * scale)
                guard pw > 0, ph > 0, let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return nil }
                ctx.scaleBy(x: scale, y: scale)
                return ctx
            }
            func bytes(_ ctx: CGContext) -> Data { Data(bytes: ctx.data!, count: ctx.bytesPerRow * ctx.height) }
            func committed() -> Data? { guard let layer = tl.layer, let ctx = context() else { return nil }; layer.render(in: ctx); return bytes(ctx) }
            var flipFresh = false // the layer capture is already in the view's orientation (calibrated below)
            func drawnFresh() -> Data? {
                guard let ctx = context() else { return nil }
                if flipFresh { ctx.translateBy(x: 0, y: tl.bounds.height); ctx.scaleBy(x: 1, y: -1) }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: tl.isFlipped)
                tl.draw(tl.bounds)
                NSGraphicsContext.restoreGraphicsState()
                return bytes(ctx)
            }
            func differing(_ a: Data, _ b: Data) -> Int {
                guard a.count == b.count else { return Int.max }
                var n = 0
                a.withUnsafeBytes { x in b.withUnsafeBytes { y in for k in 0..<x.count where abs(Int(x[k]) - Int(y[k])) > 2 { n += 1 } } }
                return n
            }
            // Calibrate on a full redraw: the two capture paths differ slightly even then (text rasterization).
            for _ in 0..<2 { tl.needsDisplay = true; win.displayIfNeeded(); CATransaction.flush() }
            var baseline = Int.max
            if let full = committed(), let fresh = drawnFresh() { baseline = differing(full, fresh) }
            _ = flipFresh
            var equal = 0, laneCounts: [Int] = [], worst = 0
            for i in 0..<10 {
                var ids = [clip]
                _ = dalnok_clips_nudge(s.h, &ids, 1, i % 2 == 0 ? 480 : -480)
                s.refresh(); win.displayIfNeeded(); CATransaction.flush()
                let lanes = tl.lanesDrawn
                guard let partial = committed() else { continue }
                let fresh = drawnFresh() // draws every lane; it does not touch the layer or the dirty region
                laneCounts.append(lanes)
                if let fresh, fresh.count == partial.count {
                    var differ = 0
                    partial.withUnsafeBytes { a in fresh.withUnsafeBytes { b in
                        for k in 0..<a.count where abs(Int(a[k]) - Int(b[k])) > 2 { differ += 1 } // 2/255: rounding between the two paths
                    } }
                    worst = max(worst, differ)
                    if lanes == 1 && differ <= baseline { equal += 1 }
                }
            }
            print("AUDIT partial timeline redraw: \(equal) of 10 one-lane redraws no further from a fresh full draw than a full redraw is (lanes drawn \(laneCounts); differing bytes: full redraw \(baseline), worst partial \(worst) of \(Int(tl.bounds.width * win.backingScaleFactor * tl.bounds.height * win.backingScaleFactor) * 4))")
            var mixerMs: [Double] = [], panelMs: [Double] = []
            for _ in 0..<20 {
                var t = DispatchTime.now().uptimeNanoseconds
                w.mixer.rebuild(); win.layoutIfNeeded(); win.displayIfNeeded(); CATransaction.flush()
                mixerMs.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
                t = DispatchTime.now().uptimeNanoseconds
                w.devicePanel.rebuild(); win.layoutIfNeeded(); win.displayIfNeeded(); CATransaction.flush()
                panelMs.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
            }
            print(String(format: "AUDIT rebuild + draw p50: mixer %.3f ms, device panel %.3f ms", med(mixerMs), med(panelMs)))
            print(String(format: "AUDIT structural drawing split p50: layout %.3f ms, display %.3f ms, layer commit %.3f ms (of which timeline draw %.3f ms, %d draw calls in 40 commits, lanes drawn %d)",
                         med(lay), med(disp), med(flush), med(timelineDraw), calls, lanes.sorted()[lanes.count / 2]))
        }
        func show(_ name: String, _ values: [Double]) {
            let sorted = values.sorted()
            func pct(_ p: Double) -> Double { sorted[Int((Double(sorted.count - 1) * p).rounded())] }
            print(String(format: "AUDIT %@ n=%d p50=%.6f ms p95=%.6f ms p99=%.6f ms max=%.6f ms", name, sorted.count, pct(0.5), pct(0.95), pct(0.99), sorted.last!))
        }
        print("AUDIT 16 tracks 4096 clips; mixer visible; 30 warmup + 100 samples; synchronous callbacks included; deferred drawing/compositing excluded")
        show("AppKit drag event", events)
        show("AppKit parameter refresh", refreshes)
        show("AppKit structural refresh, one track re-read", oneTrack)
        show("AppKit structural refresh, all tracks re-read (pre-A-05)", allTracks)
        print("AUDIT drawing included: the same cases plus displayIfNeeded and CATransaction.flush (window-server compositing excluded)")
        show("AppKit drag event + display-tick refresh + drawing", dragDraw)
        show("AppKit parameter refresh + drawing", refreshDraw)
        show("AppKit structural refresh (one track) + drawing", oneTrackDraw)
        func med(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        print(String(format: "AUDIT main-thread CPU p50 of those wall times: drag %.3f of %.3f ms, parameter %.3f of %.3f ms, structural %.3f of %.3f ms (the rest is waiting, mostly on the window server)",
                     med(dragCPU), med(dragDraw), med(refreshCPU), med(refreshDraw), med(oneTrackCPU), med(oneTrackDraw)))
        fflush(stdout)
        return true
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
            await pause(); shot("gain-undo")
            _ = dalnok_track_set_gain_db(s.h, row.trackId, -9)
            await pause(); shot("gain-script")
            _ = dalnok_undo(s.h)
            await pause()
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

        // Automation view with a few curves.
        if s.tracks.count > 3 {
            let bar = { (b: Int) in Int64(self.s.beatToFrame(self.s.barToBeat(b)).rounded()) }
            s.setAutomation(s.tracks[2].id, 0, [DalnokAutoPoint(frame: 0, value: -20), DalnokAutoPoint(frame: bar(4), value: 0),
                                                 DalnokAutoPoint(frame: bar(8), value: 0), DalnokAutoPoint(frame: bar(12), value: -40)])
            s.setAutomation(s.tracks[0].id, 0, [DalnokAutoPoint(frame: bar(2), value: -6), DalnokAutoPoint(frame: bar(6), value: 3)])
        }
        w.toggleAutomation(nil)
        await pause(200); shot("automation")
        w.toggleAutomation(nil)

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
