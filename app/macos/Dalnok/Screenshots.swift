// --screenshots <dir>: renders the documentation/parity-page screenshots from
// the real app (no mockups): empty state, arrangement during playback, palette.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
enum Screenshots {
    /// The plug-in chain galleries put on a track; DALNOK_GALLERY_CHAIN (comma-separated paths) replaces it for reviews.
    static var chain: [String] {
        ProcessInfo.processInfo.environment["DALNOK_GALLERY_CHAIN"].map { $0.split(separator: ",").map(String.init) }
            ?? ["dalnok:channel-eq", "dalnok:compressor", "au:aufx:dely:appl"]
    }

    static func png(_ view: NSView, _ url: URL) {
        guard var rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        // DALNOK_SNAPSHOT_SCALE=2: a Retina-resolution capture whatever screen (or none) the window is on.
        if let s = ProcessInfo.processInfo.environment["DALNOK_SNAPSHOT_SCALE"].flatMap(Double.init), s > 1,
           let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * s), pixelsHigh: Int(view.bounds.height * s),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            big.size = view.bounds.size
            rep = big
        }
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

    /// --gallery <dir> <project>: every screen a theme has to get right, from the real app with a generated project
    /// (the theme comes from DALNOK_THEME). Used to review and compare themes ("06 - Design/Theme System.md") and for
    /// the README. States are made through the same calls the UI makes; the recording frame shows the recording
    /// display state (no take is recorded).
    static func gallery(app: AppDelegate, project: URL?, dir: URL) {
        SelfTest.running = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = app.main!, s = app.session
        w.window?.setContentSize(NSSize(width: 1440, height: 900))
        func shot(_ name: String) {
            guard let v = w.window?.contentView else { return }
            v.layoutSubtreeIfNeeded() // nothing displays while the window is off screen or the screen is locked
            png(v, dir.appendingPathComponent("\(name).png"))
        }
        Task {
            try? await Task.sleep(for: .seconds(0.4))
            shot("01-start")
            if let project { _ = await withCheckedContinuation { cont in w.openProject(project) { cont.resume(returning: $0) } } }
            try? await Task.sleep(for: .seconds(0.6))
            let tracks = s.tracks
            // States: one muted, one soloed, two armed, one monitoring; a selected track and clip; two sections.
            if tracks.count > 6 {
                s.setMute(tracks[2].id, true)
                s.setSolo(tracks[1].id, true)
                s.setArmed(tracks[6].id, true)
                dalnok_track_set_input_monitor(s.engine.handle, tracks[6].id, true)
            }
            let bar = s.framesPerBeat * 4
            s.addMarker(at: 0, name: "Intro")
            s.addMarker(at: bar * 8, name: "Verse")
            s.addMarker(at: bar * 16, name: "Chorus")
            s.refresh()
            if tracks.count > 3 { w.headers.selectedTrack = tracks[3].id; w.timeline.selectedClip = tracks[3].clips.first?.id }
            try? await Task.sleep(for: .seconds(0.4))
            shot("02-arrangement")
            w.setOverview(true)
            try? await Task.sleep(for: .seconds(0.4))
            shot("12-composition-overview")
            w.setOverview(false)
            app.engine.seek(bar * 2)
            app.engine.play()
            try? await Task.sleep(for: .seconds(1.2))
            shot("03-playing")
            w.transport.setRecording(true)
            w.timeline.setTransportState(playing: true, recording: true)
            try? await Task.sleep(for: .seconds(0.5))
            shot("04-recording-display")
            w.transport.setRecording(false)
            w.timeline.setTransportState(playing: true, recording: false)
            let mixerWasShown = MainWindowController.showMixer
            if !MainWindowController.showMixer { w.toggleMixer(nil) }
            try? await Task.sleep(for: .seconds(1.0))
            shot("05-mixer")
            if MainWindowController.showMixer { w.toggleMixer(nil) }
            app.engine.pause()
            // A device chain of built-in plug-ins and one of Apple's Audio Units (never the owner's).
            if let t = tracks.first?.id {
                w.headers.selectedTrack = t
                for path in Screenshots.chain { _ = try? s.addPlugin(t, path: path) }
                if let comp = s.track(t)?.plugins.dropFirst().first?.id, tracks.count > 1 { dalnok_plugin_set_sidechain(s.engine.handle, t, comp, tracks[1].id) }
            }
            let devicesWereShown = MainWindowController.showDevicePanel
            if w.devicePanel.isHidden { w.toggleDevicePanel(nil) }
            app.engine.play()
            try? await Task.sleep(for: .seconds(1.2))
            shot("06-devices")
            // The README's hero frame: arrangement playing, mixer and device chain open.
            if !MainWindowController.showMixer { w.toggleMixer(nil) }
            try? await Task.sleep(for: .seconds(1.0))
            shot("00-hero")
            if MainWindowController.showMixer { w.toggleMixer(nil) }
            app.engine.pause()
            // The side panels with a library category open and a plug-in chosen.
            if !w.library.isHidden {
                // Closed and reopened, as the owner does with Y: names must draw at once (they once waited for a click).
                let motion = Motion.override
                Motion.override = true // the slide, as in use
                w.toggleLibrary(nil); try? await Task.sleep(for: .seconds(0.8))
                w.toggleLibrary(nil); try? await Task.sleep(for: .seconds(0.8))
                Motion.override = motion
                w.library.load()
                if let eq = w.library.roots.first { w.library.outline.expandItem(eq) }
                try? await Task.sleep(for: .seconds(0.4))
                shot("13-panels")
                // A long chain in the Inspector: the list's "Show all" and the folded signal path.
                if tracks.count > 1 {
                    for _ in 0..<9 { _ = try? s.addPlugin(tracks[1].id, path: "dalnok:channel-eq") }
                    w.headers.selectedTrack = tracks[1].id
                    s.refresh()
                    try? await Task.sleep(for: .seconds(0.4))
                    shot("14-inspector-long-chain")
                    w.headers.selectedTrack = tracks.first?.id
                }
                // The Files place with the project's folder open (only the generated project's files are listed).
                w.library.choose(.files)
                if let project = w.library.roots.first(where: { $0.title == "Current Project" }) {
                    w.library.outline.expandItem(project)
                    if let audio = project.children.first(where: { $0.folder != nil }) { w.library.outline.expandItem(audio) }
                }
                try? await Task.sleep(for: .seconds(0.3))
                shot("16-library-files")
                w.library.choose(.all)
            }
            w.pluginManager.show()
            w.pluginManager.filter("Dalnok")
            try? await Task.sleep(for: .seconds(0.4))
            if let v = w.pluginManager.window?.contentView { png(v, dir.appendingPathComponent("07-plugin-browser.png")) }
            w.pluginManager.window?.orderOut(nil)
            // Piano roll: chords under a running melody with varied velocities.
            let keys = s.addInstrumentTrack("Keys")
            let beat = s.framesPerBeat
            let clip = s.addMidiClip(keys, start: 0, length: beat * 16)
            var notes: [DalnokNote] = []
            for (i, chord) in [[48, 60, 64, 67, 71], [45, 57, 60, 64, 67], [41, 53, 57, 60, 64], [43, 55, 59, 62, 65]].enumerated() {
                for p in chord { notes.append(DalnokNote(start: Int64(i) * beat * 4, length: beat * 4 - beat / 8, pitch: UInt8(p), velocity: UInt8(64 + i * 14))) }
            }
            let melody = [72, 74, 76, 79, 77, 76, 74, 72, 71, 72, 74, 76, 74, 72, 71, 67]
            for (i, p) in melody.enumerated() {
                let len = i % 4 == 3 ? beat : beat / 2
                notes.append(DalnokNote(start: Int64(i) * beat, length: len, pitch: UInt8(p + 12), velocity: UInt8(50 + (i * 29) % 77)))
                if i % 2 == 1 { notes.append(DalnokNote(start: Int64(i) * beat + beat / 2, length: beat / 4, pitch: UInt8(p + 14), velocity: UInt8(40 + (i * 17) % 60))) }
            }
            s.setNotes(clip, notes)
            w.pianoRoll.show(clip: clip)
            w.pianoRoll.roll.selection = [PianoRollView.NoteKey(start: 5 * beat, pitch: 88)]
            try? await Task.sleep(for: .seconds(0.5))
            if let v = w.pianoRoll.window?.contentView { png(v, dir.appendingPathComponent("08-piano-roll.png")) }
            w.pianoRoll.window?.orderOut(nil)
            // Atelier: the five instrument figures side by side, with sample values (the modulation figure has no
            // Apple plug-in to show it in a chain).
            if Theme.look.devices == .schematic {
                // Top row at rest (as in stills); bottom row mid-motion with its first part lit, as when pointed at.
                let sheet = NSView(frame: NSRect(x: 0, y: 0, width: 5 * 250, height: 370))
                sheet.wantsLayer = true; sheet.layer?.backgroundColor = Theme.panel.cgColor
                let figs: [(FaceplateDisplay.Kind, Codex.Subject)] = [(.gainReduction, .plain), (.history, .chamber), (.history, .echo), (.transfer, .plain), (.goniometer, .modulation)]
                for (i, (kind, subject)) in figs.enumerated() + figs.enumerated().map({ ($0.offset + 5, $0.element) }) {
                    let screen: FaceplateScreen = kind == .gainReduction ? MovingCoilMeter(mode: .gainReduction) : kind == .transfer ? TransferScreen() : kind == .goniometer ? GoniometerScreen() : HistoryScreen()
                    screen.frame = NSRect(x: CGFloat(i % 5) * 250 + 7, y: i < 5 ? 190 : 10, width: 236, height: 170)
                    if i >= 5 { screen.figureAngle = 1.2; screen.highlightRole = AtelierFigure.of(kind: kind, subject: subject)?.roles.first }
                    screen.codexKind = kind; screen.codexSubject = subject; screen.figureNumber = i % 5 + 1
                    var link = FigureLink()
                    let roles = AtelierFigure.of(kind: kind, subject: subject)?.roles ?? []
                    for (k, r) in roles.enumerated() { link.ids[r] = UInt32(k + 1) }
                    link.value = { id in [0.62, 0.45][Int(id) - 1] }
                    link.text = { id in ["value \(id)", "value \(id)"][Int(id) - 1] }
                    link.letter = { id in ["A", "B"][Int(id) - 1] }
                    link.name = { id in roles[Int(id) - 1].rawValue.capitalized }
                    screen.figureLink = link
                    sheet.addSubview(screen)
                }
                let holder = NSWindow(contentRect: sheet.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                holder.contentView = sheet
                sheet.layoutSubtreeIfNeeded()
                png(sheet, dir.appendingPathComponent("15-figures.png"))
                holder.contentView = nil
            }
            // First launch: the look step (the current look marked).
            w.shortcutChooser.show()
            try? await Task.sleep(for: .seconds(0.4))
            if let v = w.shortcutChooser.window.contentView { png(v, dir.appendingPathComponent("17-first-launch.png")) }
            w.shortcutChooser.window.orderOut(nil)
            w.settings.show(.general)
            try? await Task.sleep(for: .seconds(0.4))
            if let v = w.settings.window?.contentView { png(v, dir.appendingPathComponent("09-settings.png")) }
            w.settings.window?.orderOut(nil)
            w.showCommandPalette(nil)
            w.palette.filter("mix")
            try? await Task.sleep(for: .seconds(0.3))
            if let panel = NSApp.windows.first(where: { $0 is KeyPanel }), let v = panel.contentView { png(v, dir.appendingPathComponent("10-palette.png")) }
            w.palette.close()
            // Dense at a small size: short lanes, a compact window.
            let savedHeight = UserDefaults.standard.object(forKey: "trackHeight")
            Theme.trackHeight = 48
            w.window?.setContentSize(NSSize(width: 1024, height: 640))
            s.forceRefresh()
            try? await Task.sleep(for: .seconds(0.6))
            shot("11-compact")
            if let savedHeight { UserDefaults.standard.set(savedHeight, forKey: "trackHeight") } else { UserDefaults.standard.removeObject(forKey: "trackHeight") }
            MainWindowController.showMixer = mixerWasShown
            MainWindowController.showDevicePanel = devicesWereShown
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
        // A generated project has no plug-ins: give the first two tracks a chain of built-in and Apple plug-ins
        // (never the owner's), as the gallery does, so the device panel has something to show.
        if ProcessInfo.processInfo.environment["DALNOK_TOUR_MODE"] != "plugin-ops", s.tracks.allSatisfy({ $0.plugins.isEmpty }), s.tracks.count > 1 {
            let a = s.tracks[0].id, b = s.tracks[1].id
            for path in ["dalnok:channel-eq", "dalnok:compressor", "au:aufx:dely:appl"] { _ = try? s.addPlugin(a, path: path) }
            if let comp = s.track(a)?.plugins.dropFirst().first?.id { dalnok_plugin_set_sidechain(s.engine.handle, a, comp, b) }
            for path in ["dalnok:compressor", "dalnok:channel-eq"] { _ = try? s.addPlugin(b, path: path) }
        }
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
        // DALNOK_TOUR_MODE=plugin-ops: the device panel while plug-ins are added to an empty track, turned, keyed from
        // another track, bypassed, folded and removed, over a looping 4-bar cycle. Prints the panel's screen rect.
        if ProcessInfo.processInfo.environment["DALNOK_TOUR_MODE"] == "plugin-ops",
           let target = s.tracks.first(where: { $0.name == "Pad" && $0.plugins.isEmpty }) ?? s.tracks.first(where: { $0.plugins.isEmpty && !$0.isInstrument && !$0.muted }) ?? s.tracks.first {
            let bar = s.framesPerBeat * 4
            _ = s.setCycle(true, 0, bar * 4)
            app.engine.seek(0)
            w.headers.select(target.id)
            let key = s.tracks.first(where: { $0.id != target.id && $0.name == "Kick" }) ?? s.tracks.first { $0.id != target.id }
            if let win = w.window, let screen = win.screen {
                let p = w.devicePanel.convert(w.devicePanel.bounds, to: nil), f = win.convertToScreen(p)
                print(String(format: "tour panel: %.0f %.0f %.0f %.0f", f.minX, screen.frame.height - f.maxY, f.width, f.height))
                fflush(stdout)
            }
            var eq: Int32 = 0, comp: Int32 = 0, delay: Int32 = 0
            let h = s.engine.handle
            /// Sweeps one parameter from a to b (normalized) over `secs`, as a hand turning the control would.
            func sweep(_ slot: @escaping () -> Int32, _ id: UInt32, _ a: Double, _ b: Double, at t0: Double, for secs: Double) -> [(Double, () -> Void)] {
                let n = Int(secs * 30)
                return (0...n).map { i in (t0 + Double(i) / 30, { _ = dalnok_plugin_set_parameter(h, slot(), id, a + (b - a) * Double(i) / Double(n)) }) }
            }
            var steps: [(Double, () -> Void)] = [
                (0.8, { eq = (try? s.addPlugin(target.id, path: "dalnok:channel-eq")) ?? 0 }),
                (1.6, { _ = dalnok_plugin_set_parameter(h, eq, 8, 1) }), // first peak band on
                (4.6, { comp = (try? s.addPlugin(target.id, path: "dalnok:compressor")) ?? 0 }),
                (7.8, { if let key { _ = dalnok_plugin_set_sidechain(h, target.id, comp, key.id); s.refresh() } }),
                (9.4, { s.setPluginBypassed(target.id, comp, true) }),
                (10.6, { s.setPluginBypassed(target.id, comp, false) }),
                (11.6, { s.setPluginFolded(target.id, eq, true) }),
                (12.8, { s.setPluginFolded(target.id, eq, false) }),
                (13.8, { delay = (try? s.addPlugin(target.id, path: "au:aufx:dely:appl")) ?? 0 }),
                (15.4, { s.movePlugin(target.id, delay, to: 0) }),
                (16.8, { s.removePlugin(target.id, delay) }),
                (17.8, { s.removePlugin(target.id, comp) }),
                (18.8, { s.removePlugin(target.id, eq) }),
                (23.0, { timer.invalidate(); print("tour: \(frame) frames"); fflush(stdout); exit(0) }), // after the recording ends
            ]
            steps += sweep({ eq }, 10, 0.5, 0.8, at: 1.8, for: 1.2) // peak gain up
            steps += sweep({ eq }, 9, 0.45, 0.7, at: 3.1, for: 1.2) // and its frequency
            steps += sweep({ comp }, 0, 1.0, 0.45, at: 5.4, for: 1.6) // threshold down: the meter starts moving
            steps += sweep({ comp }, 1, 0.1, 0.5, at: 7.0, for: 0.7) // ratio up
            let settle = Double(ProcessInfo.processInfo.environment["DALNOK_TOUR_DELAY"] ?? "") ?? 0
            for (t, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + settle + t) { MainActor.assumeIsolated { step() } } }
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
            // When screen-recorded (no frames written) stay up a little longer, so the recording never outlasts the window.
            (ProcessInfo.processInfo.environment["DALNOK_TOUR_FRAMES"] == "0" ? 13.0 : 9.6,
             { timer.invalidate(); print("tour: \(frame) frames in \(String(format: "%.1f", Date().timeIntervalSince(start))) s"); fflush(stdout); exit(0) }),
        ]
        let settle = Double(ProcessInfo.processInfo.environment["DALNOK_TOUR_DELAY"] ?? "") ?? 0
        for (t, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + settle + t) { MainActor.assumeIsolated { step() } } }
    }
}
