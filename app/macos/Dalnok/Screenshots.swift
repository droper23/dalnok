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
            w.settings.show()
            try? await Task.sleep(for: .seconds(0.3))
            if let v = w.settings.window?.contentView { png(v, dir.appendingPathComponent("settings.png")) }
            exit(0)
        }
    }
}
