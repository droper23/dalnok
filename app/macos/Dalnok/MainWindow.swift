// Main window composition, commands, menus validation, project lifecycle.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine
import UniformTypeIdentifiers

extension UTType {
    static let dalnokProject = UTType(filenameExtension: "dalnok", conformingTo: .json) ?? .json
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: Session
    let transport = TransportBar()
    let headers: TrackHeaderColumn
    let timeline: TimelineView
    private var timer: Timer?
    private var wasPlaying = false
    private var fitOnNextChange = true

    init(session: Session) {
        self.session = session
        headers = TrackHeaderColumn(session: session)
        timeline = TimelineView(session: session)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.window
        window.minSize = NSSize(width: 720, height: 400)
        window.setFrameAutosaveName("DalnokMain")
        super.init(window: window)
        window.delegate = self

        let root = DropView()
        root.onDrop = { [weak self] urls in self?.session.importFiles(urls) }
        window.contentView = root
        for v in [transport, headers, timeline] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            transport.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
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
        ])

        transport.onPlayPause = { [weak self] in self?.togglePlay() }
        transport.onRewind = { [weak self] in self?.goToStart() }
        transport.onImport = { [weak self] in self?.importAudio() }
        timeline.onVerticalScroll = { [weak self] y in self?.headers.scrollY = y }
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
        if let sel = timeline.selectedClip, session.clip(sel) == nil { timeline.selectedClip = nil }
        if fitOnNextChange && !session.tracks.isEmpty {
            timeline.zoomToFit()
            fitOnNextChange = false
        }
        timeline.needsDisplay = true
        updateTitle()
        if transientMessageUntil < Date() { updateStatus() }
    }

    private func updateTitle() {
        window?.title = session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        window?.representedURL = session.projectURL
        window?.isDocumentEdited = session.engine.isDirty
    }

    private var transientMessageUntil = Date.distantPast
    func flash(_ msg: String) {
        transport.statusLabel.stringValue = msg
        transientMessageUntil = Date().addingTimeInterval(4)
    }

    private func updateStatus() {
        let sr = session.engine.sampleRate
        let n = session.tracks.count
        transport.statusLabel.stringValue = n == 0
            ? "\(Int(sr)) Hz"
            : "\(n) track\(n == 1 ? "" : "s")  ·  \(TimelineView.formatTime(Double(session.length) / sr)) long  ·  \(Int(sr)) Hz  ·  hold ⌃ while dragging to bypass snap"
    }

    private func tick() {
        let e = session.engine
        e.collectGarbage()
        session.refresh() // picks up changes from any source (e.g. scripts)
        let playing = e.isPlaying
        if playing != wasPlaying {
            transport.setPlaying(playing)
            wasPlaying = playing
        }
        transport.timeLabel.stringValue = TimelineView.formatTime(Double(e.position) / e.sampleRate)
        timeline.followPlayhead()
        timeline.updatePlayhead()
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
            panel.allowedContentTypes = [.dalnokProject]
            panel.beginSheetModal(for: window!) { resp in
                guard resp == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { self.openProject(url) }
            }
        }
    }

    func openProject(_ url: URL) {
        do {
            fitOnNextChange = true
            try session.open(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            presentError(title: "Couldn't open \(url.lastPathComponent)", error)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if let url = session.projectURL { saveProject(to: url) } else { saveDocumentAs(sender) }
    }

    @objc func saveDocumentAs(_ sender: Any?, then: (() -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.dalnokProject]
        panel.nameFieldStringValue = session.projectURL?.lastPathComponent ?? "Untitled.dalnok"
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { () -> Void in
                if self?.saveProject(to: url) == true { then?() }
            }
        }
    }

    @discardableResult
    func saveProject(to url: URL) -> Bool {
        do {
            try session.save(to: url)
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

    private func presentError(title: String, _ error: Error) {
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            item.title = session.engine.canUndo ? "Undo \(session.engine.undoName)" : "Undo"
            return session.engine.canUndo
        case #selector(redo(_:)):
            item.title = session.engine.canRedo ? "Redo \(session.engine.redoName)" : "Redo"
            return session.engine.canRedo
        case #selector(delete(_:)):
            return timeline.selectedClip != nil
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
        return urls.filter { (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio)) ?? false }
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
