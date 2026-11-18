// --screenshots <dir>: renders the documentation/parity-page screenshots from
// the real app (no mockups): empty state, arrangement during playback, palette.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
enum Screenshots {
    static func png(_ view: NSView, _ url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    static func run(app: AppDelegate, files: [URL], dir: URL) {
        SelfTest.running = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = app.main!
        w.window?.setContentSize(NSSize(width: 1280, height: 720))
        Task {
            try? await Task.sleep(for: .seconds(0.3))
            png(w.window!.contentView!, dir.appendingPathComponent("empty-state.png"))
            await withCheckedContinuation { cont in app.session.importFiles(files) { cont.resume() } }
            // Show fades: a slow equal-power fade-in and fade-out on the last clip.
            if let pad = app.session.tracks.last?.clips.first {
                let sr = Int64(app.engine.sampleRate)
                app.session.setFades(pad.id, fadeIn: 3 * sr, fadeOut: 4 * sr, curve: DALNOK_FADE_EQUAL_POWER)
            }
            // Show a time-stretched clip (Hats slowed by 10%).
            if app.session.tracks.count > 1, let hats = app.session.tracks[1].clips.first {
                app.session.setStretch(hats.id, length: Int64(Double(hats.length) * 1.1), rate: 1 / 1.1, pitch: 0, preservePitch: true)
            }
            // Knob states: a few pans off-center; one knob shown revealed (hover state).
            let pans: [Float] = [0, -0.35, 0.6, -0.8, 0.25]
            for (i, t) in app.session.tracks.enumerated() where i < pans.count { app.session.setPan(t.id, pans[i]) }
            if app.session.tracks.count > 2 { w.headers.rows[2].pan.previewReveal(true) }
            w.timeline.selectedClip = app.session.tracks.last?.clips.first?.id
            app.engine.seek(Int64(app.engine.sampleRate * 2))
            app.engine.play()
            try? await Task.sleep(for: .seconds(1.2))
            png(w.window!.contentView!, dir.appendingPathComponent("arrangement.png"))
            if w.headers.rows.count > 2 {
                let rows = w.headers.rows.prefix(3)
                let rect = rows.map { $0.convert($0.bounds, to: w.window!.contentView!) }.reduce(CGRect.null) { $0.union($1) }
                if let v = w.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: rect) {
                    v.cacheDisplay(in: rect, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("knobs.png"))
                }
                w.headers.rows[2].pan.previewReveal(false)
            }
            app.engine.pause()
            w.showCommandPalette(nil)
            w.palette.filter("sp")
            try? await Task.sleep(for: .seconds(0.3))
            if let panel = NSApp.windows.first(where: { $0 is KeyPanel }), let v = panel.contentView {
                png(v, dir.appendingPathComponent("command-palette.png"))
            }
            w.palette.filter("bounce")
            try? await Task.sleep(for: .seconds(0.2))
            if let panel = NSApp.windows.first(where: { $0 is KeyPanel }), let v = panel.contentView {
                png(v, dir.appendingPathComponent("palette-other-daw-words.png"))
            }
            w.palette.close()
            // Onboarding screens without personal data (the project finder lists real files, so it's excluded).
            w.welcome.show()
            w.welcome.showChooseDAW()
            try? await Task.sleep(for: .seconds(0.3))
            if let v = w.welcome.window.contentView { png(v, dir.appendingPathComponent("welcome.png")) }
            w.welcome.window.orderOut(nil)
            w.conceptGuide.show(daw: .logic)
            try? await Task.sleep(for: .seconds(0.3))
            if let v = w.conceptGuide.window.contentView { png(v, dir.appendingPathComponent("concept-guide.png")) }
            w.conceptGuide.window.orderOut(nil)
            // Piano roll with generated chords and a melody (no personal material).
            app.engine.pause()
            let keys = app.session.addInstrumentTrack("Keys")
            let beat = app.session.framesPerBeat
            let clip = app.session.addMidiClip(keys, start: 0, length: beat * 16)
            var notes: [DalnokNote] = []
            for (i, chord) in [[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]].enumerated() {
                for p in chord { notes.append(DalnokNote(start: Int64(i) * beat * 4, length: beat * 4 - beat / 8, pitch: UInt8(p), velocity: UInt8(70 + i * 12))) }
            }
            for i in 0..<16 { notes.append(DalnokNote(start: Int64(i) * beat, length: beat / 2, pitch: UInt8([72, 76, 79, 76][i % 4] + (i / 8) * 2), velocity: UInt8(60 + (i * 23) % 67))) }
            app.session.setNotes(clip, notes)
            w.pianoRoll.show(clip: clip)
            w.pianoRoll.roll.selection = [PianoRollView.NoteKey(start: 5 * beat, pitch: 76)]
            try? await Task.sleep(for: .seconds(0.4))
            if let v = w.pianoRoll.window?.contentView { png(v, dir.appendingPathComponent("piano-roll.png")) }
            w.pianoRoll.window?.orderOut(nil)
            // Filtered to Apple's built-in Audio Units so the image never lists the owner's installed plug-ins.
            w.pluginManager.show()
            w.pluginManager.filter("Apple")
            try? await Task.sleep(for: .seconds(0.3))
            if let v = w.pluginManager.window?.contentView { png(v, dir.appendingPathComponent("plugins.png")) }
            w.pluginManager.window?.orderOut(nil)
            for pane in SettingsController.Pane.allCases {
                w.settings.show(pane)
                try? await Task.sleep(for: .seconds(0.3))
                if let v = w.settings.window?.contentView {
                    png(v, dir.appendingPathComponent(pane == .general ? "settings.png" : "settings-\(pane).png"))
                }
            }
            exit(0)
        }
    }

    /// --tour <dir>: a scripted walk through the open project for the README's animations. Plays it, shows and hides
    /// the mixer, switches between tracks' plug-ins, bypasses a unit and turns it back on, while writing the window's
    /// frames (1x, as fast as it can, with their times in times.txt) as frame-0000.tiff… Then quits.
    static func tour(app: AppDelegate, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = app.main!, s = app.session
        w.window?.setFrameAutosaveName("") // don't remember the tour's window size
        let width = Double(ProcessInfo.processInfo.environment["DALNOK_TOUR_WIDTH"] ?? "") ?? 1440
        w.window?.setContentSize(NSSize(width: width, height: 900))
        w.window?.center()
        if MainWindowController.showMixer { w.toggleMixer(nil) }
        if !MainWindowController.showDevicePanel { w.toggleDevicePanel(nil) }
        let withPlugins = s.tracks.filter { !$0.plugins.isEmpty }
        let first = withPlugins.first ?? s.tracks.first
        if let first { w.headers.select(first.id) }
        app.engine.seek(0)
        app.engine.play()
        var frame = 0, times: [Double] = []
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let view = w.window?.contentView else { return }
                let size = view.bounds.size
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { return }
                rep.size = size
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.tiffRepresentation?.write(to: dir.appendingPathComponent(String(format: "frame-%04d.tiff", frame))) // fast to write
                times.append(Date().timeIntervalSince(start)) // when each frame was taken, for the GIF's timing
                try? times.map { String(format: "%.3f", $0) }.joined(separator: "\n").write(to: dir.appendingPathComponent("times.txt"), atomically: true, encoding: .utf8)
                frame += 1
            }
        }
        // DALNOK_TOUR_FRAMES=0: play the tour without writing frames (for a smooth screen recording); print where the
        // window is (top-left origin, points) so the recording can be cropped to it.
        if ProcessInfo.processInfo.environment["DALNOK_TOUR_FRAMES"] == "0" {
            if let win = w.window, let screen = win.screen {
                let f = win.frame
                print(String(format: "tour window: %.0f %.0f %.0f %.0f scale %.0f", f.minX, screen.frame.height - f.maxY, f.width, f.height, screen.backingScaleFactor))
                fflush(stdout)
            }
        } else {
            RunLoop.main.add(timer, forMode: .common)
        }
        // DALNOK_TOUR_MODE=plugins: only the device panel matters. A 4-bar cycle plays untouched (the units' meters and
        // screens move with the music), so a recording of it can be cut into a seamless loop.
        if ProcessInfo.processInfo.environment["DALNOK_TOUR_MODE"] == "plugins", let first {
            let bar = s.framesPerBeat * 4, period = Double(bar * 4) / app.engine.sampleRate
            _ = s.setCycle(true, 0, bar * 4)
            app.engine.seek(0)
            let cycles = Int(ProcessInfo.processInfo.environment["DALNOK_TOUR_CYCLES"] ?? "") ?? 3
            print(String(format: "tour period: %.3f s", period)); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(cycles) * period + 0.5) {
                MainActor.assumeIsolated { timer.invalidate(); print("tour: \(frame) frames"); fflush(stdout); exit(0) }
            }
            return
        }
        // The script: (seconds from the start, step).
        let bypassTarget = first?.plugins.first?.id
        let steps: [(Double, () -> Void)] = [
            (1.6, { w.toggleMixer(nil) }),
            (3.4, { if let t = first, let p = bypassTarget { s.setPluginBypassed(t.id, p, true) } }),
            (4.6, { if let t = first, let p = bypassTarget { s.setPluginBypassed(t.id, p, false) } }),
            (5.6, { if let other = withPlugins.dropFirst().first ?? s.tracks.first(where: { $0.isInstrument }) { w.headers.select(other.id) } }),
            (7.0, { if let first { w.headers.select(first.id) } }),
            (8.0, { w.toggleMixer(nil) }),
            (9.6, { timer.invalidate(); print("tour: \(frame) frames in \(String(format: "%.1f", Date().timeIntervalSince(start))) s"); fflush(stdout); exit(0) }),
        ]
        let settle = Double(ProcessInfo.processInfo.environment["DALNOK_TOUR_DELAY"] ?? "") ?? 0
        for (t, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + settle + t) { MainActor.assumeIsolated { step() } } }
    }
}
