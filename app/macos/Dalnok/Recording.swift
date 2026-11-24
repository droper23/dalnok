// Recording, record arm, inputs, instrument tracks and MIDI commands for the main window.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import DalnokEngine

@MainActor
extension MainWindowController {
    // MARK: Preferences and locations

    static var recordingInputUID: String? {
        get { UserDefaults.standard.string(forKey: "recordingInputUID") }
        set { UserDefaults.standard.set(newValue, forKey: "recordingInputUID") }
    }
    /// Recordings for unsaved projects; saved projects record into "<project folder>/Audio Files".
    static var scratchRecordingFolder: URL {
        if let override = ProcessInfo.processInfo.environment["DALNOK_RECORDINGS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
                FileManager.default.temporaryDirectory).appendingPathComponent("Dalnok/Recordings", isDirectory: true)
    }
    var recordingFolder: URL {
        session.projectURL.map { $0.deletingLastPathComponent().appendingPathComponent("Audio Files", isDirectory: true) }
            ?? Self.scratchRecordingFolder
    }

    /// The device recordings come from: the saved choice, else the current output if it has inputs, else the
    /// system's default input, else the first.
    var recordingDevice: Engine.InputDevice? {
        let devices = Engine.recordingDevices()
        if let uid = Self.recordingInputUID, let d = devices.first(where: { $0.uid == uid }) { return d }
        if let d = devices.first(where: { $0.uid == session.engine.outputDeviceUid }) { return d }
        return devices.first(where: \.isDefault) ?? devices.first
    }

    /// Tells the engine which input monitored tracks hear (it opens the device only while something monitors).
    func syncInputDevice() {
        let uid = Self.simulatedInput ? DALNOK_SIMULATED_INPUT : recordingDevice?.uid
        syncLatencyCheck(input: uid)
        do { try session.engine.setInputDevice(uid) } catch {
            flash("Input monitoring unavailable: \(error)")
        }
    }

    // MARK: Record

    static var countIn: Bool {
        get { UserDefaults.standard.bool(forKey: "countIn") }
        set { UserDefaults.standard.set(newValue, forKey: "countIn") }
    }
    static var autopunch = false

    /// Transport ▸ Count-In (⇧K): recording starts one bar early with clicks; the take starts where you pressed Record.
    @objc func toggleCountIn(_ sender: Any?) {
        Self.countIn.toggle()
        syncViewButtons()
        flash(Self.countIn ? "Count-in on: one bar of clicks before recording" : "Count-in off")
    }
    /// Transport ▸ Autopunch: record only inside the red punch range (from the cycle, the selection, or 4 bars).
    @objc func toggleAutopunch(_ sender: Any?) {
        Self.autopunch.toggle()
        if Self.autopunch && timeline.punchRange == nil { setPunchToCycle(nil) }
        timeline.showPunch = Self.autopunch
        flash(Self.autopunch ? "Autopunch on: recording keeps only the red range" : "Autopunch off")
    }
    /// Transport ▸ Set Punch to Cycle: the punch range copies the cycle (or the selected clips, or 4 bars).
    @objc func setPunchToCycle(_ sender: Any?) {
        let c = session.cycle
        if c.end > c.start { timeline.punchRange = (c.start, c.end) }
        else {
            setCycleToSelection(nil)
            let n = session.cycle
            timeline.punchRange = (n.start, n.end)
            _ = session.setCycle(false, n.start, n.end)
        }
        if !Self.autopunch { Self.autopunch = true; timeline.showPunch = true }
    }

    @objc func toggleRecord(_ sender: Any?) {
        session.engine.isRecording ? finishRecording() : beginRecording()
    }

    /// A slot's record mark (clip launcher): record the armed tracks straight into slot `k`, or stop that take.
    /// Takes started this way go back to where takes went before (the arrangement, usually) when they finish.
    func recordIntoSlot(_ k: Int) {
        let h = session.engine.handle
        if session.engine.isRecording {
            if dalnok_record_slot(h) == Int32(k) { finishRecording() }
            else { flash("Already recording: stop this take first") }
            return
        }
        restoreRecordSlot = dalnok_record_slot(h)
        dalnok_record_set_slot(h, Int32(k))
        beginRecording()
        if !session.engine.isRecording && AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined, let r = restoreRecordSlot {
            dalnok_record_set_slot(h, r); restoreRecordSlot = nil
        }
        launcher.needsDisplay = true
    }

    func beginRecording() {
        let e = session.engine
        // Nothing armed: record on the selected track, like most DAWs.
        if !session.tracks.contains(where: \.armed), let sel = selectedTrack { session.setArmed(sel, true) }
        let audio = session.tracks.first { $0.armed && !$0.isInstrument }
        guard audio != nil || session.tracks.contains(where: { $0.armed && $0.isInstrument }) else {
            return recordingProblem("Choose a track to record on",
                                    "Press R on a track header to enable it for recording, or select a track first.")
        }
        var uid: String?
        if let audio {
            if Self.simulatedInput {
                uid = DALNOK_SIMULATED_INPUT
            } else {
                guard let device = recordingDevice else {
                    return recordingProblem("No audio input for recording",
                        "Connect an audio interface or microphone, then choose it in Transport ▸ Recording Input.")
                }
                for t in session.tracks where t.armed && !t.isInstrument && Int(t.inputChannel) >= device.channels {
                    return recordingProblem("Input not available",
                                            "\(device.name) has \(device.channels) inputs; choose another input for \(t.name).")
                }
                // The output stays where it is: the engine pairs this input with it (one clock, drift-corrected).
                uid = device.uid
                // Ask for microphone access before opening the input (ADR-0008).
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                        DispatchQueue.main.async {
                            if granted { self?.beginRecording() }
                            else { self?.recordingProblem("Microphone access is off", "Allow Dalnok in System Settings ▸ Privacy & Security ▸ Microphone.") }
                        }
                    }
                    return
                case .denied, .restricted:
                    return recordingProblem("Microphone access is off", "Allow Dalnok in System Settings ▸ Privacy & Security ▸ Microphone.")
                default: break
                }
            }
        }
        // Autopunch records only the red punch range; count-in starts a bar before the record point with clicks.
        let requested = e.position
        var punchIn: Int64? = nil, punchOut = Int64.max / 4
        if Self.autopunch, let p = timeline.punchRange { punchIn = p.0; punchOut = p.1 }
        var countInEnd: Int64 = 0
        if Self.countIn {
            let recordAt = max(requested, punchIn ?? requested)
            let beat = session.frameToBeat(Double(recordAt))
            let b = session.bar(atBeat: beat)
            let barBeats = session.barToBeat(b.bar + 1) - session.barToBeat(b.bar)
            let preRoll = max(0, Int64(session.beatToFrame(beat - barBeats).rounded()))
            if preRoll < recordAt { e.seek(preRoll); countInEnd = recordAt; punchIn = recordAt }
        }
        dalnok_record_set_punch(e.handle, punchIn != nil, punchIn ?? 0, punchIn != nil ? punchOut : 0)
        dalnok_metronome_count_in(e.handle, countInEnd)
        countInUntil = countInEnd
        do {
            if let uid { // measured correction, if any; and the per-stream check on the loopback it was measured on
                dalnok_record_set_latency_offset(e.handle, latencyOffset(input: uid))
                syncLatencyCheck(input: uid)
            }
            try e.startRecording(input: uid, folder: audio == nil ? nil : recordingFolder)
        } catch {
            dalnok_record_set_punch(e.handle, false, 0, 0); dalnok_metronome_count_in(e.handle, 0)
            return recordingProblem("Recording didn’t start", "\(error)")
        }
        transport.setRecording(true)
        let names = session.tracks.filter(\.armed).map(\.name).joined(separator: " and ")
        flash(countInEnd > 0 ? "● Count-in… recording \(names) from \(timeline.positionText(countInEnd))"
              : punchIn != nil ? "● Recording \(names) between the punch markers" : "● Recording \(names)")
    }

    func finishRecording() {
        let e = session.engine
        let (result, problem) = e.stopRecording()
        dalnok_record_set_punch(e.handle, false, 0, 0)
        dalnok_metronome_count_in(e.handle, 0)
        countInUntil = 0
        transport.setRecording(false)
        timeline.recording = nil
        session.refresh()
        let clip = result.audio_clip != 0 ? result.audio_clip : result.midi_clip
        let slot = dalnok_record_slot(session.engine.handle)
        if clip != 0 && slot < 0 { timeline.selectedClip = clip }
        if let r = restoreRecordSlot { dalnok_record_set_slot(e.handle, r); restoreRecordSlot = nil }
        if slot >= 0 { launcher.animateChanges(); launcher.needsDisplay = true }
        if let problem {
            let path = fixedString(result.path)
            let detail = problem + (result.recovered ? "\n\nRecovered file: \(path)" : "")
            recordingProblem(result.recovered ? "The take was interrupted" : "Recording failed", detail)
            return
        }
        var parts: [String] = []
        if result.audio_clip != 0 {
            let tracks = Int(result.audio_clip_count)
            parts.append(TimelineView.formatTime(Double(result.frames) / e.sampleRate, step: 0.1) + " of audio"
                         + (tracks > 1 ? " on \(tracks) tracks" : ""))
        }
        if result.midi_clip != 0 { parts.append(result.notes == 1 ? "1 note" : "\(result.notes) notes") }
        var check = DalnokLatencyResult()
        _ = dalnok_latency_auto_result(e.handle, &check)
        if result.audio_clip != 0 && check.ok && check.measured_frames == result.latency_frames {
            parts.append("placed with this stream's measured round trip (\(result.latency_frames) samples)")
        }
        flash(parts.isEmpty ? "Nothing was recorded" : "Recorded " + parts.joined(separator: " and ")
              + (slot >= 0 ? " into slot \(slot + 1) (whole bars): click it to launch" : ""))
    }

    /// Shows a problem without blocking: a sheet normally, a status message during self-tests.
    func recordingProblem(_ title: String, _ detail: String) {
        lastRecordingProblem = title
        guard !SelfTest.running, let window else { flash("\(title): \(detail)"); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    /// Called every UI tick while recording.
    func updateRecording() {
        let e = session.engine
        guard e.isRecording else { return }
        if e.recordBroken {
            finishRecording()
            return
        }
        let start = e.recordStartFrame
        guard start >= 0 else { timeline.recording = nil; return }
        let armed = session.tracks.filter(\.armed)
        var peaks: [DalnokTrackId: [Float]] = [:]
        for t in armed where !t.isInstrument {
            let n = Int(dalnok_record_live_peaks(e.handle, t.id, nil, 0))
            guard n > 0 else { continue }
            var buf = [Float](repeating: 0, count: n)
            let got = Int(dalnok_record_live_peaks(e.handle, t.id, &buf, Int32(n)))
            peaks[t.id] = Array(buf.prefix(min(n, got)))
        }
        let c = session.cycle
        let cycleTake = c.on && c.end > c.start && !Self.autopunch
        timeline.recording = .init(start: start, end: e.position, tracks: Set(armed.map(\.id)), peaks: peaks,
                                   cycle: cycleTake ? (c.start, c.end) : nil)
    }

    // MARK: Latency

    /// Measured corrections (measured − reported round trip, frames) per input|output device pair.
    static var latencyOffsets: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "latencyOffsets") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "latencyOffsets") }
    }
    /// The pair key: the input and the output actually in use (the system default resolved to its device).
    func latencyKey(input: String) -> String {
        let out = session.engine.outputDeviceUid
        return input + "|" + (out.isEmpty ? (Engine.outputDevices().first(where: \.isDefault)?.uid ?? "") : out)
    }
    func latencyOffset(input: String) -> Int64 { Int64(Self.latencyOffsets[latencyKey(input: input)] ?? 0) }

    /// Audio ▸ Measure Recording Latency…: clicks out, the same clicks back on an input that hears the output.
    @objc func measureLatency(_ sender: Any?) {
        guard !session.engine.isRecording else { return flash("Stop recording first") }
        guard let device = recordingDevice else { return recordingProblem("No audio input", "Connect an interface first.") }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for ch in 0..<max(device.channels, 1) { popup.addItem(withTitle: "Input \(ch + 1)") }
        // A loopback input (the interface's own playback) is the usual choice; many interfaces put it last.
        let guess = selectedTrack.flatMap { session.track($0) }.map { Int($0.inputChannel) } ?? 0
        popup.selectItem(at: min(guess, popup.numberOfItems - 1))
        let alert = NSAlert()
        alert.messageText = "Measure Recording Latency"
        alert.informativeText = "Dalnok plays short tones on \(outputDeviceDescription()) and listens for them on \(device.name). Choose an input that hears that output: a cable from an output to an input, or the interface's loopback input. Turn the volume down if the output is speakers."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Measure")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.startLatencyMeasurement(input: device.uid, channel: popup.indexOfSelectedItem)
        }
    }

    func startLatencyMeasurement(input uid: String, channel: Int) {
        var err = [CChar](repeating: 0, count: 512)
        guard dalnok_latency_measure_start(session.engine.handle, uid, Int32(channel), &err, 512) == DALNOK_OK else {
            return recordingProblem("Couldn't measure latency", cString(err))
        }
        flash("Measuring latency on Input \(channel + 1)…")
        latencyInput = uid
        latencyChannel = channel
        if SelfTest.running { return } // the self-test pumps the simulated device and polls itself
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, !self.pollLatencyMeasurement() else { return }
                poll()
            }
        }
        poll()
    }

    /// True once finished; keeps the measurement (and tells the user) when it is clean.
    @discardableResult
    func pollLatencyMeasurement() -> Bool {
        var r = DalnokLatencyResult()
        guard dalnok_latency_measure_poll(session.engine.handle, &r) else { return false }
        let rate = session.engine.sampleRate
        let ms = { (f: Int64) in String(format: "%.2f ms", Double(f) / rate * 1000) }
        guard r.ok, let input = latencyInput else {
            recordingProblem("Latency not measured", fixedString(r.error))
            return true
        }
        let key = latencyKey(input: input)
        Self.latencyOffsets[key] = Int(r.measured_frames - r.reported_frames)
        // The input that heard the output can check every new stream too (inaudibly): on by default.
        Self.latencyChecks[key] = latencyChannel
        syncLatencyCheck(input: input)
        lastLatencyResult = r
        flash("Round trip \(ms(r.measured_frames)) (\(r.measured_frames) samples; devices report \(ms(r.reported_frames))). Takes now use the measurement, re-checked on Input \(latencyChannel + 1) each time the device starts.")
        return true
    }

    @objc func resetLatency(_ sender: Any?) {
        guard let uid = recordingDevice?.uid else { return }
        Self.latencyOffsets[latencyKey(input: uid)] = nil
        Self.latencyChecks[latencyKey(input: uid)] = nil
        syncLatencyCheck(input: uid)
        flash("Latency compensation: as the devices report")
    }

    /// Per input|output pair: the loopback (or cabled) input channel that re-measures every new device stream
    /// (-(channel + 1) while turned off).
    static var latencyChecks: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "latencyChecks") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "latencyChecks") }
    }
    /// Tells the engine which input re-measures new streams for the pair in use (or none).
    func syncLatencyCheck(input uid: String?) {
        let channel = uid.flatMap { Self.latencyChecks[latencyKey(input: $0)] }.flatMap { $0 >= 0 ? $0 : nil }
        dalnok_latency_auto_set(session.engine.handle, channel == nil ? nil : uid, Int32(channel ?? -1), nil, 0)
    }
    /// Audio ▸ Recording Input ▸ Re-measure on Every Device Start.
    @objc func toggleLatencyCheck(_ sender: Any?) {
        guard let uid = Self.simulatedInput ? DALNOK_SIMULATED_INPUT : recordingDevice?.uid else { return }
        let key = latencyKey(input: uid)
        if let ch = Self.latencyChecks[key] { Self.latencyChecks[key] = -ch - 1 } // off keeps the channel: -(channel + 1)
        syncLatencyCheck(input: uid)
        flash((Self.latencyChecks[key] ?? -1) >= 0 ? "Every device start re-measures the round trip (inaudibly)" : "Takes use the stored measurement")
    }

    // MARK: Inputs

    @objc func selectRecordingInput(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        Self.recordingInputUID = uid
        syncInputDevice()
        flash("Recording input: \(Engine.recordingDevices().first { $0.uid == uid }?.name ?? uid)")
    }

    func buildRecordingInputMenu(_ menu: NSMenu) {
        let devices = Engine.recordingDevices()
        let current = recordingDevice?.uid
        if devices.isEmpty {
            let none = NSMenuItem(title: "No audio inputs", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for d in devices {
            let rateOK = abs(d.sampleRate - session.engine.sampleRate) < 0.5
            let title = d.name + (rateOK ? "" : String(format: " (switches to %g kHz)", session.engine.sampleRate / 1000))
            let it = NSMenuItem(title: title, action: #selector(selectRecordingInput(_:)), keyEquivalent: "")
            it.representedObject = d.uid
            it.state = d.uid == current ? .on : .off
            it.toolTip = "\(d.channels) inputs"
            it.target = self
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let effective = Self.simulatedInput ? DALNOK_SIMULATED_INPUT : current
        let offset = effective.map { latencyOffset(input: $0) } ?? 0
        let latency = NSMenuItem(title: String(format: "Latency compensation: %.1f ms (%@)",
                                               Double(session.engine.recordLatency) / session.engine.sampleRate * 1000,
                                               offset != 0 ? "measured" : "reported by the devices"),
                                 action: nil, keyEquivalent: "")
        latency.isEnabled = false
        if !session.engine.isRecording {
            latency.title = offset != 0 ? String(format: "Latency compensation: measured (%+d samples vs. the devices)", offset)
                                        : "Latency compensation: reported by the devices when recording starts"
        }
        menu.addItem(latency)
        let measure = NSMenuItem(title: "Measure Recording Latency…", action: #selector(measureLatency(_:)), keyEquivalent: "")
        measure.target = self
        menu.addItem(measure)
        if offset != 0, let uid = effective {
            let key = latencyKey(input: uid)
            let check = NSMenuItem(title: "Re-measure on Every Device Start", action: #selector(toggleLatencyCheck(_:)), keyEquivalent: "")
            check.target = self
            check.state = (Self.latencyChecks[key] ?? -1) >= 0 ? .on : .off
            check.isEnabled = Self.latencyChecks[key] != nil
            check.toolTip = "The round trip can change by a few samples each time the device starts. Dalnok measures it again, inaudibly, on the input you measured with."
            menu.addItem(check)
            let reset = NSMenuItem(title: "Use Reported Latency", action: #selector(resetLatency(_:)), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }
    }

    /// Track header input button: choose an input channel (audio) or explain MIDI routing.
    func showInputMenu(for row: TrackHeaderRow) {
        guard let track = session.track(row.trackId) else { return }
        let menu = NSMenu()
        // Plug-ins on this track: open their windows.
        for p in track.plugins {
            let it = NSMenuItem(title: "Open \(p.name)\(p.instrument ? "" : " (insert)")", action: #selector(openPluginItem(_:)), keyEquivalent: "")
            it.representedObject = (track.id, p.id)
            it.target = self
            it.isEnabled = p.loaded
            menu.addItem(it)
        }
        if !track.plugins.isEmpty { menu.addItem(.separator()) }
        if track.isBus {
            // Buses have no input of their own.
        } else if track.isInstrument {
            let sources = Engine.midiSources()
            let title = sources.isEmpty ? "No MIDI inputs connected" : "All MIDI inputs (\(sources.map(\.name).joined(separator: ", ")))"
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        } else {
            let device = recordingDevice
            for ch in 0..<max(device?.channels ?? 2, 1) {
                let it = NSMenuItem(title: "Input \(ch + 1)" + (device.map { " — \($0.name)" } ?? ""), action: #selector(setTrackInput(_:)), keyEquivalent: "")
                it.tag = ch
                it.representedObject = track.id
                it.state = Int(track.inputChannel) == ch ? .on : .off
                it.target = self
                menu.addItem(it)
            }
        }
        // Output: the master or a bus.
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (id, name) in [(DalnokTrackId(0), "Master")] + session.buses.filter({ $0.id != track.id }).map({ ($0.id, $0.name) }) {
            let it = NSMenuItem(title: name, action: #selector(setTrackOutputItem(_:)), keyEquivalent: "")
            it.tag = Int(id)
            it.representedObject = track.id
            it.state = track.output == id ? .on : .off
            it.target = self
            it.indentationLevel = 1
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: row.inputButton.bounds.maxY), in: row.inputButton)
    }

    @objc func setTrackOutputItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? DalnokTrackId else { return }
        if !session.setOutput(id, DalnokTrackId(sender.tag)) { flash("That output would feed the bus back into itself") }
    }

    @objc func setTrackInput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? DalnokTrackId else { return }
        session.setInput(id, Int32(sender.tag))
    }

    /// Transport ▸ Monitor Armed Tracks: every record-enabled audio track plays its input (Logic's auto input monitoring).
    @objc func toggleInputMonitoring(_ sender: Any?) {
        Self.inputMonitoring.toggle()
        syncInputDevice()
        dalnok_record_set_monitoring(session.engine.handle, Self.inputMonitoring)
        flash(Self.inputMonitoring ? "Armed tracks play their input — use headphones to avoid feedback" : "Armed tracks no longer play their input")
    }

    /// The I button: hear this track's input through its channel strip now, recording or not.
    func toggleTrackInputMonitor(_ id: DalnokTrackId) {
        guard let t = session.track(id), !t.isBus, !t.isInstrument else { return }
        syncInputDevice()
        session.setInputMonitor(id, !t.inputMonitor)
        if !t.inputMonitor {
            let problem = session.engine.inputError
            flash(problem.isEmpty ? "Input Monitoring on \(t.name): Input \(t.inputChannel + 1) of \(recordingDevice?.name ?? "no input") — use headphones to avoid feedback"
                                  : "Input Monitoring couldn't open the input: \(problem)")
        }
    }
    @objc func toggleSelectedInputMonitor(_ sender: Any?) {
        guard let id = selectedTrack else { return }
        toggleTrackInputMonitor(id)
    }

    /// Opens every MIDI source not yet connected (sources can appear at any time).
    func connectMidiInputs() {
        for source in Engine.midiSources() where !openedMidiSources.contains(source.id) {
            do {
                try session.engine.openMidiInput(source.id)
                openedMidiSources.insert(source.id)
            } catch {
                flash("MIDI input \(source.name) unavailable: \(error)")
            }
        }
    }

    // MARK: Tracks and MIDI clips

    @objc func newInstrumentTrack(_ sender: Any?) {
        let id = session.addInstrumentTrack()
        headers.select(id)
        connectMidiInputs()
        flash("Instrument track added; it plays Dalnok Poly from your MIDI keyboard")
    }

    @objc func toggleArmTrack(_ sender: Any?) {
        guard let id = selectedTrack, let t = session.track(id) else { return }
        session.setArmed(id, !t.armed)
    }

    /// A 4-bar MIDI clip at the playhead on the selected instrument track.
    @objc func newMidiClip(_ sender: Any?) {
        guard let id = selectedTrack, session.track(id)?.isInstrument == true else { return }
        // Four bars from the playhead, measured through the tempo and meter maps.
        let start = session.engine.position
        let b = session.bar(atBeat: session.frameToBeat(Double(start)))
        let endBeat = session.frameToBeat(Double(start)) + (session.barToBeat(b.bar + 4) - session.barToBeat(b.bar))
        let length = max(1, Int64(session.beatToFrame(endBeat).rounded()) - start)
        let clip = session.addMidiClip(id, start: start, length: length)
        if clip != 0 { timeline.selectedClip = clip }
    }

    /// Clip ▸ Quantize ▸ a value: makes it the quantize value and quantizes the selection with it.
    @objc func quantizeClip(_ sender: NSMenuItem) {
        QuantizeSetting.grid = 4.0 / Double(sender.tag)
        clipEditor.syncQuantizeControls()
        quantizeSelection(sender)
    }
    /// Q (Logic's Quantize): the selected notes in the piano roll, else every selected clip, to the quantize value at
    /// the quantize strength, as one undo step. MIDI clips move their notes; audio clips are cut at their transients
    /// and each slice is moved to the grid and time-stretched to meet the next (`dalnok_audio_quantize`).
    @objc func quantizeSelection(_ sender: Any?) {
        if pianoRollIsKey { return activeRoll.quantizeSelection() }
        var clips = timeline.selectedClips.compactMap { session.clip($0) }.filter { $0.folder == 0 }
        if !clipEditor.isHidden, clipEditor.focused, let c = clipEditor.clip { clips = [c] } // the docked editor's clip
        guard !clips.isEmpty else { return flash("Select clips (or notes) to quantize") }
        let grid = QuantizeSetting.grid, strength = QuantizeSetting.strength
        var slices: [DalnokClipId] = [], untouched = 0, audio = 0
        session.engine.beginGroup("Quantize")
        for c in clips {
            if c.isMidi { dalnok_midi_quantize(session.engine.handle, c.id, grid, strength); slices.append(c.id); continue }
            audio += 1
            var out = [DalnokClipId](repeating: 0, count: 4096)
            let n = Int(dalnok_audio_quantize(session.engine.handle, c.id, grid, strength, QuantizeSetting.sensitivity, &out, Int32(out.count)))
            if n > 0 { slices += out.prefix(min(n, out.count)) } else { untouched += 1; slices.append(c.id) }
        }
        session.engine.endGroup()
        session.refresh()
        timeline.selectClips(slices)
        if let open = clipEditor.clipId, session.clip(open) == nil, let first = slices.first(where: { session.clip($0) != nil }) {
            clipEditor.show(clip: first) // the docked editor follows the quantized audio
        }
        let what = clips.count == 1 ? "1 clip" : "\(clips.count) clips"
        var msg = "Quantized \(what) to \(QuantizeSetting.name)\(strength < 1 ? " at \(Int((strength * 100).rounded()))%" : "")"
        if audio > 0 && untouched == audio { msg = "No transients to quantize in \(audio == 1 ? "that clip" : "those clips")" }
        else if untouched > 0 { msg += " (\(untouched) without transients unchanged)" }
        flash(msg)
    }

    // MARK: Recovery

    @objc func recoverRecordings(_ sender: Any?) {
        var folders = [Self.scratchRecordingFolder]
        if session.projectURL != nil { folders.append(recordingFolder) }
        var recovered: [URL] = [], failures: [String] = []
        for folder in folders {
            for take in Self.unfinishedTakes(in: folder) {
                var out = [CChar](repeating: 0, count: 65_536), err = [CChar](repeating: 0, count: 512)
                if dalnok_record_recover(take, &out, out.count, &err, err.count) == DALNOK_OK,
                   let r = try? JSONSerialization.jsonObject(with: Data(cString(out).utf8)) as? [String: Any],
                   let path = r["path"] as? String {
                    recovered.append(URL(fileURLWithPath: path))
                } else {
                    failures.append("\((take as NSString).lastPathComponent): \(cString(err))")
                }
            }
        }
        lastRecoveredTakes = recovered
        if recovered.isEmpty && failures.isEmpty { return flash("No unfinished recordings found") }
        guard !SelfTest.running, let window else { return flash("Recovered \(recovered.count) take(s)") }
        let alert = NSAlert()
        alert.messageText = recovered.isEmpty ? "No takes could be recovered" : "Recovered \(recovered.count) take(s)"
        alert.informativeText = (recovered.map(\.lastPathComponent) + failures).joined(separator: "\n") +
            "\n\nThe original capture files were kept unchanged."
        if !recovered.isEmpty { alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Show in Finder") }
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if !recovered.isEmpty && response == .alertFirstButtonReturn { self.session.importFiles(recovered) }
            if !recovered.isEmpty && response == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting(recovered) }
        }
    }

    /// Journals of takes that never finished (the app or computer stopped during recording).
    static func unfinishedTakes(in folder: URL) -> [String] {
        var buf = [CChar](repeating: 0, count: 1 << 20)
        dalnok_record_scan(folder.path, &buf, buf.count)
        let list = (try? JSONSerialization.jsonObject(with: Data(cString(buf).utf8))) as? [[String: Any]] ?? []
        return list.filter { ($0["state"] as? String) == "recording" }.compactMap { $0["journal"] as? String }
    }
}
