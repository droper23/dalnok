// Main window composition, commands, menus validation, project lifecycle.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine
import UniformTypeIdentifiers

extension UTType {
    static let dalnokProject = UTType(filenameExtension: "dalnok", conformingTo: .json) ?? .json
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate, NSOpenSavePanelDelegate {
    let session: Session
    let palette = CommandPalette()
    let emptyState = EmptyStateView()
    lazy var settings = SettingsController()
    lazy var pianoRoll = PianoRollController(session: session)
    lazy var pluginManager = PluginManagerController()
    var pluginWindows: [Int32: PluginWindowController] = [:]

    /// Opens (or brings forward) a hosted plug-in's window: its editor and the generic parameter panel.
    func openPluginWindow(track: DalnokTrackId, slot: Int32) {
        if let existing = pluginWindows[slot] { existing.window?.makeKeyAndOrderFront(nil); return }
        guard let t = session.track(track), let p = t.plugins.first(where: { $0.id == slot }) else { return }
        guard p.loaded else { return flash("\(p.name) is not loaded: \(p.error)") }
        let w = PluginWindowController(engine: session.engine, slot: slot, title: "\(p.name) — \(t.name)")
        w.onClose = { [weak self] in self?.pluginWindows[slot] = nil }
        pluginWindows[slot] = w
        w.show()
    }
    @objc func openPluginItem(_ sender: NSMenuItem) {
        guard let (track, slot) = sender.representedObject as? (DalnokTrackId, Int32) else { return }
        openPluginWindow(track: track, slot: slot)
    }
    @objc func showPlugins(_ sender: Any?) {
        pluginManager.onAdd = { [weak self] path in
            guard let self, let track = self.selectedTrack else { return "no track selected" }
            do { _ = try self.session.addPlugin(track, path: path); return nil } catch { return "\(error)" }
        }
        pluginManager.selectedTrackName = { [weak self] in self?.selectedTrack.flatMap { self?.session.track($0)?.name } }
        pluginManager.show()
        pluginManager.updateAddButton()
    }

    @objc func removePluginItem(_ sender: NSMenuItem) {
        guard let (track, slot) = sender.representedObject as? (DalnokTrackId, Int32) else { return }
        session.removePlugin(track, slot)
    }

    /// Track context menu: the track's plug-ins (remove) and a way to add more.
    func pluginsMenu(for track: TrackView) -> NSMenu {
        let m = NSMenu(title: "Plug-ins")
        for p in track.plugins {
            let open = NSMenuItem(title: "Open \(p.name)", action: #selector(openPluginItem(_:)), keyEquivalent: "")
            open.representedObject = (track.id, p.id)
            open.target = self
            open.isEnabled = p.loaded
            m.addItem(open)
        }
        if !track.plugins.isEmpty { m.addItem(.separator()) }
        for p in track.plugins {
            let it = NSMenuItem(title: "Remove \(p.name)\(p.instrument ? " (instrument)" : "")\(p.loaded ? "" : " — not loaded")",
                                action: #selector(removePluginItem(_:)), keyEquivalent: "")
            it.representedObject = (track.id, p.id)
            it.target = self
            m.addItem(it)
        }
        if !track.plugins.isEmpty { m.addItem(.separator()) }
        let add = NSMenuItem(title: "Add Plug-in…", action: #selector(showPlugins(_:)), keyEquivalent: "")
        add.target = self
        m.addItem(add)
        return m
    }
    /// True while the piano roll is the window the user is working in (it was opened or clicked last),
    /// so Edit ▸ Delete removes notes there instead of the selected timeline clip.
    var pianoRollIsKey: Bool { pianoRoll.window?.isVisible == true && pianoRoll.focused }

    func windowDidBecomeKey(_ notification: Notification) { pianoRoll.focused = false }
    lazy var conceptGuide = ConceptGuideController()
    lazy var welcome = WelcomeController(main: self)
    private(set) var lastImportReport: ImportReport?
    static let foreignExtensions: Set<String> = ["rpp", "als", "logicx", "fcpxml", "fcpxmld"]
    private var tickCount = 0
    let transport = TransportBar()
    let headers: TrackHeaderColumn
    let timeline: TimelineView
    let devicePanel: DevicePanel
    private var devicePanelHeight: NSLayoutConstraint!
    static var showDevicePanel: Bool {
        get { UserDefaults.standard.object(forKey: "showDevicePanel") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showDevicePanel") }
    }
    private var timer: Timer?
    private var wasPlaying = false
    private var wasRecording = false
    private var didShowContent = false
    private var lastBeat = -1
    /// Self-test only: record from DALNOK_SIMULATED_INPUT instead of a device.
    static var simulatedInput = false
    static var inputMonitoring = false
    var openedMidiSources = Set<Int32>()
    var lastRecordingProblem: String?
    var lastRecoveredTakes: [URL] = []
    var fitOnNextChange = true

    init(session: Session) {
        self.session = session
        headers = TrackHeaderColumn(session: session)
        timeline = TimelineView(session: session)
        devicePanel = DevicePanel(session: session)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden // the control bar shows the title
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.window
        window.minSize = NSSize(width: 720, height: 400)
        window.setFrameAutosaveName("DalnokMain")
        super.init(window: window)
        window.delegate = self

        let root = DropView()
        root.onDrop = { [weak self] urls in
            guard let self else { return }
            if let project = urls.first(where: { Self.foreignExtensions.contains($0.pathExtension.lowercased()) || $0.hasDirectoryPath }) {
                self.importProject(project)
            } else {
                self.session.importFiles(urls)
            }
        }
        window.contentView = root
        for v in [transport, headers, timeline, devicePanel, emptyState] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            transport.topAnchor.constraint(equalTo: root.topAnchor),
            transport.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transport.heightAnchor.constraint(equalToConstant: Theme.transportHeight),
            headers.topAnchor.constraint(equalTo: transport.bottomAnchor),
            headers.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headers.bottomAnchor.constraint(equalTo: devicePanel.topAnchor),
            headers.widthAnchor.constraint(equalToConstant: Theme.headerWidth),
            timeline.topAnchor.constraint(equalTo: transport.bottomAnchor),
            timeline.leadingAnchor.constraint(equalTo: headers.trailingAnchor),
            timeline.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: devicePanel.topAnchor),
            devicePanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            devicePanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            devicePanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.topAnchor.constraint(equalTo: transport.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        devicePanelHeight = devicePanel.heightAnchor.constraint(equalToConstant: Self.showDevicePanel ? DevicePanel.height : 0)
        devicePanelHeight.isActive = true
        devicePanel.isHidden = !Self.showDevicePanel
        devicePanel.onOpen = { [weak self] track, slot in self?.openPluginWindow(track: track, slot: slot) }
        devicePanel.onAdd = { [weak self] in self?.showPlugins(nil) }
        emptyState.onImportAudio = { [weak self] in self?.importAudio() }
        emptyState.onOpen = { [weak self] in self?.openDocument(nil) }
        emptyState.onMigrate = { [weak self] in self?.showMigrationAssistant(nil) }
        emptyState.onNewInstrument = { [weak self] in self?.newInstrumentTrack(nil) }
        emptyState.onNewAudioTrack = { [weak self] in self?.newTrack(nil) }

        transport.onPlayPause = { [weak self] in self?.togglePlay() }
        transport.onRecord = { [weak self] in self?.toggleRecord(nil) }
        transport.onMetronome = { [weak self] in self?.toggleMetronome(nil) }
        transport.tempoField.target = self
        transport.tempoField.action = #selector(tempoEdited(_:))
        transport.meterPopup.target = self
        transport.meterPopup.action = #selector(meterChosen(_:))
        headers.onInputMenu = { [weak self] row in self?.showInputMenu(for: row) }
        transport.onRewind = { [weak self] in self?.goToStart() }
        transport.onImport = { [weak self] in self?.importAudio() }
        transport.onPalette = { [weak self] in self?.showCommandPalette(nil) }
        headers.onAddTrack = { [weak self] in self?.newTrack(nil) }
        timeline.onVerticalScroll = { [weak self] y in self?.headers.scrollY = y }
        timeline.onClipSelected = { [weak self] clip in self?.headers.selectedTrack = clip.track }
        timeline.onOpenClip = { [weak self] clip in self?.pianoRoll.show(clip: clip.id) }
        timeline.onActivate = { [weak self] in self?.pianoRoll.focused = false }
        headers.contextMenu = trackContextMenu()
        headers.onSelect = { [weak self] id in
            self?.timeline.highlightedTrack = id
            self?.devicePanel.track = id
        }
        palette.onOpenGuide = { [weak self] c in self?.conceptGuide.show(daw: c.daw, query: c.term) }
        session.onChange = { [weak self] in self?.modelChanged() }
        session.onMessage = { [weak self] msg in self?.flash(msg) }
        modelChanged()
        applyMetronome()

        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var lastRecoveryRevision: UInt64?
    private var recoveryDirectory: URL? {
        if let override = ProcessInfo.processInfo.environment["DALNOK_RECOVERY_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dalnok/Recovery", isDirectory: true)
    }

    /// Each snapshot has its own name so saving a later project cannot destroy an earlier recovery copy.
    @discardableResult
    func writeRecoverySnapshot(in directory: URL) throws -> URL? {
        guard session.engine.isDirty, session.engine.revision != lastRecoveryRevision, !session.isOpening else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "Recovery-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).dalnok"
        let url = directory.appendingPathComponent(name)
        try session.engine.saveSnapshot(to: url)
        lastRecoveryRevision = session.engine.revision
        return url
    }

    @objc func recoverSnapshot(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.dalnokProject]
        panel.directoryURL = recoveryDirectory
        panel.message = "Choose a recovery snapshot. It opens as a new unsaved project."
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.confirmDiscard { self.openRecovery(url) }
        }
    }

    func openRecovery(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        Task {
            do {
                fitOnNextChange = true
                try await session.recover(url)
                completion?(true)
            } catch {
                fitOnNextChange = false
                presentError(title: "Couldn't recover \(url.lastPathComponent)", error)
                completion?(false)
            }
        }
    }

    // MARK: Model → UI

    private func modelChanged() {
        headers.sync()
        // Show the empty state or the arrangement; crossfade only when that actually changes.
        let empty = session.tracks.isEmpty
        devicePanel.isHidden = empty || !Self.showDevicePanel
        let showingEmpty = !emptyState.isHidden && timeline.isHidden
        if showingEmpty != empty {
            let changing = didShowContent // the first state at launch appears without animation
            didShowContent = true
            emptyState.isHidden = false
            timeline.isHidden = false
            headers.isHidden = false
            let show: [NSView] = empty ? [emptyState] : [timeline, headers], hide: [NSView] = empty ? [timeline, headers] : [emptyState]
            if !changing || Motion.reduced {
                hide.forEach { $0.isHidden = true; $0.alphaValue = 1 }
                show.forEach { $0.alphaValue = 1 }
            } else {
                show.forEach { $0.alphaValue = 0 }
                Motion.views(Motion.gentle) {
                    show.forEach { $0.animator().alphaValue = 1 }
                    hide.forEach { $0.animator().alphaValue = 0 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.gentle + 0.05) { [weak self] in
                    guard let self else { return }
                    let nowEmpty = self.session.tracks.isEmpty
                    self.emptyState.isHidden = !nowEmpty
                    self.timeline.isHidden = nowEmpty
                    self.headers.isHidden = nowEmpty
                    for v in [self.emptyState, self.timeline, self.headers] as [NSView] { v.alphaValue = 1 }
                }
            }
        }
        timeline.pruneSelection()
        if fitOnNextChange && !session.tracks.isEmpty {
            timeline.zoomToFit()
            fitOnNextChange = false
        }
        timeline.needsDisplay = true
        updateTitle()
        updateTempoDisplay()
        pianoRoll.modelChanged()
        if devicePanel.track == nil, let first = session.tracks.first?.id { headers.select(first) }
        devicePanel.rebuild()
        if transientMessageUntil < Date() { updateStatus() }
    }

    func updateTitle() {
        window?.title = session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        transport.titleLabel.stringValue = (window?.title ?? "Untitled") + (session.engine.isDirty ? " — Edited" : "")
        window?.representedURL = session.projectURL
        window?.isDocumentEdited = session.engine.isDirty
    }

    private var transientMessageUntil = Date.distantPast
    func flash(_ msg: String) {
        Motion.fadeNextChange(transport.statusLabel.layer, duration: Motion.standard)
        transport.statusLabel.stringValue = msg
        transientMessageUntil = Date().addingTimeInterval(4)
    }

    private func updateStatus() {
        let e = session.engine
        let sr = e.sampleRate
        let n = session.tracks.count
        _ = (sr, n)
        let text = outputDeviceDescription()
        if transport.statusLabel.stringValue != text { Motion.fadeNextChange(transport.statusLabel.layer, duration: Motion.gentle) }
        transport.statusLabel.stringValue = text
    }

    private func outputDeviceDescription() -> String {
        let e = session.engine
        let uid = e.outputDeviceUid
        let devices = Engine.outputDevices()
        let dev = uid.isEmpty ? devices.first(where: \.isDefault) : devices.first(where: { $0.uid == uid })
        var s = dev?.name ?? "No output"
        let hw = e.hardwareSampleRate
        if hw > 0 && abs(hw - e.sampleRate) > 0.5 {
            s += String(format: ", %g kHz (converted from %g kHz)", hw / 1000, e.sampleRate / 1000)
        } else {
            s += String(format: ", %g kHz", e.sampleRate / 1000)
        }
        return s
    }

    private func tick() {
        let e = session.engine
        e.collectGarbage()
        session.refresh() // picks up changes from any source (e.g. scripts)
        _ = session.pollJobs() // installs finished time-stretch renders
        followTempoSegment()
        let playing = e.isPlaying, recording = e.isRecording
        if playing != wasPlaying || recording != wasRecording {
            transport.setPlaying(playing)
            transport.setRecording(recording)
            timeline.setTransportState(playing: playing, recording: recording)
            for row in headers.rows { row.setRecording(recording); if playing != wasPlaying { row.gain.transportChanged(playing: playing) } }
            wasPlaying = playing
            wasRecording = recording
        }
        // Visual metronome: the button ticks on each beat, harder on the downbeat.
        if playing && Self.metronomeOn {
            let b = session.bar(atBeat: session.frameToBeat(Double(e.position)))
            let beat = b.bar * 1_000 + Int(b.beatInBar)
            if beat != lastBeat {
                let downbeat = Int(b.beatInBar) == 0
                Motion.centerAnchor(transport.metronomeButton.layer)
                Motion.bounce(transport.metronomeButton.layer, scale: downbeat ? 1.3 : 1.14, duration: 0.16)
                lastBeat = beat
            }
        } else {
            lastBeat = -1
        }
        let position = timeline.positionText(e.position)
        transport.timeLabel.stringValue = position
        if Analog.on { transport.ghost.stringValue = String(position.map { $0.isNumber ? "8" : $0 }) } // unlit segments
        timeline.followPlayhead()
        timeline.updatePlayhead()
        for row in headers.rows {
            let (l, r) = e.trackMeter(row.trackId)
            row.meter.push(l, r)
            row.gain.updateMeter(max(row.meter.levelDb.0, row.meter.levelDb.1))
        }
        if e.isRecording { updateRecording() }
        let (ml, mr) = e.masterMeter()
        transport.masterMeter.push(ml, mr)
        tickCount += 1
        if tickCount % 1800 == 0 && !SelfTest.running, let directory = recoveryDirectory {
            do { _ = try writeRecoverySnapshot(in: directory) }
            catch { flash("Recovery snapshot failed: \(error)") }
        }
        if tickCount % 30 == 0 && !e.deviceAlive { deviceLost() }
        if tickCount % 15 == 0 && !devicePanel.isHidden { devicePanel.refreshValues() }
        if transientMessageUntil < Date(), transientMessageUntil != .distantPast {
            transientMessageUntil = .distantPast
            updateStatus()
        }
    }

    // MARK: Transport

    @objc func togglePlay() {
        let e = session.engine
        if e.isRecording { return finishRecording() } // Space stops a take cleanly
        e.isPlaying ? e.pause() : e.play()
    }

    @objc func goToStart() {
        if session.engine.isRecording { return } // a jump would end the take
        session.engine.seek(0)
        timeline.scrollFrame = 0
    }

    // MARK: Audio devices

    private func deviceLost() {
        let lostName = Engine.outputDevices().first { $0.uid == session.engine.outputDeviceUid }?.name ?? "Output device"
        do {
            try session.engine.setOutputDevice(nil)
            flash("\(lostName) disconnected — switched to System Default")
        } catch {
            flash("\(lostName) disconnected and no fallback device is available: \(error)")
        }
    }

    @objc func selectOutputDevice(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        do {
            try session.engine.setOutputDevice(uid)
            flash("Output: \(outputDeviceDescription())")
        } catch {
            presentError(title: "Couldn't switch output device", error)
        }
    }

    /// Rebuilds the Output Device submenu each time it opens (devices come and go).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.title == "Recording Input" { return buildRecordingInputMenu(menu) }
        if menu.title == "Track Plug-ins" {
            guard let track = selectedTrack.flatMap({ session.track($0) }) else { return }
            for item in pluginsMenu(for: track).items { item.menu?.removeItem(item); menu.addItem(item) }
            return
        }
        if menu.title == "MIDI Inputs" {
            connectMidiInputs()
            let sources = Engine.midiSources()
            for s in sources {
                let it = NSMenuItem(title: s.name, action: nil, keyEquivalent: "")
                it.state = openedMidiSources.contains(s.id) ? .on : .off
                it.isEnabled = false
                menu.addItem(it)
            }
            if sources.isEmpty { menu.addItem(withTitle: "No MIDI inputs connected", action: nil, keyEquivalent: "").isEnabled = false }
            return
        }
        let current = session.engine.outputDeviceUid
        let devices = Engine.outputDevices()
        let def = devices.first(where: \.isDefault)?.name
        let sys = NSMenuItem(title: "System Default" + (def.map { " (\($0))" } ?? ""),
                             action: #selector(selectOutputDevice(_:)), keyEquivalent: "")
        sys.representedObject = ""
        sys.state = current.isEmpty ? .on : .off
        sys.target = self
        menu.addItem(sys)
        menu.addItem(.separator())
        for d in devices {
            let it = NSMenuItem(title: d.name, action: #selector(selectOutputDevice(_:)), keyEquivalent: "")
            it.representedObject = d.uid
            it.state = d.uid == current ? .on : .off
            it.toolTip = String(format: "%.1f kHz · %d output channels", d.sampleRate / 1000, d.channels)
            it.target = self
            menu.addItem(it)
        }
    }

    @objc func showCommandPalette(_ sender: Any?) {
        guard let window else { return }
        palette.show(over: window)
    }

    // MARK: Tracks

    var selectedTrack: DalnokTrackId? { headers.selectedTrack }

    private func trackContextMenu() -> NSMenu {
        let m = NSMenu()
        for (title, sel) in [("Rename", #selector(renameTrack(_:))), ("Move Up", #selector(moveTrackUp(_:))),
                             ("Move Down", #selector(moveTrackDown(_:)))] {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            m.addItem(it)
        }
        let arm = NSMenuItem(title: "Record Enable", action: #selector(toggleArmTrack(_:)), keyEquivalent: "")
        arm.target = self
        m.addItem(arm)
        let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        color.submenu = colorMenu()
        m.addItem(color)
        let plugins = NSMenuItem(title: "Plug-ins", action: nil, keyEquivalent: "")
        plugins.submenu = NSMenu(title: "Track Plug-ins") // filled for the clicked track in menuNeedsUpdate
        plugins.submenu?.delegate = self
        m.addItem(plugins)
        m.addItem(.separator())
        let del = NSMenuItem(title: "Delete Track", action: #selector(deleteTrack(_:)), keyEquivalent: "")
        del.target = self
        m.addItem(del)
        return m
    }

    /// "Automatic" plus the 16 gradient swatches.
    func colorMenu() -> NSMenu {
        let m = NSMenu(title: "Color")
        let auto = NSMenuItem(title: "Automatic (Gradient)", action: #selector(setTrackColor(_:)), keyEquivalent: "")
        auto.representedObject = Int32(-1)
        auto.target = self
        m.addItem(auto)
        m.addItem(.separator())
        let names = ["Green", "Teal", "Cyan", "Azure", "Blue", "Indigo", "Violet", "Magenta", "Rose", "Red", "Orange", "Yellow"]
        for (i, c) in Theme.swatches.enumerated() {
            let it = NSMenuItem(title: names[i % names.count], action: #selector(setTrackColor(_:)), keyEquivalent: "")
            let rgb = c.usingColorSpace(.sRGB)!
            it.representedObject = Int32(Int(rgb.redComponent * 255) << 16 | Int(rgb.greenComponent * 255) << 8 | Int(rgb.blueComponent * 255))
            it.image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
                c.setFill(); NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill(); return true
            }
            it.target = self
            m.addItem(it)
        }
        return m
    }

    @objc func setTrackColor(_ sender: NSMenuItem) {
        guard let t = selectedTrack, let rgb = sender.representedObject as? Int32 else { return }
        session.setTrackColor(t, rgb: rgb)
    }

    @objc func recolorTracksAsGradient(_ sender: Any?) { session.recolorGradient() }

    @objc func newTrack(_ sender: Any?) {
        let id = session.addTrack()
        headers.selectedTrack = id
    }

    @objc func deleteTrack(_ sender: Any?) {
        guard let t = selectedTrack else { return }
        let index = session.tracks.firstIndex { $0.id == t } ?? 0
        session.removeTrack(t)
        // Keep a selection so repeated ⌘⌫ works like Logic.
        headers.selectedTrack = session.tracks.isEmpty ? nil : session.tracks[min(index, session.tracks.count - 1)].id
    }

    @objc func moveTrackUp(_ sender: Any?) { moveSelectedTrack(by: -1) }
    @objc func moveTrackDown(_ sender: Any?) { moveSelectedTrack(by: 1) }
    private func moveSelectedTrack(by d: Int) {
        guard let t = selectedTrack, let i = session.tracks.firstIndex(where: { $0.id == t }) else { return }
        let to = i + d
        guard to >= 0, to < session.tracks.count else { return }
        session.moveTrack(t, to: to)
    }

    @objc func toggleMuteTrack(_ sender: Any?) {
        guard let t = selectedTrack, let tv = session.track(t) else { return }
        session.setMute(t, !tv.muted)
    }

    @objc func toggleSoloTrack(_ sender: Any?) {
        guard let t = selectedTrack, let tv = session.track(t) else { return }
        session.setSolo(t, !tv.solo)
    }

    @objc func renameTrack(_ sender: Any?) {
        guard let t = selectedTrack else { return }
        headers.row(t)?.beginRename()
    }

    // MARK: Clip fades

    private var selectedClipView: ClipView? { timeline.selectedClip.flatMap { session.clip($0) } }

    @objc func setFadeCurveLinear(_ sender: Any?) { setCurve(DALNOK_FADE_LINEAR) }
    @objc func setFadeCurveEqualPower(_ sender: Any?) { setCurve(DALNOK_FADE_EQUAL_POWER) }
    private func setCurve(_ curve: DalnokFadeCurve) {
        guard let c = selectedClipView else { return }
        session.setFades(c.id, fadeIn: c.fadeIn, fadeOut: c.fadeOut, curve: curve)
    }

    @objc func removeFades(_ sender: Any?) {
        guard let c = selectedClipView else { return }
        session.setFades(c.id, fadeIn: 0, fadeOut: 0, curve: DalnokFadeCurve(rawValue: UInt32(c.fadeCurve)))
    }

    /// Adds 10 ms fades at both edges of the selected clip (quick de-click).
    // MARK: Speed and pitch

    private func restretch(_ f: (ClipView) -> (length: Int64, rate: Double, pitch: Float, preserve: Bool)?) {
        guard let c = selectedClipView, let v = f(c) else { NSSound.beep(); return }
        session.setStretch(c.id, length: max(1, v.length), rate: v.rate, pitch: v.pitch, preservePitch: v.preserve)
    }
    @objc func doubleSpeed(_ sender: Any?) { restretch { ($0.length / 2, $0.rate * 2, $0.pitch, $0.preservePitch) } }
    @objc func halfSpeed(_ sender: Any?) { restretch { ($0.length * 2, $0.rate / 2, $0.pitch, $0.preservePitch) } }
    @objc func transposeUp(_ sender: Any?) { restretch { ($0.length, $0.rate, min(48, $0.pitch + 1), true) } }
    @objc func transposeDown(_ sender: Any?) { restretch { ($0.length, $0.rate, max(-48, $0.pitch - 1), true) } }
    @objc func togglePreservePitch(_ sender: Any?) { restretch { ($0.length, $0.rate, $0.preservePitch ? 0 : $0.pitch, !$0.preservePitch) } }
    @objc func resetSpeedAndPitch(_ sender: Any?) { restretch { ($0.sourceSpan, 1, 0, true) } }

    @objc func addShortFades(_ sender: Any?) {
        guard let c = selectedClipView else { return }
        let f = Int64(session.engine.sampleRate * 0.01)
        session.setFades(c.id, fadeIn: max(c.fadeIn, f), fadeOut: max(c.fadeOut, f), curve: DalnokFadeCurve(rawValue: UInt32(c.fadeCurve)))
    }

    // MARK: Media

    static var copyAudioOnSave: Bool {
        get { UserDefaults.standard.object(forKey: "copyAudioOnSave") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "copyAudioOnSave") }
    }

    @objc func toggleCopyAudioOnSave(_ sender: Any?) { Self.copyAudioOnSave.toggle() }

    @objc func relinkMissingAudio(_ sender: Any?) {
        let missing = session.offlineMedia
        guard !missing.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose the missing files, or a folder to search (\(missing.count) missing: "
            + missing.prefix(3).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
            + (missing.count > 3 ? ", …)" : ")")
        panel.prompt = "Relink"
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK else { return }
            MainActor.assumeIsolated { () -> Void in
                let urls = panel.urls
                Task { await self?.relink(searching: urls) }
            }
        }
    }

    @discardableResult
    func relink(searching urls: [URL]) async -> (Int, Int) {
        let (done, still) = await session.relink(searching: urls)
        flash(still == 0 ? "Relinked \(done) file\(done == 1 ? "" : "s")" : "Relinked \(done); \(still) still missing")
        return (done, still)
    }

    // MARK: Edit

    @objc func undo(_ sender: Any?) { session.undo() }
    @objc func redo(_ sender: Any?) { session.redo() }

    @objc func openPianoRoll(_ sender: Any?) {
        guard let c = timeline.selectedClip, session.clip(c)?.isMidi == true else { return }
        pianoRoll.show(clip: c)
    }

    @objc func delete(_ sender: Any?) {
        if pianoRollIsKey { return pianoRoll.roll.deleteSelection() }
        let ids = timeline.selectedClips.sorted()
        guard !ids.isEmpty else { return }
        if !session.removeClips(ids) { NSSound.beep() }
    }

    @objc func nudgeClipsLeft(_ sender: Any?) { nudgeClips(direction: -1) }
    @objc func nudgeClipsRight(_ sender: Any?) { nudgeClips(direction: 1) }
    private func nudgeClips(direction: Int64) {
        let frames = max(1, Int64(timeline.snapQuantum().rounded())) * direction
        if !session.nudgeClips(timeline.selectedClips.sorted(), by: frames) { NSSound.beep() }
    }

    /// Splits the selected clip at the playhead, or every clip under it if none is selected.
    @objc func splitAtPlayhead() {
        let pos = session.engine.position
        let targets = timeline.selectedClips.isEmpty ? session.tracks.flatMap(\.clips)
            : timeline.selectedClips.compactMap { session.clip($0) }
        let hits = targets.filter { $0.start < pos && pos < $0.end }
        guard !hits.isEmpty else { NSSound.beep(); return }
        session.engine.group("Split at Playhead") {
            for c in hits { session.split(c.id, at: pos) }
        }
    }

    // MARK: File

    @objc func importAudio() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.message = "Each file becomes a new track."
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK else { return }
            MainActor.assumeIsolated { self?.session.importFiles(panel.urls) }
        }
    }

    @objc func newDocument(_ sender: Any?) {
        confirmDiscard { [weak self] in
            self?.session.newProject()
            self?.fitOnNextChange = true
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        // Logic packages may have a dynamic UTI; filter by extension instead.
        panel.delegate = self
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a Dalnok project, a project from another DAW, or a folder of stems."
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.openSelectedProject(url) }
        }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return true }
        return (["dalnok"] + Array(Self.foreignExtensions)).contains(url.pathExtension.lowercased())
    }

    /// Foreign projects are imported only after the user chooses Import.
    func openSelectedProject(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        let ext = url.pathExtension.lowercased()
        var directory: ObjCBool = false
        let isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        let foreign = ext != "dalnok" && (Self.foreignExtensions.contains(ext) || isDirectory)
        guard foreign else {
            confirmDiscard { [weak self] in self?.openProject(url, completion: completion) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Import this project?"
        alert.informativeText = "Dalnok will import \(url.lastPathComponent) into a new project. The original will remain unchanged."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard let window else { completion?(false); return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { completion?(false); return }
            self?.importProject(url, completion: completion)
        }
    }

    // MARK: Migration

    /// Imports into a new unsaved project (after resolving unsaved changes) and shows the report.
    func importProject(_ url: URL, confirm: Bool = true, completion: ((Bool) -> Void)? = nil) {
        let run = { [weak self] in
            guard let self else { return }
            Task {
                do {
                    self.fitOnNextChange = true
                    let report = try await self.session.importForeign(url)
                    self.lastImportReport = report
                    self.updateTitle()
                    if let report {
                        self.flash("Imported from \(report.app): \(report.summary)")
                        if !SelfTest.running, let w = self.window {
                            let guide = self.conceptGuide
                            ImportReportController.present(report, source: url, over: w) {
                                guide.show(daw: SourceDAW.allCases.first { $0.title == report.app })
                            }
                        }
                    }
                    completion?(true)
                } catch {
                    self.fitOnNextChange = false
                    self.presentError(title: "Couldn't import \(url.lastPathComponent)", error)
                    completion?(false)
                }
            }
        }
        confirm ? confirmDiscard(run) : run()
    }

    @objc func showSettings(_ sender: Any?) { settings.show() }

    @objc func showConceptGuide(_ sender: Any?) { conceptGuide.show(daw: SourceDAW.preferred) }
    @objc func showMigrationAssistant(_ sender: Any?) { welcome.show() }

    func openProject(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        Task {
            do {
                fitOnNextChange = true
                try await session.open(url)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                completion?(true)
            } catch {
                fitOnNextChange = false
                presentError(title: "Couldn't open \(url.lastPathComponent)", error)
                completion?(false)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if let url = session.projectURL { saveProject(to: url) } else { saveDocumentAs(sender) }
    }

    @objc func saveDocumentAs(_ sender: Any?) { saveAs() }

    /// Save As; `then` runs after a successful save, `otherwise` if it's cancelled or fails.
    func saveAs(then: (() -> Void)? = nil, otherwise: (() -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.dalnokProject]
        panel.nameFieldStringValue = session.projectURL?.lastPathComponent ?? "Untitled.dalnok"
        let copy = NSButton(checkboxWithTitle: "Copy audio files into an “Audio Files” folder next to the project",
                            target: nil, action: nil)
        copy.state = Self.copyAudioOnSave ? .on : .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 36))
        copy.frame = NSRect(x: 12, y: 8, width: 440, height: 20)
        box.addSubview(copy)
        panel.accessoryView = box
        panel.beginSheetModal(for: window!) { [weak self] resp in
            MainActor.assumeIsolated { () -> Void in
                guard resp == .OK, let url = panel.url else { otherwise?(); return }
                Self.copyAudioOnSave = copy.state == .on
                if self?.saveProject(to: url) == true { then?() } else { otherwise?() }
            }
        }
    }

    @discardableResult
    func saveProject(to url: URL) -> Bool {
        do {
            try session.save(to: url, copyAudio: Self.copyAudioOnSave)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            updateTitle()
            return true
        } catch {
            presentError(title: "Couldn't save", error)
            return false
        }
    }

    @objc func exportMix(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Mix") + ".wav"
        panel.message = "Exports the full arrangement as a 24-bit WAV."
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { () -> Void in self?.exportMix(to: url) }
        }
    }

    @discardableResult
    func exportMix(to url: URL) -> Bool {
        do {
            let t0 = Date()
            try session.engine.exportWav(to: url)
            flash(String(format: "Exported %@ in %.0f ms", url.lastPathComponent, Date().timeIntervalSince(t0) * 1000))
            return true
        } catch {
            presentError(title: "Export failed", error)
            return false
        }
    }

    /// Runs `proceed` after resolving unsaved changes (Save / Don't Save / Cancel).
    /// Asks to save unsaved changes. `cancelled` runs when the person cancels (or saving fails), so callers
    /// waiting on an answer (like quitting) always get one.
    func confirmDiscard(_ proceed: @escaping () -> Void, cancelled: (() -> Void)? = nil) {
        guard session.engine.isDirty else { proceed(); return }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(window?.title ?? "Untitled")”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] resp in
            MainActor.assumeIsolated { () -> Void in
                guard let self else { return }
                switch resp {
                case .alertFirstButtonReturn:
                    if let url = self.session.projectURL {
                        if self.saveProject(to: url) { proceed() } else { cancelled?() }
                    } else {
                        self.saveAs(then: proceed, otherwise: cancelled)
                    }
                case .alertSecondButtonReturn: proceed()
                default: cancelled?()
                }
            }
        }
    }

    func presentError(title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window!)
    }

    // MARK: View

    static var metronomeOn: Bool {
        get { UserDefaults.standard.bool(forKey: "metronome") }
        set { UserDefaults.standard.set(newValue, forKey: "metronome") }
    }
    @objc func toggleMetronome(_ sender: Any?) {
        Self.metronomeOn.toggle()
        applyMetronome()
        flash(Self.metronomeOn ? "Metronome on" : "Metronome off")
    }
    func applyMetronome() {
        dalnok_metronome_set(session.engine.handle, Self.metronomeOn, 0.5)
        transport.metronomeButton.setSymbol("metronome.fill", tint: Self.metronomeOn ? Theme.accent : Theme.textDim)
        transport.metronomeButton.setAccessibilityValue(Self.metronomeOn ? "on" : "off")
    }

    @objc func toggleDevicePanel(_ sender: Any?) {
        Self.showDevicePanel.toggle()
        let show = Self.showDevicePanel
        if show { devicePanel.isHidden = false }
        let panel = devicePanel
        Motion.views(Motion.gentle, { devicePanelHeight.animator().constant = show ? DevicePanel.height : 0 }, completion: {
            DispatchQueue.main.async { if !show { panel.isHidden = true } }
        })
        if Motion.reduced { devicePanel.isHidden = !show }
    }

    @objc func toggleBarsAndBeats(_ sender: Any?) {
        TimelineView.barsAndBeats.toggle()
        timeline.needsDisplay = true
        updateTempoDisplay()
    }

    /// Index of the tempo point and meter change in effect at the playhead.
    func tempoSegmentAtPlayhead() -> (tempo: Int, meter: Int, beat: Double) {
        let beat = session.frameToBeat(Double(session.engine.position))
        let tempo = session.tempoPoints.lastIndex { $0.beat <= beat + 1e-9 } ?? 0
        let bar = session.bar(atBeat: beat).bar
        let meter = session.meterPoints.lastIndex { Int($0.bar) <= bar } ?? 0
        return (tempo, meter, beat)
    }

    func updateTempoDisplay() {
        let at = tempoSegmentAtPlayhead()
        let tempo = session.tempoPoints, meters = session.meterPoints
        let bpm = tempo.indices.contains(at.tempo) ? tempo[at.tempo].bpm : session.bpm
        if transport.tempoField.currentEditor() == nil { transport.tempoField.stringValue = String(format: "%g", bpm) }
        let m = meters.indices.contains(at.meter) ? meters[at.meter] : DalnokMeterPoint(bar: 0, numerator: 4, denominator: 4)
        let title = "\(m.numerator)/\(m.denominator)"
        if transport.meterPopup.item(withTitle: title) == nil { transport.meterPopup.addItem(withTitle: title) }
        transport.meterPopup.selectItem(withTitle: title)
        let changes = tempo.count > 1 || meters.count > 1
        transport.tempoField.toolTip = changes ? "Tempo at the playhead (this project has tempo or meter changes)" : "Tempo"
        transport.timeLabel.toolTip = TimelineView.barsAndBeats ? "Bar . beat . sixteenth . tick" : "Minutes : seconds"
        shownTempoSegment = (at.tempo, at.meter)
    }
    private var shownTempoSegment = (0, 0)

    /// Keeps the tempo and meter display on the playhead's segment while it moves.
    func followTempoSegment() {
        guard session.tempoPoints.count > 1 || session.meterPoints.count > 1 else { return }
        let at = tempoSegmentAtPlayhead()
        if at.tempo != shownTempoSegment.0 || at.meter != shownTempoSegment.1 { updateTempoDisplay() }
    }

    @objc func tempoEdited(_ sender: Any?) {
        var tempo = session.tempoPoints
        let at = tempoSegmentAtPlayhead()
        guard let bpm = Double(transport.tempoField.stringValue.replacingOccurrences(of: ",", with: ".")),
              tempo.indices.contains(at.tempo) else { flash("Tempo must be 20–400 BPM"); return updateTempoDisplay() }
        tempo[at.tempo].bpm = bpm
        guard session.setTempoMap(tempo, session.meterPoints) else {
            flash("Tempo must be 20–400 BPM")
            return updateTempoDisplay()
        }
        timeline.needsDisplay = true
        window?.makeFirstResponder(nil)
    }

    @objc func editTempo(_ sender: Any?) { transport.tempoField.beginEditing() }

    @objc func meterChosen(_ sender: Any?) {
        let parts = (transport.meterPopup.titleOfSelectedItem ?? "4/4").split(separator: "/").compactMap { Int32($0) }
        var meters = session.meterPoints
        let at = tempoSegmentAtPlayhead()
        guard parts.count == 2, meters.indices.contains(at.meter) else { return }
        meters[at.meter].numerator = parts[0]; meters[at.meter].denominator = parts[1]
        if !session.setTempoMap(session.tempoPoints, meters) { flash("Couldn't change the time signature") }
        timeline.needsDisplay = true
    }

    /// Adds a tempo change at the playhead (rounded to a 16th note), starting at the current tempo, then edits it.
    @objc func addTempoChange(_ sender: Any?) {
        var tempo = session.tempoPoints
        let at = tempoSegmentAtPlayhead()
        let beat = (at.beat * 4).rounded() / 4
        guard beat > 0 else { return editTempo(nil) }
        if let i = tempo.firstIndex(where: { abs($0.beat - beat) < 1e-9 }) { _ = i; return editTempo(nil) }
        tempo.append(DalnokTempoPoint(beat: beat, bpm: session.tempo(atBeat: beat)))
        tempo.sort { $0.beat < $1.beat }
        guard session.setTempoMap(tempo, session.meterPoints) else { return flash("Couldn't add a tempo change here") }
        flash("Tempo change at \(timeline.barsLabel(session.beatToFrame(beat), wholeBars: false)): type the new tempo")
        updateTempoDisplay()
        editTempo(nil)
    }

    /// Adds a meter change at the bar the playhead is in (or the next bar if it's past the downbeat).
    @objc func addMeterChange(_ sender: Any?) {
        var meters = session.meterPoints
        let b = session.bar(atBeat: tempoSegmentAtPlayhead().beat)
        let bar = Int32(b.beatInBar < 1e-6 ? b.bar : b.bar + 1)
        guard bar > 0, !meters.contains(where: { $0.bar == bar }) else { return flash("There's already a time signature at bar \(bar + 1)") }
        meters.append(DalnokMeterPoint(bar: bar, numerator: Int32(b.num), denominator: Int32(b.den)))
        meters.sort { $0.bar < $1.bar }
        guard session.setTempoMap(session.tempoPoints, meters) else { return flash("Couldn't add a time signature here") }
        session.engine.seek(Int64(session.beatToFrame(session.barToBeat(Int(bar))).rounded()))
        flash("Time signature change at bar \(bar + 1): choose it in the control bar")
        updateTempoDisplay()
    }

    @objc func removeTempoChange(_ sender: Any?) {
        var tempo = session.tempoPoints
        let at = tempoSegmentAtPlayhead()
        guard at.tempo > 0 else { return }
        tempo.remove(at: at.tempo)
        if session.setTempoMap(tempo, session.meterPoints) { flash("Removed the tempo change") }
    }

    @objc func removeMeterChange(_ sender: Any?) {
        var meters = session.meterPoints
        let at = tempoSegmentAtPlayhead()
        guard at.meter > 0 else { return }
        meters.remove(at: at.meter)
        if session.setTempoMap(session.tempoPoints, meters) { flash("Removed the time signature change") }
    }

    /// Keyboard zoom keeps the playhead where it is when it's on screen, otherwise the view's centre.
    private var zoomAnchor: CGFloat {
        let x = timeline.xPos(forFrame: Double(session.engine.position))
        return x >= 0 && x <= timeline.bounds.width ? x : timeline.bounds.midX
    }
    @objc func zoomIn() { timeline.zoom(by: 0.5, around: zoomAnchor) }
    @objc func zoomOut() { timeline.zoom(by: 2, around: zoomAnchor) }
    @objc func zoomToFit() { timeline.zoomToFit() }

    // MARK: Menu validation

    /// True while a text field is being edited (track rename, palette search…).
    /// Unmodified shortcuts (Space, ↩, ⌫) must then reach the text, not the menu.
    static var isTyping: Bool {
        if let key = NSApp.keyWindow { return key.firstResponder is NSText }
        // App not active (e.g. driven by automation): any visible window editing text.
        return NSApp.windows.contains { $0.isVisible && $0.firstResponder is NSText }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.keyEquivalentModifierMask.isEmpty, !item.keyEquivalent.isEmpty, Self.isTyping { return false }
        switch item.action {
        case #selector(undo(_:)):
            item.title = session.engine.canUndo ? "Undo \(session.engine.undoName)" : "Undo"
            return session.engine.canUndo
        case #selector(redo(_:)):
            item.title = session.engine.canRedo ? "Redo \(session.engine.redoName)" : "Redo"
            return session.engine.canRedo
        case #selector(delete(_:)):
            return pianoRollIsKey ? !pianoRoll.roll.selection.isEmpty : timeline.selectedClip != nil
        case #selector(nudgeClipsLeft(_:)), #selector(nudgeClipsRight(_:)):
            return !pianoRollIsKey && !timeline.selectedClips.isEmpty
        case #selector(openPianoRoll(_:)):
            return selectedClipView?.isMidi == true
        case #selector(deleteTrack(_:)), #selector(renameTrack(_:)):
            return selectedTrack != nil
        case #selector(moveTrackUp(_:)):
            return selectedTrack != nil && session.tracks.first?.id != selectedTrack
        case #selector(moveTrackDown(_:)):
            return selectedTrack != nil && session.tracks.last?.id != selectedTrack
        case #selector(toggleMuteTrack(_:)):
            item.state = selectedTrack.flatMap { session.track($0) }?.muted == true ? .on : .off
            return selectedTrack != nil
        case #selector(toggleSoloTrack(_:)):
            item.state = selectedTrack.flatMap { session.track($0) }?.solo == true ? .on : .off
            return selectedTrack != nil
        case #selector(setFadeCurveLinear(_:)), #selector(setFadeCurveEqualPower(_:)):
            let eq = item.action == #selector(setFadeCurveEqualPower(_:))
            item.state = selectedClipView.map { ($0.fadeCurve == 1) == eq } == true ? .on : .off
            return selectedClipView != nil
        case #selector(removeFades(_:)):
            return selectedClipView.map { $0.fadeIn > 0 || $0.fadeOut > 0 } ?? false
        case #selector(addShortFades(_:)), #selector(doubleSpeed(_:)), #selector(halfSpeed(_:)),
             #selector(transposeUp(_:)), #selector(transposeDown(_:)):
            return selectedClipView.map { !$0.isMidi } ?? false
        case #selector(togglePreservePitch(_:)):
            item.state = selectedClipView?.preservePitch == false ? .off : .on
            return selectedClipView.map { !$0.isMidi } ?? false
        case #selector(quantizeClip(_:)):
            return selectedClipView?.isMidi == true
        case #selector(newMidiClip(_:)):
            return selectedTrack.flatMap { session.track($0) }?.isInstrument == true
        case #selector(toggleArmTrack(_:)):
            item.state = selectedTrack.flatMap { session.track($0) }?.armed == true ? .on : .off
            return selectedTrack != nil && !session.engine.isRecording
        case #selector(toggleRecord(_:)):
            item.title = session.engine.isRecording ? "Stop Recording" : "Record"
            return true
        case #selector(toggleMetronome(_:)):
            item.state = Self.metronomeOn ? .on : .off
            return true
        case #selector(removeTempoChange(_:)):
            return tempoSegmentAtPlayhead().tempo > 0
        case #selector(removeMeterChange(_:)):
            return tempoSegmentAtPlayhead().meter > 0
        case #selector(toggleDevicePanel(_:)):
            item.state = Self.showDevicePanel ? .on : .off
            return true
        case #selector(toggleBarsAndBeats(_:)):
            item.state = TimelineView.barsAndBeats ? .on : .off
            return true
        case #selector(toggleInputMonitoring(_:)):
            item.state = Self.inputMonitoring ? .on : .off
            return true
        case #selector(resetSpeedAndPitch(_:)):
            return selectedClipView?.isStretched == true
        case #selector(setTrackColor(_:)):
            guard let t = selectedTrack.flatMap({ session.track($0) }), let rgb = item.representedObject as? Int32 else { return false }
            item.state = t.customColor == rgb ? .on : .off
            return true
        case #selector(recolorTracksAsGradient(_:)):
            return session.tracks.count > 1
        case #selector(toggleCopyAudioOnSave(_:)):
            item.state = Self.copyAudioOnSave ? .on : .off
            return true
        case #selector(relinkMissingAudio(_:)):
            return !session.offlineMedia.isEmpty
        case #selector(exportMix(_:)):
            return session.length > 0
        default:
            return true
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if session.engine.isDirty && session.length > 0 {
            confirmDiscard { NSApp.terminate(nil) }
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    /// Renders the window contents to a PNG (used for automated UI checks).
    func snapshot(to url: URL) throws {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw EngineError(description: "no content view")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw EngineError(description: "PNG encode failed")
        }
        try png.write(to: url)
    }
}

/// Accepts dropped audio files and Dalnok projects.
@MainActor
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.window.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func audioURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter {
            (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) ?? false)
                || MainWindowController.foreignExtensions.contains($0.pathExtension.lowercased()) || $0.hasDirectoryPath
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        audioURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = audioURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
