// Self-test steps (Recording), split out of SelfTest.swift (A-18). The harness (check, perform, mouse) lives there.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import DalnokEngine

extension SelfTest {
    /// Recording through the real menus on the simulated input, record arm, input labels,
    /// a failed take, journal recovery, instrument tracks, MIDI clips, quantize, live MIDI and MIDI recording.
    func recordingAndMidi() async {
        let e = s.engine
        e.pause()
        check(w.saveProject(to: workdir.appendingPathComponent("recording.dalnok")), "save so takes go to the project's Audio Files")
        let audioFiles = workdir.appendingPathComponent("Audio Files")
        dalnok_engine_stop_device(e.handle) // the simulated input replaces the device during the take
        MainWindowController.simulatedInput = true
        defer { MainWindowController.simulatedInput = false }
        print("STATE countIn=\(UserDefaults.standard.bool(forKey: "countIn")) metronome=\(MainWindowController.metronomeOn) playing=\(e.isPlaying) recording=\(e.isRecording) tracks=\(s.tracks.map(\.name)) armed=\(s.tracks.filter(\.armed).map(\.name)) key=\(NSApp.keyWindow?.title ?? "nil")")
        guard let track = s.tracks.first?.id else { return check(false, "an audio track exists for recording") }
        w.headers.select(track)
        var l = [Float](repeating: 0, count: 512), r = l
        // Input Monitoring (I): the input plays through the track's strip while stopped, and the input closes again.
        do {
            check(s.track(track)?.inputMonitor == false, "Input Monitoring starts off")
            check(w.headers.row(track)?.subviews.contains { ($0 as? ToggleChip)?.toolTip?.hasPrefix("Input Monitoring") == true && !$0.isHidden } == true,
                  "audio track headers show the I button")
            check(perform("Input Monitoring", exact: true) && s.track(track)?.inputMonitor == true, "menu Track > Input Monitoring turns it on")
            let probe = [Float](repeating: 0.5, count: 512)
            var heard: Float = 0
            for _ in 0..<4 {
                check(dalnok_engine_pump_input(e.handle, probe, &l, &r, 512) == DALNOK_OK, "the input runs while a track monitors it")
                heard = l.map(abs).max() ?? 0
            }
            check(!e.isPlaying && heard > 0.05, "the monitored input is heard with the transport stopped (\(heard); meter \(e.trackMeter(track)); plugins \(s.track(track)?.plugins.map(\.name) ?? []); stack \(s.track(track)?.stack ?? -1); track \(s.track(track).map { "muted \($0.muted) solo \($0.solo) gain \($0.gainDb) out \($0.output) in \($0.inputChannel) kind \($0.kind)" } ?? "-"); solo any \(s.tracks.contains(where: \.solo)))")
            check(perform("Input Monitoring", exact: true) && s.track(track)?.inputMonitor == false, "Input Monitoring turns off")
            check(dalnok_engine_pump_input(e.handle, probe, &l, &r, 512) != DALNOK_OK, "the input closes when nothing monitors it")
        }
        // Measure Recording Latency: the simulated input hears the output 700 frames later; takes then use it.
        do {
            w.startLatencyMeasurement(input: DALNOK_SIMULATED_INPUT, channel: 0)
            var heard = [Float](repeating: 0, count: 700), finished = false
            for _ in 0..<400 where !finished {
                let input = Array(heard.prefix(512))
                heard.removeFirst(512)
                check(dalnok_engine_pump_input(e.handle, input, &l, &r, 512) == DALNOK_OK, "the measurement runs the input")
                heard += l
                finished = w.pollLatencyMeasurement()
            }
            let key = w.latencyKey(input: DALNOK_SIMULATED_INPUT)
            check(finished && w.lastLatencyResult?.measured_frames == 700 && MainWindowController.latencyOffsets[key] == 700 - Int(w.lastLatencyResult?.reported_frames ?? 0),
                  "Measure Recording Latency finds the 700-sample round trip and keeps it (\(w.lastLatencyResult?.measured_frames ?? -1))")
            check(dalnok_engine_pump_input(e.handle, [Float](repeating: 0, count: 512), &l, &r, 512) != DALNOK_OK, "the input closes after measuring")
            // Every new device stream re-measures on that input, inaudibly; here the device comes up echoing 706 late.
            check(MainWindowController.latencyChecks[key] == 0, "the measurement turns on the per-stream check on its input")
            let wasArmed = s.track(track)?.armed == true
            if !wasArmed { s.setArmed(track, true) }
            e.seek(Int64(e.sampleRate))
            check(perform("Record", exact: true) && e.isRecording, "Record opens a new stream")
            var played: [Float] = []
            for _ in 0..<150 {
                let n = played.count
                let input = (0..<512).map { i -> Float in let k = n + i - 706; return k >= 0 ? played[k] : 0 }
                dalnok_engine_pump_input(e.handle, input, &l, &r, 512)
                played += zip(l, r).map { 0.5 * ($0 + $1) }
            }
            check(perform("Stop Recording", exact: true) && !e.isRecording, "stop the take")
            var stream = DalnokLatencyResult()
            _ = dalnok_latency_auto_result(e.handle, &stream)
            check(stream.ok && stream.measured_frames == 706, "the new stream measured its own round trip (\(stream.measured_frames))")
            check(w.lastFlashText.contains("measured round trip (706 samples)"), "the take was placed with it (\(w.lastFlashText))")
            _ = perform("Undo")
            if !wasArmed { s.setArmed(track, false) }
            func checkItem() -> (NSMenu, NSMenuItem?) { // the Recording Input menu is built when it opens
                let m = NSMenu(); w.buildRecordingInputMenu(m)
                return (m, m.items.first { $0.title == "Re-measure on Every Device Start" })
            }
            let (menu, item) = checkItem()
            check(item?.state == .on && item?.isEnabled == true, "Audio > Recording Input shows Re-measure on Every Device Start, on")
            if let item { menu.performActionForItem(at: menu.index(of: item)) }
            check(MainWindowController.latencyChecks[key] == -1 && checkItem().1?.state == .off, "choosing it turns the check off")
            let (menu2, item2) = checkItem()
            if let item2 { menu2.performActionForItem(at: menu2.index(of: item2)) }
            check(MainWindowController.latencyChecks[key] == 0, "and on again")
            MainWindowController.latencyChecks = [:]
            w.syncLatencyCheck(input: DALNOK_SIMULATED_INPUT)
            e.seek(0) // back where the next step expects the playhead (the seek lands on the next cycle)
            for _ in 0..<2 { dalnok_engine_pump(e.handle, &l, &r, 512) }
            MainWindowController.latencyOffsets = [:]
        }
        check(perform("Record Enable Track") && s.track(track)?.armed == true, "menu Track > Record Enable Track arms the track")
        check(w.headers.row(track)?.inputButton.title == "IN 1", "header shows the track input (IN 1)")
        e.seek(0)
        let clipsBefore = s.track(track)?.clips.count ?? 0
        check(perform("Record", exact: true) && e.isRecording, "menu Transport > Record starts recording")
        check(menuItem("Stop Recording") != nil, "record menu item becomes Stop Recording")
        let input = [Float](repeating: 0.25, count: 512)
        for _ in 0..<20 { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        w.updateRecording()
        check(w.timeline.recording?.tracks.contains(track) == true, "timeline shows the take in progress")
        let livePeaks = w.timeline.recording?.peaks[track] ?? []
        check(livePeaks.count >= 19 * 512 / Int(DALNOK_LIVE_PEAK_FRAMES) && livePeaks.allSatisfy { abs($0 - 0.25) < 1e-6 },
              "the take's waveform draws while recording (\(livePeaks.count) peaks)")
        check(perform("Stop Recording", exact: true) && !e.isRecording, "menu Transport > Stop Recording")
        let take = s.track(track)?.clips.last
        check(s.track(track)?.clips.count == clipsBefore + 1 && (take?.length ?? 0) >= 19 * 512,
              "take placed on the armed track (\(take?.length ?? 0) frames)")
        check(FileManager.default.fileExists(atPath: audioFiles.appendingPathComponent("\(s.track(track)?.name ?? "") Take 1.wav").path),
              "take saved in the project's Audio Files")
        check(e.undoName == "Record", "recording is one undo step")
        check(perform("Undo") && s.track(track)?.clips.count == clipsBefore, "undo removes the take")
        check(perform("Redo") && s.track(track)?.clips.count == clipsBefore + 1, "redo restores the take")

        // Count-in: the transport starts a bar early with clicks; the take starts where Record was pressed.
        let bar2 = Int64(s.beatToFrame(s.barToBeat(2)).rounded())
        e.seek(bar2)
        for _ in 0..<2 { dalnok_engine_pump(e.handle, &l, &r, 512) } // let the seek land (no input session yet)
        let wasCountIn = MainWindowController.countIn
        if !wasCountIn { check(perform("Count-In") && MainWindowController.countIn, "Transport > Count-In turns it on") }
        check(perform("Record", exact: true) && e.isRecording, "count-in take starts")
        let barLength = bar2 - Int64(s.beatToFrame(s.barToBeat(1)).rounded())
        for _ in 0..<(Int(barLength) / 512 + 12) { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        check(perform("Stop Recording", exact: true), "count-in take stops")
        let counted = s.track(track)?.clips.last
        let latency = dalnok_record_latency(e.handle)
        check(counted.map { abs($0.start + latency - bar2) <= 1 } == true,
              "count-in take starts at the record position (\(counted?.start ?? -1) + latency \(latency) vs \(bar2))")
        if !wasCountIn { _ = perform("Count-In") }

        // Autopunch: only the red range is kept.
        let bar3 = Int64(s.beatToFrame(s.barToBeat(3)).rounded())
        w.timeline.punchRange = (bar2 + 1_000, bar3)
        if !MainWindowController.autopunch { check(perform("Autopunch") && MainWindowController.autopunch, "Transport > Autopunch turns it on") }
        w.timeline.punchRange = (bar2 + 1_000, bar3)
        e.seek(Int64(s.beatToFrame(s.barToBeat(1)).rounded()))
        for _ in 0..<2 { dalnok_engine_pump(e.handle, &l, &r, 512) }
        check(perform("Record", exact: true) && e.isRecording, "autopunch take starts")
        for _ in 0..<(Int(bar3 - bar2) * 2 / 512 + 20) { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        check(perform("Stop Recording", exact: true), "autopunch take stops")
        let punched = s.track(track)?.clips.last
        check(punched.map { abs($0.start + latency - (bar2 + 1_000)) <= 1 && abs($0.length - (bar3 - bar2 - 1_000)) <= 1 } == true,
              "autopunch keeps exactly the punch range (\(punched?.start ?? -1), \(punched?.length ?? -1))")
        _ = perform("Autopunch")

        // Two armed audio tracks record together: one take each, one undo step.
        if let second = s.tracks.first(where: { !$0.isInstrument && $0.id != track })?.id {
            w.headers.select(second)
            if s.track(second)?.armed != true { _ = perform("Record Enable Track") }
            check(s.track(track)?.armed == true && s.track(second)?.armed == true, "two audio tracks can be armed together")
            let before = (s.track(track)?.clips.count ?? 0, s.track(second)?.clips.count ?? 0)
            e.seek(Int64(s.beatToFrame(s.barToBeat(5)).rounded()))
            for _ in 0..<2 { dalnok_engine_pump(e.handle, &l, &r, 512) }
            check(perform("Record", exact: true) && e.isRecording, "multi-track take starts")
            for _ in 0..<12 { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
            check(perform("Stop Recording", exact: true), "multi-track take stops")
            check(s.track(track)?.clips.count == before.0 + 1 && s.track(second)?.clips.count == before.1 + 1,
                  "both armed tracks get a take")
            check(perform("Undo") && s.track(track)?.clips.count == before.0 && s.track(second)?.clips.count == before.1,
                  "one undo removes both takes")
            _ = perform("Redo")
            w.headers.select(second); _ = perform("Record Enable Track") // disarm
            w.headers.select(track)
        } else { check(false, "a second audio track for multi-track recording") }

        // Cycle recording: each pass becomes a take in a take folder; the comp editor swipes between them.
        do {
            let c0 = Int64(s.beatToFrame(s.barToBeat(8)).rounded()), c1 = Int64(s.beatToFrame(s.barToBeat(9)).rounded())
            _ = s.setCycle(true, c0, c1)
            e.seek(c0)
            for _ in 0..<2 { dalnok_engine_pump(e.handle, &l, &r, 512) }
            check(perform("Record", exact: true) && e.isRecording, "cycle take starts")
            let blocks = Int((c1 - c0) * 5 / 2 / 512) // two and a half passes
            for _ in 0..<blocks { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
            check(perform("Stop Recording", exact: true), "cycle take stops")
            _ = s.setCycle(false, c0, c1)
            let folders = s.takeFolders(track)
            check(folders.count == 1 && s.takes(folders.first ?? 0).count == 3, "a cycle take makes a folder of 3 takes (\(folders))")
            if let f = folders.first, let piece = s.track(track)?.clips.first(where: { $0.folder == f }) {
                let lane = s.tracks.firstIndex { $0.id == track } ?? 0
                let rect = w.timeline.clipRect(piece, laneY: w.timeline.laneY(lane))
                let at = w.timeline.convert(CGPoint(x: rect.minX + 8, y: rect.midY), to: nil)
                w.timeline.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: at, modifierFlags: [], timestamp: 0,
                                                              windowNumber: w.window!.windowNumber, context: nil, eventNumber: 0,
                                                              clickCount: 2, pressure: 1)!)
                w.timeline.mouseUp(with: mouse(.leftMouseUp, at))
                await wait(0.2)
                let ed = w.compEditor.view
                check(w.compEditor.window?.isVisible == true && ed.folder == f, "double-clicking a comp opens the take folder")
                ed.layoutSubtreeIfNeeded(); ed.fit()
                // Swipe across the first half of take 1.
                let y = ed.laneTop(0) + CompView.lane / 2
                let a = ed.convert(CGPoint(x: ed.x(Double(c0)) + 2, y: y), to: nil)
                let b = ed.convert(CGPoint(x: ed.x(Double(c0 + (c1 - c0) / 2)), y: y), to: nil)
                ed.mouseDown(with: mouse(.leftMouseDown, a))
                for k in 1...5 { ed.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / 5, y: a.y))) }
                ed.mouseUp(with: mouse(.leftMouseUp, b))
                let comp = s.comp(f)
                check(comp.first?.take == 0 && comp.first?.from == c0 && e.undoName == "Comp",
                      "swiping across take 1 puts it in the comp (\(comp.map { ($0.from, $0.to, $0.take) }))")
                try? w.compEditor.window?.contentView?.superview.map { v in
                    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!; v.cacheDisplay(in: v.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: workdir.appendingPathComponent("comp-editor.png"))
                }
                // Clicking a take's name uses all of it.
                let name = ed.convert(CGPoint(x: 20, y: ed.laneTop(1) + 10), to: nil)
                ed.mouseDown(with: mouse(.leftMouseDown, name)); ed.mouseUp(with: mouse(.leftMouseUp, name))
                check(s.comp(f).count == 1 && s.comp(f).first?.take == 1, "clicking Take 2 comps the whole take")
                check(perform("Undo") && s.comp(f).first?.take == 0, "undo restores the swiped comp")
                w.compEditor.window?.orderOut(nil)
            } else { check(false, "the comp shows in the arrangement") }
        }

        // Interrupted take: pausing ends it with an explanation; nothing is placed.
        let clipsBeforeInterrupted = s.track(track)?.clips.count ?? 0
        check(perform("Record", exact: true) && e.isRecording, "second take starts")
        for _ in 0..<5 { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        e.pause()
        for _ in 0..<3 { dalnok_engine_pump_input(e.handle, input, &l, &r, 512) }
        w.updateRecording()
        check(!e.isRecording && w.lastRecordingProblem == "The take was interrupted", "interrupted take is reported (\(w.lastRecordingProblem ?? "-"))")
        check(s.track(track)?.clips.count == clipsBeforeInterrupted, "interrupted take is not placed")

        // An unfinished take (as after a crash) is recovered through File > Recover Recordings.
        var spool = Data("DLNCAP01".utf8)
        withUnsafeBytes(of: UInt32(e.sampleRate).littleEndian) { spool.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(1).littleEndian) { spool.append(contentsOf: $0) }
        for _ in 0..<4_800 { withUnsafeBytes(of: Float(0.1).bitPattern.littleEndian) { spool.append(contentsOf: $0) } }
        try? spool.write(to: audioFiles.appendingPathComponent("Crash Take 1.dlncap"))
        try? #"{"format":"dalnok-take","version":1,"state":"recording","spool":"Crash Take 1.dlncap","wav":"Crash Take 1.wav"}"#
            .write(to: audioFiles.appendingPathComponent("Crash Take 1.dlntake"), atomically: true, encoding: .utf8)
        check(perform("Recover Recordings") && w.lastRecoveredTakes.map(\.lastPathComponent) == ["Crash Take 1 (recovered).wav"],
              "File > Recover Recordings recovers the unfinished take")
        do { try e.startDevice() } catch { check(false, "device restarts after recording: \(error)") }
        check(perform("Record Enable Track") && s.track(track)?.armed == false, "disarm the audio track")

        // Instrument track and MIDI clip.
        check(perform("New Instrument Track"), "menu Track > New Instrument Track")
        guard let keys = s.tracks.last, keys.isInstrument, keys.armed else { return check(false, "instrument track is armed") }
        check(w.headers.row(keys.id)?.inputButton.title == "Dalnok Poly", "instrument header names its instrument (Dalnok Poly)")
        e.seek(0)
        try? await Task.sleep(for: .milliseconds(100))
        check(perform("New MIDI Clip"), "menu Clip > New MIDI Clip")
        guard let clip = w.timeline.selectedClip, s.clip(clip)?.isMidi == true else { return check(false, "MIDI clip selected") }
        // A 16th is 6,890.625 frames at 44.1 kHz and 96 BPM: notes land on the nearest frame to each grid line.
        let exact16 = e.sampleRate * 60 / s.bpm / 4, sixteenth = Int64(exact16.rounded())
        s.setNotes(clip, [DalnokNote(start: sixteenth + 100, length: sixteenth, pitch: 60, velocity: 100),
                          DalnokNote(start: Int64((2 * exact16).rounded()) - 90, length: sixteenth, pitch: 64, velocity: 90)])
        check(perform("1/16 Notes"), "menu Clip > Quantize > 1/16 Notes")
        check(s.clip(clip)?.notes.map(\.start) == [sixteenth, Int64((2 * exact16).rounded())],
              "notes quantized to 16ths (\(s.clip(clip)?.notes.map(\.start) ?? []))")
        check(menuItem("Double Speed")?.isEnabled == false, "audio-only clip commands are disabled for MIDI clips")

        // Live MIDI through the running device: the armed instrument meters while stopped.
        dalnok_midi_inject(e.handle, 0x90, 69, 110)
        try? await Task.sleep(for: .milliseconds(300))
        let live = w.headers.row(keys.id)?.meter.levelDb.0 ?? -200
        dalnok_midi_inject(e.handle, 0x80, 69, 0)
        check(live > -40, String(format: "live MIDI plays the armed instrument (%.1f dBFS)", live))

        // MIDI recording through the menu (device clock).
        let before = s.track(keys.id)?.clips.count ?? 0
        e.seek(Int64(e.sampleRate) * 8)
        check(perform("Record", exact: true) && e.isRecording, "Record with only an instrument armed")
        try? await Task.sleep(for: .milliseconds(150))
        dalnok_midi_inject(e.handle, 0x90, 67, 100)
        try? await Task.sleep(for: .milliseconds(250))
        dalnok_midi_inject(e.handle, 0x80, 67, 0)
        try? await Task.sleep(for: .milliseconds(100))
        check(perform("Stop Recording", exact: true), "stop MIDI recording")
        let recorded = s.track(keys.id)?.clips.last
        _ = recorded
        await pianoRoll(clip: clip)
        await tempoAndMetronome()
        await cycle()
        await mixerAndRouting()
        await launcherSteps()
        check(s.track(keys.id)?.clips.count == before + 1 && recorded?.notes.count == 1 && recorded?.notes.first?.pitch == 67,
              "recorded one MIDI note (\(recorded?.notes.count ?? 0))")
        let ms = Double(recorded?.notes.first?.length ?? 0) / e.sampleRate * 1000
        check(ms > 150 && ms < 400, String(format: "recorded note length %.0f ms (held ~250 ms)", ms))
    }

    /// Piano roll through real menus, mouse gestures (synthesized events) and keys.
    /// DALNOK_TEST_AUDIO_INPUT=<input device name>: Input Monitoring and a short take on real hardware, listening on the
    /// system default output (another device), so recording must not move the output. The monitored track sits at
    /// -24 dB (little risk of feedback through speakers). Skipped without the variable.
    func realAudioInput() async {
        guard let name = ProcessInfo.processInfo.environment["DALNOK_TEST_AUDIO_INPUT"], !name.isEmpty else { return }
        guard let device = Engine.recordingDevices().first(where: { $0.name == name }) else {
            return check(false, "real audio input \(name) is connected")
        }
        let e = s.engine
        e.pause()
        MainWindowController.simulatedInput = false
        // Leave the device as found: later steps seek (applied by the audio thread) when it was running.
        let wasRunning = dalnok_engine_device_running(e.handle)
        do { try e.startDevice(); try e.setOutputDevice(nil) } catch { return check(false, "output device starts: \(error)") }
        defer { if !wasRunning { dalnok_engine_stop_device(e.handle) } }
        MainWindowController.recordingInputUID = device.uid
        w.syncInputDevice()
        let found: DalnokTrackId? = s.tracks.first(where: { !$0.isInstrument && !$0.isBus && $0.stack == 0 })?.id
        let track: DalnokTrackId = found ?? s.addTrack("Real Input")
        let gain = s.track(track)?.gainDb ?? 0
        s.setGain(track, db: -24)
        defer { s.setGain(track, db: gain) }
        w.headers.select(track)
        let outputBefore = e.outputDeviceUid
        if s.track(track)?.inputMonitor != true { _ = perform("Input Monitoring", exact: true) }
        await wait(0.6)
        var ml: Float = 0
        for _ in 0..<20 { await wait(0.1); ml = max(ml, e.trackMeter(track).0) } // a quiet room is near the meter's floor
        check(e.inputRunning && e.inputError.isEmpty, "real input: \(name) opens for Input Monitoring (\(e.inputError))")
        check(e.outputDeviceUid == outputBefore, "real input: monitoring keeps the output device")
        check(ml > 0, "real input: the monitored track's meter moves with \(name)'s input (\(ml))")
        if s.track(track)?.armed != true { _ = perform("Record Enable Track") }
        e.seek(0)
        check(perform("Record", exact: true) && e.isRecording, "real input: recording starts while monitoring")
        await wait(1.5)
        w.updateRecording()
        let peaks = w.timeline.recording?.peaks[track] ?? []
        check(peaks.count > 200 && peaks.contains { $0 > 0 }, "real input: the waveform draws while recording (\(peaks.count) peaks, max \(peaks.max() ?? 0))")
        let clipsBefore = s.track(track)?.clips.count ?? 0
        check(perform("Stop Recording", exact: true) && !e.isRecording, "real input: recording stops")
        let take = s.track(track)?.clips.last
        check(s.track(track)?.clips.count == clipsBefore + 1 && (take?.length ?? 0) > 48_000, "real input: the take is placed (\(take?.length ?? 0) frames)")
        check(e.outputDeviceUid == outputBefore, "real input: recording keeps the output device (no switch to \(name))")
        check(e.inputRunning, "real input: the input stays open after the take while the track monitors")
        _ = perform("Record Enable Track")
        _ = perform("Input Monitoring", exact: true)
        check(!e.inputRunning && s.track(track)?.inputMonitor == false, "real input: the input closes when monitoring stops")
        MainWindowController.simulatedInput = true
        w.syncInputDevice()
    }

    func pianoRoll(clip: DalnokClipId) async {
        let e = s.engine
        w.timeline.selectedClip = clip
        check(perform("Piano Roll", exact: true), "menu Clip > Piano Roll opens the editor")
        let roll = w.pianoRoll.roll
        guard let win = w.pianoRoll.window, win.isVisible, roll.clipId == clip else { return check(false, "piano roll window is visible") }
        win.makeKey()
        let pianoArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: win.windowNumber, context: nil,
                                          characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                                          charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!), isARepeat: false, keyCode: 124)!
        check(!(NSApp.mainMenu?.performKeyEquivalent(with: pianoArrow) ?? true), "arrangement nudge shortcuts do not steal piano-roll arrows")
        roll.layoutSubtreeIfNeeded()
        func ev(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, mods: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: roll.convert(p, to: nil), modifierFlags: mods,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func key(_ code: UInt16, _ chars: String, mods: NSEvent.ModifierFlags = []) {
            roll.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                                windowNumber: win.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        func drag(from a: CGPoint, to b: CGPoint, mods: NSEvent.ModifierFlags = []) {
            roll.mouseDown(with: ev(.leftMouseDown, a, mods: mods))
            for k in 1...8 { roll.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / 8, y: a.y + (b.y - a.y) * CGFloat(k) / 8), mods: mods)) }
            roll.mouseUp(with: ev(.leftMouseUp, b, mods: mods))
        }
        guard let c = s.clip(clip) else { return }
        let before = c.notes.count
        let beat = s.framesPerBeat
        // Double-click empty grid at bar 1 beat 3 of the clip, pitch D5 (74): adds a snapped note.
        let target = Double(c.start + 2 * beat) + Double(roll.snapFrames) * 0.2
        let p = CGPoint(x: roll.x(target), y: roll.y(74) + roll.rowHeight / 2)
        roll.mouseDown(with: ev(.leftMouseDown, p, clicks: 2))
        roll.mouseUp(with: ev(.leftMouseUp, p, clicks: 2))
        let added = s.clip(clip)?.notes.first { $0.pitch == 74 }
        check(s.clip(clip)?.notes.count == before + 1 && added?.start == c.offset + 2 * beat, "double-click adds a snapped note (\(added?.start ?? -1))")
        check(e.undoName == "Add Note", "adding a note is one undo step")
        guard let n = added, let cur = s.clip(clip) else { return }
        // Drag the note up two rows and right one beat: one undo step "Move Notes".
        let r = roll.rect(n, cur)
        drag(from: CGPoint(x: r.minX + 3, y: r.midY), to: CGPoint(x: r.minX + 3 + CGFloat(Double(beat) / roll.framesPerPoint), y: r.midY - 2 * roll.rowHeight))
        let moved = s.clip(clip)?.notes.first { $0.pitch == 76 && $0.start == n.start + beat }
        check(moved != nil && e.undoName == "Move Notes", "dragging a note moves it in time and pitch as one undo step")
        // Resize from its right edge.
        if let m = moved, let cur = s.clip(clip) {
            let r2 = roll.rect(m, cur)
            drag(from: CGPoint(x: r2.maxX - 2, y: r2.midY), to: CGPoint(x: r2.maxX - 2 + CGFloat(Double(beat) / roll.framesPerPoint), y: r2.midY))
            let resized = s.clip(clip)?.notes.first { $0.pitch == 76 && $0.start == m.start }
            check((resized?.length ?? 0) == m.length + beat && e.undoName == "Resize Notes", "dragging the right edge lengthens the note by a beat")
            // Velocity stem: drag up.
            if let rn = resized, let cur2 = s.clip(clip) {
                let sx = roll.x(roll.timeline(rn, cur2)) + 1
                let lane = roll.velocityLane
                let h = (lane.height - 12) * CGFloat(rn.velocity) / 127
                drag(from: CGPoint(x: sx, y: lane.maxY - 4 - h / 2), to: CGPoint(x: sx, y: lane.maxY - 4 - h / 2 - 20))
                let v = s.clip(clip)?.notes.first { $0.pitch == 76 && $0.start == rn.start }?.velocity ?? 0
                check(v > rn.velocity && e.undoName == "Note Velocity", "velocity lane drag raises velocity (\(rn.velocity) → \(v))")
            }
        }
        // Auditioning: holding the mouse on a note plays it through the track's instrument, unarmed and stopped, and
        // releasing it stops the sound (dalnok_track_preview_note).
        if dalnok_engine_device_running(e.handle), let cur = s.clip(clip), let note = cur.notes.first(where: { $0.pitch == 76 }) {
            let track = cur.track
            _ = dalnok_track_set_armed(e.handle, track, false)
            if e.isPlaying { dalnok_transport_pause(e.handle) }
            func level(over seconds: Double) async -> Float {
                var peak: Float = 0
                for _ in 0..<Int(seconds / 0.05) {
                    await wait(0.05)
                    var l: Float = 0, r: Float = 0
                    _ = dalnok_meter_track(e.handle, track, &l, &r)
                    peak = max(peak, l, r)
                }
                return peak
            }
            _ = await level(over: 0.6) // anything still ringing
            let r = roll.rect(note, cur)
            let at = CGPoint(x: r.minX + 3, y: r.midY)
            roll.mouseDown(with: ev(.leftMouseDown, at))
            let held = await level(over: 0.4)
            roll.mouseUp(with: ev(.leftMouseUp, at))
            _ = await level(over: 1.2) // the release
            let after = await level(over: 0.3)
            print(String(format: "MEASURE audition: held %.4f, after release %.5f", held, after))
            check(held > 0.01 && after < held * 0.05, "holding a note in the piano roll plays it; releasing stops it (held \(held), after \(after))")
            check(!e.isPlaying && s.clip(clip)?.notes.count == cur.notes.count, "auditioning neither starts the transport nor edits notes")
        } else {
            print("SKIP  piano-roll audition (no output device running)")
        }
        // Keys: transpose down an octave, nudge right, then delete through Edit > Delete.
        key(125, "", mods: .shift)
        check(s.clip(clip)?.notes.contains { $0.pitch == 64 && $0.start == n.start + beat } == true, "⇧↓ transposes the selection down an octave")
        key(124, "")
        check(s.clip(clip)?.notes.contains { $0.pitch == 64 && $0.start == n.start + beat + Int64(roll.snapFrames) } == true, "→ nudges by the grid")
        let count = s.clip(clip)?.notes.count ?? 0
        check(perform("Delete") && s.clip(clip)?.notes.count == count - 1, "Edit > Delete removes the selected note, not the clip")
        check(s.clip(clip) != nil, "the clip itself is untouched")
        _ = perform("Undo")
        check(s.clip(clip)?.notes.count == count, "undo restores the note")
        key(0, "a", mods: .command)
        check(roll.selection.count == s.clip(clip)?.notes.count, "⌘A selects all notes")
        if let cur = s.clip(clip), let targetNote = cur.notes.first(where: { $0.pitch == 64 && $0.start > c.offset + 2 * beat }) {
            let box = roll.rect(targetNote, cur)
            drag(from: CGPoint(x: box.minX - 3, y: box.minY - 2), to: CGPoint(x: box.maxX + 3, y: box.maxY + 2))
            check(roll.selection == [roll.key(targetNote)], "marquee selects intersecting notes")
            if let other = cur.notes.first(where: { $0.pitch == 60 }) {
                let box2 = roll.rect(other, cur)
                drag(from: CGPoint(x: box2.minX - 3, y: box2.minY - 2), to: CGPoint(x: box2.maxX + 3, y: box2.maxY + 2), mods: .shift)
                check(roll.selection.contains(roll.key(targetNote)) && roll.selection.contains(roll.key(other)), "shift-marquee adds to selection")
            } else { check(false, "shift-marquee fixture exists") }
        } else { check(false, "marquee fixture exists") }
        roll.entryFrame = Double(c.start)
        roll.entryPitch = 70
        key(124, "", mods: .option)
        key(126, "", mods: .option)
        let entry = Int64(roll.snapFrames.rounded()) // the nearest frame (a 16th is 6,890.625 frames at 44.1 kHz)
        key(36, "\r")
        check(s.clip(clip)?.notes.contains { $0.pitch == 71 && $0.start == c.offset + entry && $0.length == entry } == true,
              "option arrows and Return enter a note at the cursor")
        check(abs((roll.entryFrame ?? 0) - (Double(c.start) + 2 * roll.snapFrames)) < 1e-6, "step entry advances by the grid")
        _ = perform("Undo")
        check(s.clip(clip)?.notes.contains { $0.pitch == 71 && $0.start == c.offset + entry } == false, "undo removes the entered note")
        let originalNotes = s.clip(clip)?.notes ?? []
        let boundaryNotes = [DalnokNote(start: 0, length: entry, pitch: 126, velocity: 100),
                             DalnokNote(start: entry, length: entry, pitch: 127, velocity: 100)]
        s.setNotes(clip, boundaryNotes)
        key(0, "a", mods: .command)
        key(126, "")
        key(123, "")
        check(s.clip(clip)?.notes.map(\.pitch) == [126, 127] && s.clip(clip)?.notes.map(\.start) == [0, entry],
              "keyboard movement preserves group spacing at MIDI boundaries")
        if let current = s.clip(clip), let first = current.notes.first {
            roll.scrollY = 0
            let r = roll.rect(first, current)
            drag(from: CGPoint(x: r.minX + 2, y: r.midY), to: CGPoint(x: r.minX - 30, y: r.midY - roll.rowHeight * 4))
            check(s.clip(clip)?.notes.map(\.pitch) == [126, 127] && s.clip(clip)?.notes.map(\.start) == [0, entry],
                  "drag preserves group spacing at MIDI boundaries")
        }
        s.setNotes(clip, originalNotes)
        win.close()
        check(!w.pianoRollIsKey, "closing the piano roll returns Delete to the arrangement")
        w.window?.makeKey()
    }
}
