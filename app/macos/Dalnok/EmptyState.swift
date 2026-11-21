// The start page an empty project shows: templates for what people come to make (Logic's project chooser, Bitwig's
// dashboard and Studio One's start page all lead with these), recent projects, the other ways in, and three tips that
// unlock the rest of the app. The whole page is still a drop zone for audio files and projects.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A starting point: named tracks, ready to record or play. Templates only add tracks (one undo step), so nothing
/// about them is hidden: delete a track and it's gone, exactly as if it had been added by hand.
struct ProjectTemplate {
    struct Track { let name: String; let instrument: Bool }
    let id: String, title: String, detail: String, symbol: String
    let tracks: [Track]

    private static func a(_ n: String) -> Track { Track(name: n, instrument: false) }
    private static func i(_ n: String) -> Track { Track(name: n, instrument: true) }
    static let all: [ProjectTemplate] = [
        ProjectTemplate(id: "record", title: "Record Audio", detail: "One track for a mic or guitar", symbol: "mic.fill",
                        tracks: [a("Audio 1")]),
        ProjectTemplate(id: "instrument", title: "Play an Instrument", detail: "A synth for a MIDI keyboard", symbol: "pianokeys",
                        tracks: [i("Keys")]),
        ProjectTemplate(id: "beat", title: "Make a Beat", detail: "Drums, bass, chords, melody", symbol: "square.grid.3x3.fill",
                        tracks: [i("Drums"), i("Bass"), i("Chords"), i("Melody")]),
        ProjectTemplate(id: "band", title: "Record a Band", detail: "Drums, bass, guitar, keys, vocal", symbol: "music.mic",
                        tracks: [a("Drums"), a("Bass"), a("Guitar"), i("Keys"), a("Vocal")]),
        ProjectTemplate(id: "songwriter", title: "Write a Song", detail: "Vocal and guitar, plus piano", symbol: "music.quarternote.3",
                        tracks: [a("Vocal"), a("Guitar"), i("Piano")]),
        ProjectTemplate(id: "voice", title: "Podcast or Voice-over", detail: "Two voice tracks", symbol: "waveform.and.mic",
                        tracks: [a("Host"), a("Guest")]),
    ]
}

/// A large, clickable template card. Hovering lifts it (border, shadow, a 2 pt rise); pressing sinks it.
@MainActor
final class TemplateCard: NSButton {
    let template: ProjectTemplate
    private var hovering = false { didSet { if hovering != oldValue { restyle(animated: true) } } }

    init(_ t: ProjectTemplate, target: AnyObject, action: Selector) {
        template = t
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
        setAccessibilityLabel(t.title)
        setAccessibilityHelp("\(t.detail). Creates \(t.tracks.count) track\(t.tracks.count == 1 ? "" : "s").")
        toolTip = "Tracks: " + t.tracks.map { $0.name + ($0.instrument ? " (instrument)" : "") }.joined(separator: ", ")

        let icon = NSImageView(image: NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))!)
        icon.contentTintColor = Theme.accent
        icon.setAccessibilityElement(false)
        let name = NSTextField(labelWithString: t.title)
        name.font = Theme.ui(14, .semibold)
        name.textColor = Theme.text
        let detail = NSTextField(labelWithString: t.detail)
        detail.font = Theme.ui(11.5)
        detail.textColor = Theme.textDim
        detail.lineBreakMode = .byTruncatingTail
        let count = NSTextField(labelWithString: "\(t.tracks.count) track\(t.tracks.count == 1 ? "" : "s")")
        count.font = Theme.ui(10, .medium)
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
            widthAnchor.constraint(equalToConstant: 256), heightAnchor.constraint(equalToConstant: 92),
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
    var onTemplate: ((ProjectTemplate) -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    /// Automated runs (snapshots, screenshots, self-test, tours) never show recent projects: their names are the
    /// owner's and must not land in a picture.
    static let showsRecents: Bool = {
        let a = CommandLine.arguments
        return !["--snapshot", "--screenshots", "--selftest", "--uiwalk", "--tour"].contains(where: a.contains)
    }()

    private let emblem = BreathingBars()
    private(set) var cards: [TemplateCard] = []
    private let recentsStack = NSStackView()
    /// Views that rise into place, in order, when the page appears.
    private var entrance: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let title = NSTextField(labelWithString: "What do you want to make?")
        title.font = Theme.ui(22, .semibold)
        title.textColor = Theme.text
        let sub = NSTextField(labelWithString: "Pick a starting point, or drop audio files anywhere in this window.")
        sub.font = Theme.ui(12.5)
        sub.textColor = Theme.textDim
        let head = NSStackView(views: [emblem, title, sub])
        head.orientation = .vertical
        head.spacing = 6
        head.setCustomSpacing(12, after: emblem)

        cards = ProjectTemplate.all.map { TemplateCard($0, target: self, action: #selector(templateTapped(_:))) }
        let grid = NSGridView(views: stride(from: 0, to: cards.count, by: 3).map { Array(cards[$0..<min($0 + 3, cards.count)]) })
        grid.rowSpacing = 12
        grid.columnSpacing = 12

        // Recent projects (left) and the other ways in (right).
        recentsStack.orientation = .vertical
        recentsStack.alignment = .leading
        recentsStack.spacing = 2
        let recentBox = section("Recent", recentsStack)
        func link(_ title: String, _ symbol: String, _ keys: String, _ sel: Selector) -> NSButton {
            // Symbols differ in width; centre each in the same 18 pt box so the labels line up.
            let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))!
            let boxed = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { r in
                glyph.draw(in: NSRect(x: (r.width - glyph.size.width) / 2, y: (r.height - glyph.size.height) / 2,
                                      width: glyph.size.width, height: glyph.size.height))
                return true
            }
            boxed.isTemplate = true
            let b = NSButton(title: "  " + title, image: boxed, target: self, action: sel)
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.contentTintColor = Theme.textDim
            b.font = Theme.ui(12.5)
            b.toolTip = keys.isEmpty ? nil : "\(title) (\(keys))"
            b.setAccessibilityLabel(title)
            return b
        }
        let ways = NSStackView(views: [
            link("Open Project…", "folder", "⌘O", #selector(openTapped)),
            link("Import Audio…", "square.and.arrow.down", "⌘I", #selector(importTapped)),
            link("Bring In a Logic, Ableton or REAPER Project…", "arrow.triangle.branch", "", #selector(migrateTapped)),
            link("Empty Audio Track", "waveform", "⌥⌘N", #selector(newAudioTapped)),
            link("Empty Instrument Track", "pianokeys", "⌥⇧⌘N", #selector(newInstrumentTapped)),
        ])
        ways.orientation = .vertical
        ways.alignment = .leading
        ways.spacing = 6
        let waysBox = section("More ways to start", ways)
        let lower = NSStackView(views: [recentBox, waysBox])
        lower.alignment = .top
        lower.distribution = .fillEqually
        lower.spacing = 24

        let tips = NSTextField(labelWithAttributedString: Self.tips())
        tips.setAccessibilityLabel("Tips: Command K finds any command. X shows the mixer. Space plays and stops.")

        let stack = NSStackView(views: [head, grid, lower, tips])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 26
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            lower.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])
        entrance = [head, grid, lower, tips]
        reloadRecents()
    }
    required init?(coder: NSCoder) { fatalError() }

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

    private static func tips() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let key: [NSAttributedString.Key: Any] = [.font: Theme.mono(11, .semibold), .foregroundColor: Theme.text]
        let text: [NSAttributedString.Key: Any] = [.font: Theme.ui(11.5), .foregroundColor: Theme.textDim]
        for (i, (k, t)) in [("⌘K", "finds any command"), ("X", "shows the mixer"), ("Space", "plays and stops")].enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "     ·     ", attributes: text)) }
            out.append(NSAttributedString(string: k, attributes: key))
            out.append(NSAttributedString(string: " " + t, attributes: text))
        }
        return out
    }

    /// Recent projects that still exist, newest first (at most five).
    func reloadRecents() {
        recentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = Self.showsRecents
            ? NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(5)
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
            let s = NSMutableAttributedString(string: url.deletingPathExtension().lastPathComponent,
                                              attributes: [.font: Theme.ui(12.5, .medium), .foregroundColor: Theme.text])
            if !date.isEmpty { s.append(NSAttributedString(string: "   " + date, attributes: [.font: Theme.ui(11), .foregroundColor: Theme.textFaint])) }
            b.attributedTitle = s
            b.toolTip = url.path
            b.identifier = NSUserInterfaceItemIdentifier(url.path)
            b.setAccessibilityLabel("Open \(url.deletingPathExtension().lastPathComponent)")
            recentsStack.addArrangedSubview(b)
        }
    }

    // MARK: Appearing

    override var isHidden: Bool { didSet { if oldValue && !isHidden { appear() } else if isHidden { emblem.breathe(false) } } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil && !isHidden { appear() } }
    /// The sections rise 10 pt and fade in one after another (40 ms apart), the way Final Cut and Bitwig open panels.
    private func appear() {
        reloadRecents()
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

    @objc private func templateTapped(_ sender: TemplateCard) { onTemplate?(sender.template) }
    @objc private func recentTapped(_ sender: NSButton) { if let p = sender.identifier?.rawValue { onOpenRecent?(URL(fileURLWithPath: p)) } }
    @objc private func importTapped() { onImportAudio?() }
    @objc private func openTapped() { onOpen?() }
    @objc private func migrateTapped() { onMigrate?() }
    @objc private func newInstrumentTapped() { onNewInstrument?() }
    @objc private func newAudioTapped() { onNewAudioTrack?() }
}
