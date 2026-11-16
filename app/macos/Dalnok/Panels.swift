// Transport bar and track header column.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class TransportBar: NSView {
    let playButton = NSButton()
    let importButton = NSButton()
    let timeLabel = NSTextField(labelWithString: "0:00.000")
    let statusLabel = NSTextField(labelWithString: "")
    let masterMeter = MeterView()
    var onPlayPause: (() -> Void)?
    var onRewind: (() -> Void)?
    var onImport: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor

        let rewind = Self.iconButton("backward.end.fill", "Go to Start (Return)")
        rewind.target = self
        rewind.action = #selector(rewindTapped)
        configure(playButton, symbol: "play.fill", tip: "Play / Pause (Space)")
        playButton.action = #selector(playTapped)
        configure(importButton, symbol: "square.and.arrow.down", tip: "Import Audio… (⌘I)")
        importButton.action = #selector(importTapped)

        timeLabel.font = Theme.mono(20, .medium)
        timeLabel.textColor = Theme.accent
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Theme.textDim
        statusLabel.lineBreakMode = .byTruncatingTail

        let lcd = NSView()
        lcd.wantsLayer = true
        lcd.layer?.backgroundColor = Theme.window.cgColor
        lcd.layer?.cornerRadius = 6
        lcd.layer?.borderColor = Theme.separator.cgColor
        lcd.layer?.borderWidth = 1
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        lcd.addSubview(timeLabel)

        let left = NSStackView(views: [rewind, playButton])
        left.spacing = 6
        masterMeter.toolTip = "Master output peak (click to reset clip)"
        masterMeter.setAccessibilityLabel("Master level meter")
        let stack = NSStackView(views: [left, lcd, statusLabel, NSView(), masterMeter, importButton])
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            lcd.widthAnchor.constraint(equalToConstant: 132),
            masterMeter.widthAnchor.constraint(equalToConstant: 160),
            masterMeter.heightAnchor.constraint(equalToConstant: 9),
            lcd.heightAnchor.constraint(equalToConstant: 32),
            timeLabel.centerXAnchor.constraint(equalTo: lcd.centerXAnchor),
            timeLabel.centerYAnchor.constraint(equalTo: lcd.centerYAnchor),
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func iconButton(_ symbol: String, _ tip: String) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .texturedRounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.contentTintColor = Theme.text
        b.widthAnchor.constraint(equalToConstant: 38).isActive = true
        return b
    }

    private func configure(_ b: NSButton, symbol: String, tip: String) {
        b.bezelStyle = .texturedRounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.contentTintColor = Theme.text
        b.target = self
        b.widthAnchor.constraint(equalToConstant: 38).isActive = true
    }

    func setPlaying(_ playing: Bool) {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        playButton.contentTintColor = playing ? Theme.accent : Theme.text
    }

    @objc private func playTapped() { onPlayPause?() }
    @objc private func rewindTapped() { onRewind?() }
    @objc private func importTapped() { onImport?() }
}

/// Slider that brackets each mouse interaction in an undo group, so one drag = one undo step.
@MainActor
final class GroupedSlider: NSSlider {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private(set) var tracking = false
    override func mouseDown(with event: NSEvent) {
        tracking = true
        onBegin?()
        super.mouseDown(with: event) // runs the tracking loop until mouse-up
        onEnd?()
        tracking = false
    }
}

@MainActor
final class TrackHeaderRow: NSView, NSTextFieldDelegate {
    let trackId: DalnokTrackId
    let session: Session
    weak var column: TrackHeaderColumn?
    var isSelected = false { didSet { needsDisplay = true } }
    private let swatch = NSView()
    let nameLabel = NSTextField(labelWithString: "")
    private let gainLabel = NSTextField(labelWithString: "0.0 dB")
    private let mute = NSButton(title: "M", target: nil, action: nil)
    private let solo = NSButton(title: "S", target: nil, action: nil)
    private let gain = GroupedSlider(value: 0, minValue: -60, maxValue: 6, target: nil, action: nil)
    private let pan = GroupedSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    let meter = MeterView()
    private var dragStartY: CGFloat?

    init(track: TrackView, session: Session) {
        self.trackId = track.id
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 1.5
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = Theme.text
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.delegate = self
        nameLabel.toolTip = "Double-click to rename"

        for (b, title, tip) in [(mute, "M", "Mute (⌃M)"), (solo, "S", "Solo (⌃S)")] {
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            b.font = .systemFont(ofSize: 10, weight: .bold)
            b.title = title
            b.target = self
            b.toolTip = tip
        }
        mute.action = #selector(toggleMute)
        solo.action = #selector(toggleSolo)

        for (slider, name) in [(gain, "Volume"), (pan, "Pan")] {
            slider.controlSize = .small
            slider.target = self
            slider.toolTip = name
            slider.onBegin = { [weak self] in self?.session.engine.beginGroup(name) }
            slider.onEnd = { [weak self] in self?.session.engine.endGroup() }
        }
        gain.action = #selector(gainChanged(_:))
        pan.action = #selector(panChanged(_:))

        gainLabel.font = Theme.mono(10)
        gainLabel.textColor = Theme.textDim
        gainLabel.alignment = .right
        let panLabel = NSTextField(labelWithString: "Pan")
        panLabel.font = .systemFont(ofSize: 10)
        panLabel.textColor = Theme.textDim

        meter.toolTip = "Post-fader peak (click to reset clip)"
        meter.setAccessibilityLabel("Level meter \(track.name)")
        for v in [swatch, nameLabel, mute, solo, gain, pan, gainLabel, panLabel, meter] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor),
            swatch.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            swatch.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            swatch.widthAnchor.constraint(equalToConstant: 3),
            nameLabel.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: mute.leadingAnchor, constant: -6),
            solo.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            solo.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            solo.widthAnchor.constraint(equalToConstant: 26),
            mute.trailingAnchor.constraint(equalTo: solo.leadingAnchor, constant: -4),
            mute.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            mute.widthAnchor.constraint(equalToConstant: 26),
            gain.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            gain.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 12),
            gain.trailingAnchor.constraint(equalTo: gainLabel.leadingAnchor, constant: -6),
            gainLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            gainLabel.centerYAnchor.constraint(equalTo: gain.centerYAnchor),
            gainLabel.widthAnchor.constraint(equalToConstant: 52),
            pan.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pan.topAnchor.constraint(equalTo: gain.bottomAnchor, constant: 8),
            pan.trailingAnchor.constraint(equalTo: gain.trailingAnchor),
            panLabel.leadingAnchor.constraint(equalTo: gainLabel.leadingAnchor),
            panLabel.centerYAnchor.constraint(equalTo: pan.centerYAnchor),
            meter.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            meter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            meter.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            meter.heightAnchor.constraint(equalToConstant: 5),
        ])
        update(track)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Applies model values (after edits, undo, or scripts) without fighting an active drag.
    func update(_ t: TrackView) {
        swatch.layer?.backgroundColor = t.color.cgColor
        if !nameLabel.isEditable { nameLabel.stringValue = t.name }
        mute.state = t.muted ? .on : .off
        mute.contentTintColor = t.muted ? Theme.accent : nil
        solo.state = t.solo ? .on : .off
        solo.contentTintColor = t.solo ? Theme.hex(0xE8C35A) : nil
        mute.setAccessibilityLabel("Mute \(t.name)")
        solo.setAccessibilityLabel("Solo \(t.name)")
        gain.setAccessibilityLabel("Volume \(t.name)")
        pan.setAccessibilityLabel("Pan \(t.name)")
        if !gain.tracking { gain.doubleValue = t.gainDb.isFinite ? Double(t.gainDb) : -60 }
        if !pan.tracking { pan.doubleValue = Double(t.pan) }
        gainLabel.stringValue = t.gainDb.isFinite && t.gainDb > -59.9 ? String(format: "%+.1f dB", t.gainDb) : "-∞ dB"
    }

    override func draw(_ dirtyRect: NSRect) {
        (isSelected ? Theme.hex(0x2B2F36) : Theme.panelRaised).setFill()
        bounds.fill()
        if isSelected {
            Theme.accent.withAlphaComponent(0.5).setFill()
            NSRect(x: bounds.width - 2, y: 0, width: 2, height: bounds.height).fill()
        }
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: Rename (double-click the name)

    func beginRename() {
        nameLabel.isEditable = true
        nameLabel.isBezeled = true
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = Theme.window
        window?.makeFirstResponder(nameLabel)
        nameLabel.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard nameLabel.isEditable else { return }
        nameLabel.isEditable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        let name = nameLabel.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { session.renameTrack(trackId, name) } else { session.refresh() }
        if let t = session.track(trackId) { nameLabel.stringValue = t.name }
    }

    // MARK: Mouse: select, double-click rename, drag to reorder

    override func mouseDown(with event: NSEvent) {
        column?.select(trackId)
        if event.clickCount == 2, nameLabel.frame.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) {
            beginRename()
            return
        }
        dragStartY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartY, abs(event.locationInWindow.y - start) > 4 else { return }
        column?.dragUpdate(row: self, windowPoint: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStartY != nil { column?.dragEnd(row: self) }
        dragStartY = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        column?.select(trackId)
        return column?.contextMenu
    }

    @objc private func gainChanged(_ s: NSSlider) {
        var db = Float(s.doubleValue)
        if abs(db) < 0.4 { db = 0; s.doubleValue = 0 } // detent at unity
        session.setGain(trackId, db: db <= -59.9 ? -.infinity : db)
    }

    @objc private func panChanged(_ s: NSSlider) {
        var p = Float(s.doubleValue)
        if abs(p) < 0.04 { p = 0; s.doubleValue = 0 }
        session.setPan(trackId, p)
    }

    @objc private func toggleMute() { session.setMute(trackId, mute.state == .on) }
    @objc private func toggleSolo() { session.setSolo(trackId, solo.state == .on) }
}

/// Column of track headers; vertically synced with the timeline.
@MainActor
final class TrackHeaderColumn: NSView {
    let session: Session
    private(set) var rows: [TrackHeaderRow] = []
    private let rowClip = FlippedView()
    private let insertLine = CALayer()
    private var dropIndex: Int?
    var scrollY: CGFloat = 0 { didSet { needsLayout = true } }
    var selectedTrack: DalnokTrackId? { didSet { rows.forEach { $0.isSelected = $0.trackId == selectedTrack }; onSelect?(selectedTrack) } }
    var onSelect: ((DalnokTrackId?) -> Void)?
    var contextMenu: NSMenu?

    func select(_ id: DalnokTrackId) { selectedTrack = id }

    func row(_ id: DalnokTrackId) -> TrackHeaderRow? { rows.first { $0.trackId == id } }

    /// Shows an insertion line between rows while dragging a header.
    func dragUpdate(row: TrackHeaderRow, windowPoint: CGPoint) {
        let y = rowClip.convert(windowPoint, from: nil).y + scrollY
        let slot = max(0, min(rows.count, Int((y / Theme.trackHeight).rounded())))
        dropIndex = slot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insertLine.isHidden = false
        insertLine.frame = CGRect(x: 0, y: CGFloat(slot) * Theme.trackHeight - scrollY - 1, width: rowClip.bounds.width, height: 2)
        CATransaction.commit()
    }

    func dragEnd(row: TrackHeaderRow) {
        insertLine.isHidden = true
        guard let slot = dropIndex, let from = rows.firstIndex(where: { $0 === row }) else { return }
        dropIndex = nil
        let to = slot > from ? slot - 1 : slot
        if to != from { session.moveTrack(row.trackId, to: to) }
    }

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor
        rowClip.wantsLayer = true
        rowClip.layer?.masksToBounds = true
        addSubview(rowClip)
        insertLine.backgroundColor = Theme.accent.cgColor
        insertLine.isHidden = true
        insertLine.zPosition = 5
        rowClip.layer?.addSublayer(insertLine)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Reuses rows by track id so in-progress slider drags survive model updates.
    func sync() {
        let tracks = session.tracks
        if rows.map(\.trackId) != tracks.map(\.id) {
            var byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.trackId, $0) })
            rows = tracks.map { t in byId.removeValue(forKey: t.id) ?? TrackHeaderRow(track: t, session: session) }
            rows.forEach { $0.column = self; $0.isSelected = $0.trackId == selectedTrack }
            if let sel = selectedTrack, !tracks.contains(where: { $0.id == sel }) { selectedTrack = nil }
            byId.values.forEach { $0.removeFromSuperview() }
            rows.forEach { if $0.superview == nil { rowClip.addSubview($0) } }
            needsLayout = true
        }
        for (row, t) in zip(rows, tracks) { row.update(t) }
    }

    override func layout() {
        super.layout()
        rowClip.frame = CGRect(x: 0, y: Theme.rulerHeight, width: bounds.width - 1, height: max(0, bounds.height - Theme.rulerHeight))
        for (i, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(i) * Theme.trackHeight - scrollY, width: rowClip.bounds.width,
                               height: Theme.trackHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.panel.setFill()
        bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                     .foregroundColor: Theme.textDim, .kern: 1.2]
        ("TRACKS" as NSString).draw(at: CGPoint(x: 13, y: 9), withAttributes: attrs)
        Theme.separator.setFill()
        NSRect(x: 0, y: Theme.rulerHeight - 1, width: bounds.width, height: 1).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
