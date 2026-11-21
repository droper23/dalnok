// What an empty project shows: the two ways to add a track, the handful of keys that get someone around a project,
// and the other ways in. The whole page is still a drop zone for audio files and projects.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A large, clickable choice. Hovering lifts it (border, shadow, a 2 pt rise); pressing sinks it.
@MainActor
final class StartCard: NSButton {
    private var hovering = false { didSet { if hovering != oldValue { restyle(animated: true) } } }

    init(title t: String, detail d: String, keys: String, symbol: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        setAccessibilityLabel(t)
        setAccessibilityHelp(d)
        toolTip = "\(t) (\(keys))"

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
        let count = NSTextField(labelWithString: keys)
        count.font = Theme.mono(10, .medium)
        count.textColor = Theme.textFaint
        for v in [name, detail, count, icon] as [NSView] { v.setAccessibilityElement(false) }
        let text = NSStackView(views: [name, detail, count])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setCustomSpacing(6, after: detail)
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
            widthAnchor.constraint(equalToConstant: 280), heightAnchor.constraint(equalToConstant: 92),
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
            self.layer?.backgroundColor = (self.hovering ? Theme.hex(0xFFFFFF, 0.075) : Theme.hex(0xFFFFFF, 0.04)).cgColor
            self.layer?.borderColor = (self.hovering ? Theme.accent.withAlphaComponent(0.55) : Theme.hex(0xFFFFFF, 0.08)).cgColor
            self.layer?.shadowOpacity = self.hovering ? 0.35 : 0
            self.layer?.shadowRadius = self.hovering ? 12 : 4
            self.layer?.sublayerTransform = CATransform3DMakeTranslation(0, self.hovering ? 2 : 0, 0)
        }
        if animated { Motion.layers(Motion.standard, body) } else { CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit() }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
}

/// Five breathing bars: the page's emblem. Still under Reduce Motion, and stops while hidden.
@MainActor
final class BreathingBars: NSView {
    private var bars: [CALayer] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
        for (i, h) in [0.45, 0.8, 1.0, 0.7, 0.4].enumerated() {
            let b = CALayer()
            b.backgroundColor = Theme.accent.cgColor
            b.cornerRadius = 2
            b.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            b.setValue(h, forKey: "rest")
            b.setValue(i, forKey: "index")
            layer?.addSublayer(b)
            bars.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 34) }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, b) in bars.enumerated() {
            let h = bounds.height * CGFloat(b.value(forKey: "rest") as? Double ?? 1)
            b.bounds = CGRect(x: 0, y: 0, width: 4, height: h)
            b.position = CGPoint(x: 4 + CGFloat(i) * 9, y: bounds.midY)
        }
        CATransaction.commit()
    }
    func breathe(_ on: Bool) {
        for (i, b) in bars.enumerated() {
            b.removeAnimation(forKey: "breathe")
            guard on, !Motion.reduced else { continue }
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = 1
            a.toValue = [0.55, 0.7, 0.62, 0.75, 0.5][i]
            a.duration = 1.1 + Double(i % 3) * 0.17
            a.autoreverses = true
            a.repeatCount = .infinity
            a.beginTime = CACurrentMediaTime() + Double(i) * 0.12
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            b.add(a, forKey: "breathe")
        }
    }
}

@MainActor
final class EmptyStateView: NSView {
    var onImportAudio: (() -> Void)?
    var onOpen: (() -> Void)?
    var onMigrate: (() -> Void)?
    var onNewInstrument: (() -> Void)?
    var onNewAudioTrack: (() -> Void)?

    private let emblem = BreathingBars()
    private(set) var cards: [StartCard] = []
    /// Views that rise into place, in order, when the page appears.
    private var entrance: [NSView] = []

    /// The keys that get someone around a project, in the order they need them.
    static let essentials: [(keys: String, what: String)] = [
        ("Space", "Play and stop"),
        ("R", "Record on the tracks with R lit"),
        ("⌘K", "Find any command by name"),
        ("X", "Show the mixer"),
        ("⌘Z", "Undo anything"),
        ("Hover", "The line under the project name explains it"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let title = NSTextField(labelWithString: "Your project is empty")
        title.font = Theme.ui(22, .semibold)
        title.textColor = Theme.text
        let sub = NSTextField(labelWithString: "Add a track to start, or drop audio files anywhere in this window.")
        sub.font = Theme.ui(12.5)
        sub.textColor = Theme.textDim
        let head = NSStackView(views: [emblem, title, sub])
        head.orientation = .vertical
        head.spacing = 6
        head.setCustomSpacing(12, after: emblem)

        cards = [
            StartCard(title: "New Audio Track", detail: "Record a microphone or guitar", keys: "⌥⌘N", symbol: "waveform",
                      target: self, action: #selector(newAudioTapped)),
            StartCard(title: "New Instrument Track", detail: "Play a synth from a MIDI keyboard", keys: "⌥⇧⌘N", symbol: "pianokeys",
                      target: self, action: #selector(newInstrumentTapped)),
        ]
        let choices = NSStackView(views: cards)
        choices.spacing = 12

        // Getting around: a key and what it does, two columns.
        let keyFont = Theme.mono(11, .semibold)
        let rows: [[NSView]] = Self.essentials.map { k, w in
            let key = NSTextField(labelWithString: k)
            key.font = keyFont
            key.textColor = Theme.text
            key.alignment = .right
            let what = NSTextField(labelWithString: w)
            what.font = Theme.ui(12)
            what.textColor = Theme.textDim
            return [key, what]
        }
        let half = (rows.count + 1) / 2
        let grid = NSGridView(views: (0..<half).map { i in rows[i] + (i + half < rows.count ? rows[i + half] : [NSGridCell.emptyContentView, NSGridCell.emptyContentView]) })
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).width = 56
        grid.column(at: 2).width = 64
        grid.column(at: 1).trailingPadding = 22
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing
        let around = section("Getting around", grid)

        func link(_ title: String, _ keys: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.isBordered = false
            b.contentTintColor = Theme.accent
            b.attributedTitle = NSAttributedString(string: title, attributes: [.font: Theme.ui(12), .foregroundColor: Theme.accent])
            b.toolTip = keys.isEmpty ? nil : "\(title) (\(keys))"
            return b
        }
        let dot = { () -> NSTextField in let d = NSTextField(labelWithString: "·"); d.textColor = Theme.textFaint; return d }
        let links = NSStackView(views: [link("Open Project…", "⌘O", #selector(openTapped)), dot(),
                                        link("Import Audio…", "⌘I", #selector(importTapped)), dot(),
                                        link("Bring in a Logic, Ableton or REAPER project…", "", #selector(migrateTapped))])
        links.spacing = 8

        let stack = NSStackView(views: [head, choices, around, links])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
        ])
        entrance = [head, choices, around, links]
    }
    required init?(coder: NSCoder) { fatalError() }

    private func section(_ name: String, _ content: NSView) -> NSView {
        let l = NSTextField(labelWithString: name.uppercased())
        l.font = Theme.ui(10, .semibold)
        l.textColor = Theme.textFaint
        let s = NSStackView(views: [l, content])
        s.orientation = .vertical
        s.alignment = .centerX
        s.spacing = 10
        return s
    }

    // MARK: Appearing

    override var isHidden: Bool { didSet { if oldValue && !isHidden { appear() } else if isHidden { emblem.breathe(false) } } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil && !isHidden { appear() } }
    /// The sections rise 10 pt and fade in one after another (45 ms apart).
    private func appear() {
        emblem.breathe(true)
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
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        path.lineWidth = 1.5
        path.setLineDash([6, 5], count: 2, phase: 0)
        Theme.hex(0xFFFFFF, 0.08).setStroke()
        path.stroke()
    }

    // Let drags pass through to the window's drop view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }

    @objc private func importTapped() { onImportAudio?() }
    @objc private func openTapped() { onOpen?() }
    @objc private func migrateTapped() { onMigrate?() }
    @objc private func newInstrumentTapped() { onNewInstrument?() }
    @objc private func newAudioTapped() { onNewAudioTrack?() }
}
