// The new-project screen, built on what Logic's Project Chooser, Studio One's Start page, Pro Tools' Dashboard,
// Cubase's Hub and Bitwig's Dashboard share (06 - Design/New Project Screen 2026-11-21.md): the project's basics
// (tempo, time signature, the audio device and its sample rate) before the first recording, one focused way to start
// (the first track), and recent projects one click away. No templates and no shortcut lessons: people chose the
// shortcuts they know at first launch. The whole page is still a drop zone for audio files and projects.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A large, clickable choice. Hovering lifts it (border, shadow, a 2 pt rise); pressing sinks it.
@MainActor
final class StartCard: NSButton {
    private var hovering = false { didSet { if hovering != oldValue { restyle(animated: true) } } }

    init(title t: String, detail d: String, symbol: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        if Theme.activeStyle == .atelier, let l = layer { // a card sketched on the page
            l.cornerRadius = 0
            SketchBorderLayer.attach(to: l, color: Theme.ink(0.7), width: 1, seed: Atelier.seed(CGPoint(x: CGFloat(title.count), y: 3)), overshoot: 4)
        }
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        setAccessibilityLabel(t)
        setAccessibilityHelp(d)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))!)
        icon.contentTintColor = Theme.accent
        icon.setAccessibilityElement(false)
        let name = NSTextField(labelWithString: t)
        name.font = Theme.ui(14, .semibold)
        name.textColor = Theme.text
        let detail = NSTextField(labelWithString: d)
        detail.font = Theme.ui(11.5)
        detail.textColor = Theme.textDim
        detail.lineBreakMode = .byTruncatingTail
        for v in [name, detail, icon] as [NSView] { v.setAccessibilityElement(false) }
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(equalToConstant: 280), heightAnchor.constraint(equalToConstant: 72),
        ])
        restyle(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        Motion.centerAnchor(layer)
        Motion.layers(Motion.quick) { layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1) }
        super.mouseDown(with: event) // tracks until mouse up and sends the action if released inside
        Motion.layers(Motion.standard) { layer?.transform = CATransform3DIdentity }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {} // the layer draws the card; focus ring below

    private func restyle(animated: Bool) {
        let body = {
            self.layer?.backgroundColor = (self.hovering ? Theme.ink(0.075) : Theme.ink(0.04)).cgColor
            self.layer?.borderColor = (self.hovering ? Theme.accent.withAlphaComponent(0.55) : Theme.ink(0.08)).cgColor
            self.layer?.shadowOpacity = self.hovering ? 0.35 : 0
            self.layer?.shadowRadius = self.hovering ? 12 : 4
            self.layer?.sublayerTransform = CATransform3DMakeTranslation(0, self.hovering ? 2 : 0, 0)
        }
        if animated { Motion.layers(Motion.standard, body) } else { CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit() }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
}

@MainActor
final class EmptyStateView: NSView, NSTextFieldDelegate {
    var onImportAudio: (() -> Void)?
    var onOpen: (() -> Void)?
    var onMigrate: (() -> Void)?
    var onNewInstrument: (() -> Void)?
    var onNewAudioTrack: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    var onTempo: ((Double) -> Void)?
    var onMeter: ((Int32, Int32) -> Void)?
    var onAudioSettings: (() -> Void)?
    /// What the page shows for the project and the audio device; asked each time the page appears.
    var basics: (() -> (bpm: Double, meter: (Int32, Int32), output: String, input: String))?

    /// Automated runs (snapshots, screenshots, self-test, tours) never list recent projects: their names are the
    /// owner's and must not land in a picture.
    static let showsRecents: Bool = {
        let a = CommandLine.arguments
        return !["--snapshot", "--screenshots", "--gallery", "--selftest", "--uiwalk", "--tour", "--perf"].contains(where: a.contains)
    }()
    static let meters = ["2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "12/8"]

    private(set) var cards: [StartCard] = []
    let tempoField = NSTextField(string: "120")
    let meterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let outputLabel = NSTextField(labelWithString: "")
    let inputLabel = NSTextField(labelWithString: "")
    private let recentsStack = NSStackView()
    private var entrance: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let title = NSTextField(labelWithString: "New Project")
        title.font = Theme.title(24, .semibold)
        title.textColor = Theme.text
        let sub = NSTextField(labelWithString: "Set the basics, then add your first track. You can drop audio files anywhere in this window.")
        sub.font = Theme.ui(12.5)
        sub.textColor = Theme.textDim

        // Project basics: tempo and time signature (Logic and Studio One ask before the first recording, since
        // recordings are laid against them), and the device the project plays and records through, with its rate.
        tempoField.font = Theme.mono(13, .medium)
        tempoField.alignment = .right
        tempoField.delegate = self
        tempoField.setAccessibilityLabel("Tempo in BPM")
        tempoField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        meterPopup.addItems(withTitles: Self.meters)
        meterPopup.target = self
        meterPopup.action = #selector(meterChosen)
        meterPopup.setAccessibilityLabel("Time signature")
        let bpm = small("BPM")
        let tempoRow = NSStackView(views: [field("Tempo"), tempoField, bpm, spacer(18), field("Time signature"), meterPopup])
        tempoRow.spacing = 8
        for l in [outputLabel, inputLabel] { l.font = Theme.ui(12.5); l.textColor = Theme.text; l.lineBreakMode = .byTruncatingTail }
        let audioButton = NSButton(title: "Audio Settings…", target: self, action: #selector(audioTapped))
        audioButton.bezelStyle = .rounded
        audioButton.controlSize = .small
        let outRow = NSStackView(views: [field("Output"), outputLabel])
        let inRow = NSStackView(views: [field("Input"), inputLabel])
        for r in [outRow, inRow] { r.spacing = 8 }
        let devices = NSStackView(views: [outRow, inRow])
        devices.orientation = .vertical
        devices.alignment = .leading
        devices.spacing = 6
        let audio = NSStackView(views: [devices, NSView(), audioButton])
        audio.alignment = .centerY
        let basicsStack = NSStackView(views: [tempoRow, divider(), audio])
        basicsStack.orientation = .vertical
        basicsStack.alignment = .leading
        basicsStack.spacing = 12
        basicsStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 14)
        let basicsBox = panel(basicsStack)
        audio.widthAnchor.constraint(equalTo: basicsStack.widthAnchor, constant: -30).isActive = true

        cards = [
            StartCard(title: "Audio Track", detail: "Record a microphone or an instrument", symbol: "waveform",
                      target: self, action: #selector(newAudioTapped)),
            StartCard(title: "Instrument Track", detail: "Play a synth from a MIDI keyboard", symbol: "pianokeys",
                      target: self, action: #selector(newInstrumentTapped)),
        ]
        let choices = NSStackView(views: cards)
        choices.spacing = 12
        let start = section("Add your first track", choices)

        let left = NSStackView(views: [section("Project", basicsBox), start])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 22
        basicsBox.widthAnchor.constraint(equalTo: choices.widthAnchor).isActive = true

        // Recent projects (every DAW's start screen leads with these for returning users) and the other ways in.
        recentsStack.orientation = .vertical
        recentsStack.alignment = .leading
        recentsStack.spacing = 4
        func link(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: title, attributes: [.font: Theme.ui(12.5), .foregroundColor: Theme.accent])
            b.setAccessibilityLabel(title)
            return b
        }
        let ways = NSStackView(views: [link("Open Project…", #selector(openTapped)), link("Import Audio…", #selector(importTapped)),
                                       link("Bring in a Logic, Ableton or REAPER project…", #selector(migrateTapped))])
        ways.orientation = .vertical
        ways.alignment = .leading
        ways.spacing = 6
        let right = NSStackView(views: [section("Recent", recentsStack), ways])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 18
        right.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let columns = NSStackView(views: [left, right])
        columns.alignment = .top
        columns.spacing = 40
        let head = NSStackView(views: [title, sub])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 4
        let stack = NSStackView(views: [head, columns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 26
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
        ])
        entrance = [head, left, right]
    }
    required init?(coder: NSCoder) { fatalError() }

    private func field(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.ui(12)
        l.textColor = Theme.textDim
        if ["Output", "Input"].contains(s) { l.widthAnchor.constraint(equalToConstant: 48).isActive = true }
        return l
    }
    private func small(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = Theme.ui(10, .semibold); l.textColor = Theme.textFaint; return l
    }
    private func spacer(_ w: CGFloat) -> NSView { let v = NSView(); v.widthAnchor.constraint(equalToConstant: w).isActive = true; return v }
    private func divider() -> NSView {
        let v = NSBox(); v.boxType = .separator; return v
    }
    private func panel(_ content: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.backgroundColor = Theme.ink(0.04).cgColor
        box.layer?.borderColor = Theme.ink(0.08).cgColor
        box.layer?.borderWidth = 1
        if Theme.activeStyle == .atelier, let l = box.layer {
            l.cornerRadius = 0; l.backgroundColor = Theme.ink(0.025).cgColor
            SketchBorderLayer.attach(to: l, color: Theme.ink(0.55), width: 0.9, seed: 21, overshoot: 4)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor), content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            content.topAnchor.constraint(equalTo: box.topAnchor), content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }
    private func section(_ name: String, _ content: NSView) -> NSView {
        let l = NSTextField(labelWithString: name.uppercased())
        l.font = Theme.ui(10, .semibold)
        l.textColor = Theme.textFaint
        let s = NSStackView(views: [l, content])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 8
        return s
    }

    /// Fills in the project basics and recent projects (each time the page appears).
    func reload() {
        if let b = basics?() {
            if tempoField.currentEditor() == nil { tempoField.stringValue = String(format: "%g", b.bpm) }
            meterPopup.selectItem(withTitle: "\(b.meter.0)/\(b.meter.1)")
            outputLabel.stringValue = b.output
            inputLabel.stringValue = b.input
        }
        recentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = Self.showsRecents
            ? NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(6)
            : []
        if urls.isEmpty {
            let none = NSTextField(labelWithString: "Projects you save appear here.")
            none.font = Theme.ui(12)
            none.textColor = Theme.textFaint
            recentsStack.addArrangedSubview(none)
            return
        }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        for url in urls {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { fmt.localizedString(for: $0, relativeTo: Date()) } ?? ""
            let b = NSButton(title: "", target: self, action: #selector(recentTapped(_:)))
            b.isBordered = false
            b.alignment = .left
            let name = url.deletingPathExtension().lastPathComponent
            let s = NSMutableAttributedString(string: name, attributes: [.font: Theme.ui(12.5, .medium), .foregroundColor: Theme.text])
            if !date.isEmpty { s.append(NSAttributedString(string: "   " + date, attributes: [.font: Theme.ui(11), .foregroundColor: Theme.textFaint])) }
            b.attributedTitle = s
            b.lineBreakMode = .byTruncatingMiddle
            b.toolTip = url.path
            b.identifier = NSUserInterfaceItemIdentifier(url.path)
            b.setAccessibilityLabel("Open \(name)")
            recentsStack.addArrangedSubview(b)
        }
    }

    // MARK: Editing the basics

    func controlTextDidEndEditing(_ obj: Notification) { commitTempo() }
    private func commitTempo() {
        guard let bpm = Double(tempoField.stringValue.replacingOccurrences(of: ",", with: ".")) else { return reload() }
        // Leaving the field without a change is not an edit (it would add an empty "Tempo" undo step).
        if let current = basics?().bpm, abs(current - bpm) < 1e-9 { return }
        onTempo?(bpm)
        reload()
    }
    @objc private func meterChosen() {
        let parts = (meterPopup.titleOfSelectedItem ?? "4/4").split(separator: "/").compactMap { Int32($0) }
        if parts.count == 2 { onMeter?(parts[0], parts[1]) }
    }

    // MARK: Appearing

    override var isHidden: Bool { didSet { if oldValue && !isHidden { appear() } } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil && !isHidden { appear() } }
    /// The header and the two columns rise 10 pt and fade in one after another (45 ms apart).
    private func appear() {
        reload()
        guard !Motion.reduced else { return }
        layoutSubtreeIfNeeded()
        for (i, v) in entrance.enumerated() {
            v.wantsLayer = true
            guard let l = v.layer else { continue }
            let delay = CACurrentMediaTime() + 0.05 + Double(i) * 0.045
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -10
            rise.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            for a in [rise, fade] {
                a.duration = 0.32
                a.beginTime = delay
                a.fillMode = .backwards
                a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                l.add(a, forKey: "appear-\(a.keyPath!)")
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dashed drop zone.
        let r = bounds.insetBy(dx: 28, dy: 28)
        if Theme.look.arrangement == .glass { Prism.drawField(in: self, frosted: false); Prism.liquidPane(self, r, radius: 18) }
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        path.lineWidth = 1.5
        path.setLineDash([6, 5], count: 2, phase: 0)
        Theme.ink(0.08).setStroke()
        path.stroke()
    }

    // Let drags pass through to the window's drop view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }

    @objc private func recentTapped(_ sender: NSButton) { if let p = sender.identifier?.rawValue { onOpenRecent?(URL(fileURLWithPath: p)) } }
    @objc private func importTapped() { onImportAudio?() }
    @objc private func openTapped() { onOpen?() }
    @objc private func migrateTapped() { onMigrate?() }
    @objc private func audioTapped() { onAudioSettings?() }
    @objc private func newInstrumentTapped() { onNewInstrument?() }
    @objc private func newAudioTapped() { onNewAudioTrack?() }
}
