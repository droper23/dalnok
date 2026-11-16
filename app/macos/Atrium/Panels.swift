// Transport bar and track header column.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class TransportBar: NSView {
    let playButton = NSButton()
    let importButton = NSButton()
    let timeLabel = NSTextField(labelWithString: "0:00.000")
    let statusLabel = NSTextField(labelWithString: "")
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
        let stack = NSStackView(views: [left, lcd, statusLabel, NSView(), importButton])
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            lcd.widthAnchor.constraint(equalToConstant: 132),
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

@MainActor
final class TrackHeaderRow: NSView {
    let track: TrackModel
    let session: Session
    private let gainLabel = NSTextField(labelWithString: "0.0 dB")
    private let mute = NSButton(title: "M", target: nil, action: nil)

    init(track: TrackModel, session: Session) {
        self.track = track
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true

        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = track.color.cgColor
        swatch.layer?.cornerRadius = 1.5

        let name = NSTextField(labelWithString: track.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingTail

        mute.setButtonType(.pushOnPushOff)
        mute.bezelStyle = .texturedRounded
        mute.font = .systemFont(ofSize: 10, weight: .bold)
        mute.target = self
        mute.action = #selector(toggleMute)
        mute.toolTip = "Mute"
        mute.setAccessibilityLabel("Mute \(track.name)")

        let gain = NSSlider(value: 0, minValue: -60, maxValue: 6, target: self, action: #selector(gainChanged(_:)))
        gain.controlSize = .small
        gain.toolTip = "Volume (double-click label to reset)"
        gain.setAccessibilityLabel("Volume \(track.name)")
        let pan = NSSlider(value: 0, minValue: -1, maxValue: 1, target: self, action: #selector(panChanged(_:)))
        pan.controlSize = .small
        pan.toolTip = "Pan"
        pan.setAccessibilityLabel("Pan \(track.name)")

        gainLabel.font = Theme.mono(10)
        gainLabel.textColor = Theme.textDim
        gainLabel.alignment = .right
        let panLabel = NSTextField(labelWithString: "Pan")
        panLabel.font = .systemFont(ofSize: 10)
        panLabel.textColor = Theme.textDim

        for v in [swatch, name, mute, gain, pan, gainLabel, panLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor),
            swatch.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            swatch.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            swatch.widthAnchor.constraint(equalToConstant: 3),
            name.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: mute.leadingAnchor, constant: -6),
            mute.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            mute.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            mute.widthAnchor.constraint(equalToConstant: 26),
            gain.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            gain.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 12),
            gain.trailingAnchor.constraint(equalTo: gainLabel.leadingAnchor, constant: -6),
            gainLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            gainLabel.centerYAnchor.constraint(equalTo: gain.centerYAnchor),
            gainLabel.widthAnchor.constraint(equalToConstant: 52),
            pan.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            pan.topAnchor.constraint(equalTo: gain.bottomAnchor, constant: 8),
            pan.trailingAnchor.constraint(equalTo: gain.trailingAnchor),
            panLabel.leadingAnchor.constraint(equalTo: gainLabel.leadingAnchor),
            panLabel.centerYAnchor.constraint(equalTo: pan.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.panelRaised.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func gainChanged(_ s: NSSlider) {
        var db = Float(s.doubleValue)
        if abs(db) < 0.4 { db = 0; s.doubleValue = 0 } // detent at unity
        session.setGain(track, db: db <= -59.9 ? -.infinity : db)
        gainLabel.stringValue = db <= -59.9 ? "-∞ dB" : String(format: "%+.1f dB", db)
    }

    @objc private func panChanged(_ s: NSSlider) {
        var p = Float(s.doubleValue)
        if abs(p) < 0.04 { p = 0; s.doubleValue = 0 }
        session.setPan(track, p)
    }

    @objc private func toggleMute() {
        session.setMute(track, mute.state == .on)
        mute.contentTintColor = mute.state == .on ? Theme.accent : nil
        window?.contentView?.needsDisplay = true
    }
}

/// Column of track headers; vertically synced with the timeline.
@MainActor
final class TrackHeaderColumn: NSView {
    let session: Session
    private var rows: [TrackHeaderRow] = []
    var scrollY: CGFloat = 0 { didSet { needsLayout = true } }

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func reload() {
        rows.forEach { $0.removeFromSuperview() }
        rows = session.tracks.map { TrackHeaderRow(track: $0, session: session) }
        rows.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (i, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: Theme.rulerHeight + CGFloat(i) * Theme.trackHeight - scrollY,
                               width: bounds.width, height: Theme.trackHeight)
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
