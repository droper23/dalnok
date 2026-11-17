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

    /// The device recordings come from: the saved choice, else the current output if it has inputs, else the first.
    var recordingDevice: Engine.InputDevice? {
        let devices = Engine.recordingDevices()
        if let uid = Self.recordingInputUID, let d = devices.first(where: { $0.uid == uid }) { return d }
        if let d = devices.first(where: { $0.uid == session.engine.outputDeviceUid }) { return d }
        return devices.first
    }

    // MARK: Record

    @objc func toggleRecord(_ sender: Any?) {
        session.engine.isRecording ? finishRecording() : beginRecording()
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
                    return recordingProblem("No audio interface for recording",
                        "Dalnok records from a device that has both inputs and outputs (such as an audio interface), so one clock drives recording and playback. Separate built-in microphones and speakers aren’t supported yet.")
                }
                guard abs(device.sampleRate - e.sampleRate) < 0.5 else {
                    return recordingProblem("Sample rates don’t match",
                        String(format: "%@ runs at %g kHz, but this session runs at %g kHz. Set the device to %g kHz in Audio MIDI Setup, or make it the system output and reopen Dalnok.",
                               device.name, device.sampleRate / 1000, e.sampleRate / 1000, e.sampleRate / 1000))
                }
                guard Int(audio.inputChannel) < device.channels else {
                    return recordingProblem("Input not available",
                                            "\(device.name) has \(device.channels) inputs; choose another input for \(audio.name).")
                }
                if e.outputDeviceUid != device.uid {
                    do { try e.setOutputDevice(device.uid) } catch {
                        return recordingProblem("Couldn’t use \(device.name)", "\(error)")
                    }
                }
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
        do {
            try e.startRecording(input: uid, folder: audio == nil ? nil : recordingFolder)
        } catch {
            return recordingProblem("Recording didn’t start", "\(error)")
        }
        transport.setRecording(true)
        let names = session.tracks.filter(\.armed).map(\.name).joined(separator: " and ")
        flash("● Recording \(names)")
    }

    func finishRecording() {
        let e = session.engine
        let (result, problem) = e.stopRecording()
        transport.setRecording(false)
        timeline.recording = nil
        session.refresh()
        let clip = result.audio_clip != 0 ? result.audio_clip : result.midi_clip
        if clip != 0 { timeline.selectedClip = clip }
        if let problem {
            let path = fixedString(result.path)
            let detail = problem + (result.recovered ? "\n\nRecovered file: \(path)" : "")
            recordingProblem(result.recovered ? "The take was interrupted" : "Recording failed", detail)
            return
        }
        var parts: [String] = []
        if result.audio_clip != 0 {
            parts.append(TimelineView.formatTime(Double(result.frames) / e.sampleRate, step: 0.1) + " of audio")
        }
        if result.midi_clip != 0 { parts.append(result.notes == 1 ? "1 note" : "\(result.notes) notes") }
        flash(parts.isEmpty ? "Nothing was recorded" : "Recorded " + parts.joined(separator: " and "))
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
        timeline.recording = start < 0 ? nil : .init(start: start, end: e.position,
                                                     tracks: Set(session.tracks.filter(\.armed).map(\.id)))
    }

    // MARK: Inputs

    @objc func selectRecordingInput(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        Self.recordingInputUID = uid
        flash("Recording input: \(Engine.recordingDevices().first { $0.uid == uid }?.name ?? uid)")
    }

    func buildRecordingInputMenu(_ menu: NSMenu) {
        let devices = Engine.recordingDevices()
        let current = recordingDevice?.uid
        if devices.isEmpty {
            let none = NSMenuItem(title: "No device with inputs and outputs", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for d in devices {
            let rateOK = abs(d.sampleRate - session.engine.sampleRate) < 0.5
            let title = d.name + (rateOK ? "" : String(format: " (%g kHz — session is %g kHz)", d.sampleRate / 1000, session.engine.sampleRate / 1000))
            let it = NSMenuItem(title: title, action: #selector(selectRecordingInput(_:)), keyEquivalent: "")
            it.representedObject = d.uid
            it.state = d.uid == current ? .on : .off
            it.toolTip = "\(d.channels) inputs"
            it.target = self
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let latency = NSMenuItem(title: String(format: "Latency compensation: %.1f ms (reported by the device)",
                                               Double(session.engine.recordLatency) / session.engine.sampleRate * 1000),
                                 action: nil, keyEquivalent: "")
        latency.isEnabled = false
        if !session.engine.isRecording { latency.title = "Latency compensation: reported by the device when recording starts" }
        menu.addItem(latency)
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
        if track.isInstrument {
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
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: row.inputButton.bounds.maxY), in: row.inputButton)
    }

    @objc func setTrackInput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? DalnokTrackId else { return }
        session.setInput(id, Int32(sender.tag))
    }

    @objc func toggleInputMonitoring(_ sender: Any?) {
        Self.inputMonitoring.toggle()
        dalnok_record_set_monitoring(session.engine.handle, Self.inputMonitoring)
        flash(Self.inputMonitoring ? "Input monitoring on — use headphones to avoid feedback" : "Input monitoring off")
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
        var num: Int32 = 4, den: Int32 = 4
        dalnok_meter(session.engine.handle, &num, &den)
        let bar = session.framesPerBeat * Int64(num) * 4 / Int64(den)
        let clip = session.addMidiClip(id, start: session.engine.position, length: bar * 4)
        if clip != 0 { timeline.selectedClip = clip }
    }

    @objc func quantizeClip(_ sender: NSMenuItem) {
        guard let c = timeline.selectedClip, session.clip(c)?.isMidi == true else { return }
        session.quantize(c, grid: 4.0 / Double(sender.tag))
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
