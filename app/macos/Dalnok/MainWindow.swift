// Main window composition, commands, menus validation, project lifecycle.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine
import UniformTypeIdentifiers

extension UTType {
    static let dalnokProject = UTType(filenameExtension: "dalnok", conformingTo: .json) ?? .json
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    let session: Session
    let palette = CommandPalette()
    let emptyState = EmptyStateView()
    lazy var conceptGuide = ConceptGuideController()
    lazy var welcome = WelcomeController(main: self)
    private(set) var lastImportReport: ImportReport?
    static let foreignExtensions: Set<String> = ["rpp", "als", "logicx", "fcpxml", "fcpxmld"]
    private var tickCount = 0
    let transport = TransportBar()
    let headers: TrackHeaderColumn
    let timeline: TimelineView
    private var timer: Timer?
    private var wasPlaying = false
    var fitOnNextChange = true

    init(session: Session) {
        self.session = session
        headers = TrackHeaderColumn(session: session)
        timeline = TimelineView(session: session)

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
        for v in [transport, headers, timeline, emptyState] as [NSView] {
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
            headers.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            headers.widthAnchor.constraint(equalToConstant: Theme.headerWidth),
            timeline.topAnchor.constraint(equalTo: transport.bottomAnchor),
            timeline.leadingAnchor.constraint(equalTo: headers.trailingAnchor),
            timeline.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.topAnchor.constraint(equalTo: transport.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        emptyState.onImportAudio = { [weak self] in self?.importAudio() }
        emptyState.onOpen = { [weak self] in self?.openDocument(nil) }
        emptyState.onMigrate = { [weak self] in self?.showMigrationAssistant(nil) }

        transport.onPlayPause = { [weak self] in self?.togglePlay() }
        transport.onRewind = { [weak self] in self?.goToStart() }
        transport.onImport = { [weak self] in self?.importAudio() }
        transport.onPalette = { [weak self] in self?.showCommandPalette(nil) }
        headers.onAddTrack = { [weak self] in self?.newTrack(nil) }
        timeline.onVerticalScroll = { [weak self] y in self?.headers.scrollY = y }
        timeline.onClipSelected = { [weak self] clip in self?.headers.selectedTrack = clip.track }
        headers.contextMenu = trackContextMenu()
        headers.onSelect = { [weak self] id in self?.timeline.highlightedTrack = id }
        palette.onOpenGuide = { [weak self] c in self?.conceptGuide.show(daw: c.daw, query: c.term) }
        session.onChange = { [weak self] in self?.modelChanged() }
        session.onMessage = { [weak self] msg in self?.flash(msg) }
        modelChanged()

        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Model → UI

    private func modelChanged() {
        headers.sync()
        emptyState.isHidden = !session.tracks.isEmpty
        headers.isHidden = session.tracks.isEmpty
        timeline.isHidden = session.tracks.isEmpty
        if let sel = timeline.selectedClip, session.clip(sel) == nil { timeline.selectedClip = nil }
        if fitOnNextChange && !session.tracks.isEmpty {
            timeline.zoomToFit()
            fitOnNextChange = false
        }
        timeline.needsDisplay = true
        updateTitle()
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
        transport.statusLabel.stringValue = msg
        transientMessageUntil = Date().addingTimeInterval(4)
    }

    private func updateStatus() {
        let e = session.engine
        let sr = e.sampleRate
        let n = session.tracks.count
        _ = (sr, n)
        transport.statusLabel.stringValue = outputDeviceDescription()
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
        let playing = e.isPlaying
        if playing != wasPlaying {
            transport.setPlaying(playing)
            wasPlaying = playing
        }
        transport.timeLabel.stringValue = TimelineView.formatTime(Double(e.position) / e.sampleRate)
        timeline.followPlayhead()
        timeline.updatePlayhead()
        for row in headers.rows {
            let (l, r) = e.trackMeter(row.trackId)
            row.meter.push(l, r)
            row.gain.updateMeter(max(row.meter.levelDb.0, row.meter.levelDb.1))
        }
        let (ml, mr) = e.masterMeter()
        transport.masterMeter.push(ml, mr)
        tickCount += 1
        if tickCount % 30 == 0 && !e.deviceAlive { deviceLost() }
        if transientMessageUntil < Date(), transientMessageUntil != .distantPast {
            transientMessageUntil = .distantPast
            updateStatus()
        }
    }

    // MARK: Transport

    @objc func togglePlay() {
        let e = session.engine
        e.isPlaying ? e.pause() : e.play()
    }

    @objc func goToStart() {
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
        let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        color.submenu = colorMenu()
        m.addItem(color)
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

    @objc func delete(_ sender: Any?) {
        guard let c = timeline.selectedClip else { return }
        session.removeClip(c)
    }

    /// Splits the selected clip at the playhead, or every clip under it if none is selected.
    @objc func splitAtPlayhead() {
        let pos = session.engine.position
        let targets = timeline.selectedClip.flatMap { session.clip($0) }.map { [$0] }
            ?? session.tracks.flatMap(\.clips)
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
        confirmDiscard { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.dalnokProject] + Self.foreignExtensions.compactMap { UTType(filenameExtension: $0) }
            panel.treatsFilePackagesAsDirectories = false
            panel.message = "Open a Dalnok project — or a Logic, Ableton or REAPER project to import."
            panel.beginSheetModal(for: window!) { resp in
                guard resp == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated {
                    if Self.foreignExtensions.contains(url.pathExtension.lowercased()) { self.importProject(url, confirm: false) }
                    else { self.openProject(url) }
                }
            }
        }
    }

    // MARK: Migration

    @objc func importProjectFromDAW(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowedContentTypes = Self.foreignExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.message = "Choose a Logic (.logicx), Ableton (.als), REAPER (.rpp) or Final Cut Pro XML project — or a folder of stems."
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.importProject(url) }
        }
    }

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

    @objc func saveDocumentAs(_ sender: Any?, then: (() -> Void)? = nil) {
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
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { () -> Void in
                Self.copyAudioOnSave = copy.state == .on
                if self?.saveProject(to: url) == true { then?() }
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
    func confirmDiscard(_ proceed: @escaping () -> Void) {
        guard session.engine.isDirty, session.length > 0 || session.engine.canUndo else { proceed(); return }
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
                        if self.saveProject(to: url) { proceed() }
                    } else {
                        self.saveDocumentAs(nil, then: proceed)
                    }
                case .alertSecondButtonReturn: proceed()
                default: break
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

    @objc func zoomIn() { timeline.zoom(by: 0.5, around: timeline.bounds.midX) }
    @objc func zoomOut() { timeline.zoom(by: 2, around: timeline.bounds.midX) }
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
            return timeline.selectedClip != nil
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
            return selectedClipView != nil
        case #selector(togglePreservePitch(_:)):
            item.state = selectedClipView?.preservePitch == false ? .off : .on
            return selectedClipView != nil
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
