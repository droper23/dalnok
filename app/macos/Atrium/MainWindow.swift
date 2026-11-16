// Main window composition, menus, keyboard shortcuts, drag-and-drop.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let session: Session
    let transport = TransportBar()
    let headers: TrackHeaderColumn
    let timeline: TimelineView
    private var timer: Timer?
    private var wasPlaying = false

    init(session: Session) {
        self.session = session
        headers = TrackHeaderColumn(session: session)
        timeline = TimelineView(session: session)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Atrium"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.window
        window.minSize = NSSize(width: 720, height: 400)
        window.setFrameAutosaveName("AtriumMain")
        super.init(window: window)
        window.delegate = self

        let root = DropView()
        root.onDrop = { [weak self] urls in self?.session.importFiles(urls) }
        window.contentView = root
        for v in [transport, headers, timeline] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let titlebar: CGFloat = 28
        NSLayoutConstraint.activate([
            transport.topAnchor.constraint(equalTo: root.topAnchor, constant: titlebar),
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
        session.onChange = { [weak self] in self?.sessionChanged() }
        session.onError = { [weak self] msg in self?.transport.statusLabel.stringValue = msg }
        updateStatus()

        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var firstImport = true
    private func sessionChanged() {
        headers.reload()
        if firstImport { timeline.zoomToFit(); firstImport = false }
        timeline.needsDisplay = true
        updateStatus()
    }

    private func updateStatus() {
        let sr = session.engine.sampleRate
        let n = session.tracks.count
        transport.statusLabel.stringValue = n == 0
            ? "Drop audio files anywhere, or press ⌘I to import  ·  \(Int(sr)) Hz"
            : "\(n) track\(n == 1 ? "" : "s")  ·  \(TimelineView.formatTime(Double(session.length) / sr)) long  ·  \(Int(sr)) Hz"
    }

    private func tick() {
        let e = session.engine
        e.collectGarbage()
        let playing = e.isPlaying
        if playing != wasPlaying {
            transport.setPlaying(playing)
            wasPlaying = playing
        }
        transport.timeLabel.stringValue = TimelineView.formatTime(Double(e.position) / e.sampleRate)
        timeline.followPlayhead()
        timeline.updatePlayhead()
    }

    // MARK: Commands

    @objc func togglePlay() {
        let e = session.engine
        e.isPlaying ? e.pause() : e.play()
    }

    @objc func goToStart() {
        session.engine.seek(0)
        timeline.scrollFrame = 0
    }

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

    @objc func zoomIn() { timeline.zoom(by: 0.5, around: timeline.bounds.midX) }
    @objc func zoomOut() { timeline.zoom(by: 2, around: timeline.bounds.midX) }
    @objc func zoomToFit() { timeline.zoomToFit() }

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

/// Accepts dropped audio files.
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
