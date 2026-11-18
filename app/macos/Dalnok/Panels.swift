// Control bar (in the title bar) and track headers.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

// MARK: - Control bar

/// Editable only on purpose (click or Transport ▸ Edit Tempo). As an ordinary text field it became the
/// window's first responder at launch, which made Space, R and Delete count as typing.
final class TempoField: NSTextField {
    private var armed = false
    override var acceptsFirstResponder: Bool { armed }
    func beginEditing() {
        armed = true
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
    override func mouseDown(with event: NSEvent) {
        if !armed { beginEditing() } else { super.mouseDown(with: event) }
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        armed = false
    }
}

@MainActor
final class TransportBar: NSView {
    let titleLabel = NSTextField(labelWithString: "Untitled")
    /// Secondary line under the title: audio status, or a transient message.
    let statusLabel = NSTextField(labelWithString: "")
    let timeLabel = NSTextField(labelWithString: "0:00.000")
    let lcdWell = NSView()
    /// Warm Analog: unlit display segments behind the digits, as on a vacuum-fluorescent display.
    let ghost = NSTextField(labelWithString: "")
    let masterMeter = MeterView()
    let reels = TapeReels() // Warm Analog only
    /// Warm Analog: the tape transport (reels, keys, lamps) in place of the round transport buttons.
    private(set) lazy var tapeStrip = TapeStrip(reels: reels)
    let playButton = IconButton("play.fill", help: "Play / Pause (Space)")
    let recordButton = IconButton("circle.fill", help: "Record (R)")
    let metronomeButton = IconButton("metronome.fill", help: "Metronome (K)")
    var onMetronome: (() -> Void)?
    let cycleButton = IconButton("repeat", help: "Cycle (C): loop playback between the yellow markers in the ruler")
    var onCycle: (() -> Void)?
    private let rewind = IconButton("backward.end.fill", help: "Go to Start (Return)")
    private let paletteButton = IconButton("magnifyingglass", help: "Command Palette (⌘K)")
    private let importButton = IconButton("plus.rectangle.on.rectangle", help: "Import Audio… (⌘I)")
    var onPlayPause: (() -> Void)?
    var onRecord: (() -> Void)?
    /// Project tempo (type and press Return) and meter.
    let tempoField = TempoField(string: "120")
    let meterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var onRewind: (() -> Void)?
    var onImport: (() -> Void)?
    var onPalette: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor

        titleLabel.font = Theme.ui(13, .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = Theme.ui(11)
        statusLabel.textColor = Theme.textDim
        statusLabel.lineBreakMode = .byTruncatingTail
        let titles = NSStackView(views: [titleLabel, statusLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1

        // Transport cluster: buttons + position display, centered.
        timeLabel.font = Theme.mono(20, .medium)
        timeLabel.textColor = Theme.accent
        timeLabel.alignment = .center
        let lcd = lcdWell
        lcd.wantsLayer = true
        lcd.layer?.backgroundColor = Theme.lcd.cgColor
        lcd.layer?.cornerRadius = 6
        lcd.layer?.borderWidth = 1
        lcd.layer?.borderColor = Theme.hairline.cgColor
        lcd.layer?.shadowRadius = 6
        lcd.layer?.shadowOffset = .zero
        lcd.layer?.masksToBounds = false
        timeLabel.wantsLayer = true
        statusLabel.wantsLayer = true
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        if Analog.on {
            let vfd = Theme.hex(0x7DF0D8)
            timeLabel.textColor = vfd
            let glow = NSShadow()
            glow.shadowColor = vfd.withAlphaComponent(0.8)
            glow.shadowBlurRadius = 6
            timeLabel.shadow = glow
            ghost.font = timeLabel.font
            ghost.textColor = vfd.withAlphaComponent(0.07)
            ghost.stringValue = "88.8.8.888"
            ghost.alignment = .center
            ghost.translatesAutoresizingMaskIntoConstraints = false
            lcd.addSubview(ghost)
            lcd.layer?.backgroundColor = Theme.hex(0x060B0A).cgColor
            lcd.layer?.borderColor = NSColor(white: 0, alpha: 0.9).cgColor
            lcd.layer?.borderWidth = 2
            NSLayoutConstraint.activate([ghost.centerXAnchor.constraint(equalTo: lcd.centerXAnchor),
                                         ghost.centerYAnchor.constraint(equalTo: lcd.centerYAnchor)])
        }
        lcd.addSubview(timeLabel)
        lcd.setAccessibilityElement(true)
        lcd.setAccessibilityLabel("Position")

        rewind.target = self; rewind.action = #selector(rewindTapped)
        playButton.target = self; playButton.action = #selector(playTapped)
        recordButton.target = self; recordButton.action = #selector(recordTapped)
        metronomeButton.target = self; metronomeButton.action = #selector(metronomeTapped)
        cycleButton.target = self; cycleButton.action = #selector(cycleTapped)
        recordButton.contentTintColor = Theme.recordOn.withAlphaComponent(0.75)
        paletteButton.target = self; paletteButton.action = #selector(paletteTapped)
        importButton.target = self; importButton.action = #selector(importTapped)
        tempoField.font = Theme.mono(13, .medium)
        tempoField.textColor = Theme.text
        tempoField.alignment = .right
        tempoField.isBordered = false
        tempoField.drawsBackground = false
        tempoField.focusRingType = .none
        tempoField.toolTip = "Tempo in BPM (type and press Return)"
        tempoField.setAccessibilityLabel("Tempo, beats per minute")
        let bpmLabel = NSTextField(labelWithString: "BPM")
        bpmLabel.font = Theme.mono(9, .medium)
        bpmLabel.textColor = Theme.textDim
        meterPopup.addItems(withTitles: ["2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "12/8"])
        meterPopup.isBordered = false
        meterPopup.font = Theme.mono(12, .medium)
        meterPopup.toolTip = "Time signature"
        meterPopup.setAccessibilityLabel("Time signature")
        let tempo = NSStackView(views: [tempoField, bpmLabel, meterPopup, metronomeButton])
        tempo.spacing = 3
        tempo.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        tempoField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        reels.setAccessibilityElement(false)
        let transport = NSStackView(views: Analog.on ? [tapeStrip, lcd, tempo]
                                                     : [rewind, playButton, recordButton, cycleButton, lcd, tempo])
        transport.spacing = 6

        masterMeter.toolTip = "Output level (click to reset the clip indicator)"
        masterMeter.setAccessibilityLabel("Master level meter")
        let tools = NSStackView(views: [masterMeter, paletteButton, importButton])
        tools.spacing = 8

        for v in [titles, transport, tools] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titles.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.trafficLightInset + 8),
            titles.centerYAnchor.constraint(equalTo: centerYAnchor),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: transport.leadingAnchor, constant: -16),
            transport.centerXAnchor.constraint(equalTo: centerXAnchor),
            transport.centerYAnchor.constraint(equalTo: centerYAnchor),
            lcd.widthAnchor.constraint(equalToConstant: 150),
            lcd.heightAnchor.constraint(equalToConstant: 34),
            timeLabel.centerXAnchor.constraint(equalTo: lcd.centerXAnchor),
            timeLabel.centerYAnchor.constraint(equalTo: lcd.centerYAnchor),
            tools.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tools.centerYAnchor.constraint(equalTo: centerYAnchor),
            masterMeter.widthAnchor.constraint(equalToConstant: 132),
            masterMeter.heightAnchor.constraint(equalToConstant: 8),
        ])
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        (Analog.on ? Analog.faceplate : Theme.panel).setFill(); bounds.fill()
        Theme.separator.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        if Analog.on, let ctx = NSGraphicsContext.current?.cgContext {
            // A faceplate: bevel highlight and screws at the corners clear of the window buttons.
            NSColor(white: 1, alpha: 0.06).setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
            for p in [CGPoint(x: bounds.width - 7, y: 7), CGPoint(x: bounds.width - 7, y: bounds.height - 7), CGPoint(x: 7, y: 7)] {
                Analog.screw(ctx, at: p, radius: 3)
            }
        }
    }

    /// Lets the window be dragged by the bar's empty space.
    override var mouseDownCanMoveWindow: Bool { true }

    func setPlaying(_ playing: Bool) {
        Motion.fadeNextChange(playButton.layer)
        playButton.setSymbol(playing ? "pause.fill" : "play.fill", tint: playing ? Theme.accent : Theme.text)
    }

    @objc private func playTapped() { onPlayPause?() }
    @objc private func recordTapped() { onRecord?() }
    @objc private func metronomeTapped() { onMetronome?() }
    @objc private func cycleTapped() { onCycle?() }

    /// Recording: red record symbol and position display; otherwise the normal look.
    func setRecording(_ recording: Bool) {
        guard recording != isRecordingShown else { return }
        isRecordingShown = recording
        Motion.fadeNextChange(recordButton.layer)
        recordButton.setSymbol(recording ? "record.circle.fill" : "circle.fill",
                               tint: recording ? Theme.recordOn : Theme.recordOn.withAlphaComponent(0.75))
        recordButton.setAccessibilityValue(recording ? "recording" : "stopped")
        if recording { Motion.pulse(recordButton.layer, from: 1, to: 0.4, period: 1.0) } else { Motion.stopPulse(recordButton.layer) }
        Motion.fadeNextChange(timeLabel.layer, duration: Motion.standard)
        timeLabel.textColor = recording ? Theme.recordOn : (Analog.on ? Theme.hex(0x7DF0D8) : Theme.accent)
        if Analog.on { timeLabel.shadow?.shadowColor = (recording ? Theme.recordOn : Theme.hex(0x7DF0D8)).withAlphaComponent(0.8) }
        // The position display's well glows red while recording.
        Motion.layers(Motion.gentle) {
            lcdWell.layer?.borderColor = (recording ? Theme.recordOn.withAlphaComponent(0.7) : Theme.hairline).cgColor
            lcdWell.layer?.shadowColor = Theme.recordOn.cgColor
            lcdWell.layer?.shadowOpacity = recording ? 0.6 : 0
        }
    }
    private var isRecordingShown = false
    @objc private func rewindTapped() { onRewind?() }
    @objc private func importTapped() { onImport?() }
    @objc private func paletteTapped() { onPalette?() }
}

// MARK: - Track header

@MainActor
final class TrackHeaderRow: NSView, NSTextFieldDelegate {
    let trackId: DalnokTrackId
    let session: Session
    weak var column: TrackHeaderColumn?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            Motion.layers(Motion.standard) {
                selectionLayer.opacity = isSelected ? 1 : 0
                strip.frame.size.width = isSelected ? 5 : 3
            }
        }
    }
    /// Selected-row tint and the color strip are layers so selection slides in instead of jumping.
    private let selectionLayer = CALayer(), strip = CALayer()
    private let scribble = ScribbleStrip() // Warm Analog: the display window behind the name
    private var hasShown = false
    /// While recording, an armed row's R chip breathes.
    func setRecording(_ recording: Bool) { arm.pulsing = recording && arm.isOn }
    private var color = Theme.gradientColor(step: 0)
    private var muted = false
    private let number = NSTextField(labelWithString: "")
    /// Track stacks: a disclosure arrow on the stack (in place of the number); members are indented.
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private var numberLeading: NSLayoutConstraint!
    private var isStackRow = false, stackCollapsed = false
    var onToggleStack: ((DalnokTrackId, Bool) -> Void)?
    let nameLabel = NSTextField(labelWithString: "")
    private let mute = ToggleChip("M", on: Theme.muteOn, onText: .white, help: "Mute (⌃M)")
    private let solo = ToggleChip("S", on: Theme.soloOn, onText: Theme.hex(0x1A1400), help: "Solo (⌃S)")
    private let arm = ToggleChip("R", on: Theme.recordOn, onText: .white, help: "Record Enable (⌃R)")
    /// Input source: "IN 1" for audio tracks, "MIDI" for instrument tracks. Click to choose.
    let inputButton = NSButton(title: "IN 1", target: nil, action: nil)
    var onInputMenu: ((TrackHeaderRow) -> Void)?
    let gain = GainKnob()
    private let gainLabel = NSTextField(labelWithString: "GAIN")
    private let panLabel = NSTextField(labelWithString: "PAN")
    let pan = PanKnob()
    let meter = MeterView()
    private var dragStartY: CGFloat?

    init(track: TrackView, index: Int, session: Session) {
        self.trackId = track.id
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        selectionLayer.backgroundColor = Theme.selectedHeader.cgColor
        selectionLayer.opacity = 0
        layer?.addSublayer(selectionLayer)
        layer?.addSublayer(strip)

        number.font = Theme.mono(11)
        number.textColor = Theme.textFaint
        number.alignment = .right
        nameLabel.font = Theme.ui(13, .semibold)
        nameLabel.textColor = Theme.text
        if Analog.on {
            // A console scribble strip: a recessed display window (drawn by the row) with the name lit in the
            // track's color, like the backlit strips on modern analog-style consoles.
            nameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold, width: .condensed)
            nameLabel.drawsBackground = false
        }
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.delegate = self
        nameLabel.toolTip = "Double-click to rename"

        mute.onToggle = { [weak self] on in guard let self else { return }; self.session.setMute(self.trackId, on) }
        solo.onToggle = { [weak self] on in guard let self else { return }; self.session.setSolo(self.trackId, on) }
        arm.onToggle = { [weak self] on in guard let self else { return }; self.session.setArmed(self.trackId, on) }
        inputButton.isBordered = false
        inputButton.font = Theme.mono(10, .medium)
        inputButton.contentTintColor = Theme.textDim
        inputButton.target = self
        inputButton.action = #selector(inputTapped)
        gain.onBegin = { [weak self] in guard let self else { return }; self.session.engine.beginGroup("Volume"); AutomationWriter.shared?.touch(self.trackId, 0, true) }
        gain.onGainChange = { [weak self] db in guard let self else { return }; self.session.setGain(self.trackId, db: db) }
        gain.onEnd = { [weak self] in guard let self else { return }; self.session.engine.endGroup(); AutomationWriter.shared?.touch(self.trackId, 0, false) }
        pan.onBegin = { [weak self] in guard let self else { return }; self.session.engine.beginGroup("Pan"); AutomationWriter.shared?.touch(self.trackId, 1, true) }
        pan.onPanChange = { [weak self] p in guard let self else { return }; self.session.setPan(self.trackId, p) }
        pan.onEnd = { [weak self] in guard let self else { return }; self.session.engine.endGroup(); AutomationWriter.shared?.touch(self.trackId, 1, false) }
        for label in [gainLabel, panLabel] {
            label.font = Theme.mono(10, .medium)
            label.textColor = Theme.textDim
            label.alignment = .center
        }
        meter.vertical = true
        meter.toolTip = "Post-fader level (click to reset the clip indicator)"

        if Analog.on { addSubview(scribble) } // first, so the name draws on top of it
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.contentTintColor = Theme.textDim
        disclosure.target = self
        disclosure.action = #selector(toggleStack)
        disclosure.isHidden = true
        for v in [number, nameLabel, arm, mute, solo, gain, pan, gainLabel, panLabel, meter, inputButton, disclosure] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        numberLeading = number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            numberLeading,
            disclosure.centerXAnchor.constraint(equalTo: number.centerXAnchor), disclosure.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 18), disclosure.heightAnchor.constraint(equalToConstant: 18),
            number.widthAnchor.constraint(equalToConstant: 18),
            number.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: Analog.on ? 14 : 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: arm.leadingAnchor, constant: Analog.on ? -16 : -8),
            arm.trailingAnchor.constraint(equalTo: mute.leadingAnchor, constant: -4),
            arm.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            inputButton.trailingAnchor.constraint(equalTo: solo.trailingAnchor),
            inputButton.centerYAnchor.constraint(equalTo: pan.centerYAnchor),
            solo.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -10),
            solo.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            mute.trailingAnchor.constraint(equalTo: solo.leadingAnchor, constant: -4),
            mute.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            gain.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            gain.centerYAnchor.constraint(equalTo: pan.centerYAnchor),
            gain.widthAnchor.constraint(equalToConstant: 30),
            gain.heightAnchor.constraint(equalToConstant: 30),
            pan.leadingAnchor.constraint(equalTo: gain.trailingAnchor, constant: 34),
            pan.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 12),
            pan.widthAnchor.constraint(equalToConstant: 30),
            pan.heightAnchor.constraint(equalToConstant: 30),
            gainLabel.centerXAnchor.constraint(equalTo: gain.centerXAnchor),
            gainLabel.topAnchor.constraint(equalTo: gain.bottomAnchor, constant: 2),
            panLabel.centerXAnchor.constraint(equalTo: pan.centerXAnchor),
            panLabel.topAnchor.constraint(equalTo: pan.bottomAnchor, constant: 2),
            meter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            meter.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            meter.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            meter.widthAnchor.constraint(equalToConstant: 7),
        ])
        // Long names truncate; the chips never shrink.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for chip in [arm, mute, solo] { chip.setContentCompressionResistancePriority(.required, for: .horizontal) }
        update(track, index: index)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Applies model values (after edits, undo, or scripts) without fighting an active drag.
    func update(_ t: TrackView, index: Int) {
        if color != t.color || muted != t.muted { needsDisplay = true }
        color = t.color
        muted = t.muted
        number.stringValue = "\(index + 1)"
        isStackRow = t.isStack
        stackCollapsed = t.collapsed
        number.isHidden = t.isStack
        disclosure.isHidden = !t.isStack
        if t.isStack {
            disclosure.image = NSImage(systemSymbolName: t.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
            disclosure.toolTip = t.collapsed ? "Open the stack (show its tracks)" : "Close the stack (hide its tracks)"
            disclosure.setAccessibilityLabel(t.collapsed ? "Open stack \(t.name)" : "Close stack \(t.name)")
        }
        numberLeading.constant = 8 + 12 * CGFloat(min(3, session.nesting(t))) // members sit inside their stack (nested ones deeper)
        if !nameLabel.isEditable { nameLabel.stringValue = t.name }
        if Analog.on {
            // Lit in the track's color; a muted channel's strip goes dark.
            let lit = OKLCH.adjust(t.color, dl: 0.2, chromaScale: 0.7)
            nameLabel.textColor = t.muted ? Theme.textFaint : lit
            let glow = NSShadow()
            glow.shadowColor = t.muted ? .clear : lit.withAlphaComponent(0.55)
            glow.shadowBlurRadius = 5
            glow.shadowOffset = .zero
            nameLabel.shadow = glow
            scribble.color = t.color
            scribble.lit = !t.muted
        } else {
            nameLabel.textColor = t.muted ? Theme.textDim : Theme.text
        }
        // Color strip: the track's identity, full height; desaturated (animated) when muted.
        Motion.layers(Motion.gentle) { strip.backgroundColor = (t.muted ? TrackTint(base: t.color).muted : t.color).cgColor }
        mute.isOn = t.muted
        solo.isOn = t.solo
        arm.isOn = t.armed
        let fx = t.effects.count
        let instrument = t.instrumentName ?? "Dalnok Poly"
        inputButton.title = (t.isBus ? "BUS" : t.isInstrument ? String(instrument.prefix(12)) : "IN \(t.inputChannel + 1)") + (fx > 0 ? " · \(fx) FX" : "")
        arm.isHidden = t.isBus
        let missing = t.plugins.filter { !$0.loaded }.map(\.name)
        inputButton.toolTip = (t.isBus ? "A bus mixes what tracks route or send to it (View ▸ Mixer)"
                               : t.isInstrument ? "Instrument: \(instrument). Plays from all MIDI inputs when armed."
                                                : "Recording input channel (click to choose)")
            + (fx > 0 ? "\nInserts: " + t.effects.map(\.name).joined(separator: " → ") : "")
            + (missing.isEmpty ? "" : "\nNot loaded (bypassed): " + missing.joined(separator: ", "))
        inputButton.contentTintColor = missing.isEmpty ? Theme.textDim : Theme.clipRed
        inputButton.setAccessibilityLabel(t.isInstrument ? "Input, MIDI" : "Input channel \(t.inputChannel + 1), \(t.name)")
        arm.setAccessibilityLabel("Record enable \(t.name)")
        gain.tint = t.muted ? Theme.textFaint : t.color
        pan.tint = t.color
        // First display is instant; later changes from undo or scripts glide and light the ring.
        let db: Float = t.gainDb.isFinite ? t.gainDb : -.infinity
        if !gain.tracking { if hasShown { gain.glide(toDb: db) } else { gain.db = db } }
        if !pan.tracking { if hasShown { pan.glide(toPan: t.pan) } else { pan.pan = t.pan } }
        hasShown = true
        gain.setAccessibilityLabel("Volume, \(t.name)")
        pan.setAccessibilityLabel("Pan, \(t.name)")
        mute.setAccessibilityLabel("Mute \(t.name)")
        solo.setAccessibilityLabel("Solo \(t.name)")
        meter.setAccessibilityLabel("Level, \(t.name)")
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = CGRect(x: 0, y: 1, width: bounds.width, height: bounds.height - 2)
        strip.frame = CGRect(x: 0, y: 0, width: isSelected ? 5 : 3, height: bounds.height - 1)
        CATransaction.commit()
        if Analog.on {
            let n = nameLabel.frame
            scribble.frame = NSRect(x: n.minX - 7, y: n.midY - 11, width: max(40, arm.frame.minX - 9 - (n.minX - 7)), height: 22)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        (Analog.on ? Analog.faceplate : Theme.panelRaised).setFill()
        bounds.fill()
        if !Analog.on { // a wash of the track colour helps find a track in a long list
            (muted ? TrackTint(base: color).muted : color).withAlphaComponent(0.08).setFill()
            bounds.fill()
        }
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    // MARK: Rename (double-click the name)

    @objc private func inputTapped() { onInputMenu?(self) }
    @objc private func toggleStack() { onToggleStack?(trackId, !stackCollapsed) }

    func beginRename() {
        nameLabel.isEditable = true
        nameLabel.isBezeled = true
        nameLabel.drawsBackground = true
        // Both themes edit in a dark well (Warm Analog: the scribble strip itself).
        nameLabel.backgroundColor = Analog.on ? Theme.hex(0x0D0A08) : Theme.window
        window?.makeFirstResponder(nameLabel)
        nameLabel.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard nameLabel.isEditable else { return }
        nameLabel.isEditable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false // Warm Analog's strip is drawn by the row
        let name = renameCancelled ? "" : nameLabel.stringValue.trimmingCharacters(in: .whitespaces)
        renameCancelled = false
        if !name.isEmpty { session.renameTrack(trackId, name) } else { session.refresh() }
        if let t = session.track(trackId) { nameLabel.stringValue = t.name }
    }
    private var renameCancelled = false

    /// Ends a rename without changing the name (Escape does the same).
    func cancelRename() { renameCancelled = true; window?.makeFirstResponder(nil) }
    /// Escape cancels the rename and keeps the old name; Return commits.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renameCancelled = true
        window?.makeFirstResponder(nil)
        return true
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
}

/// Column of track headers; vertically synced with the timeline.
@MainActor
final class TrackHeaderColumn: NSView, TrackScrollHost {
    /// Scrolling over the headers moves the shared track viewport (owned by the timeline).
    var onScroll: ((NSEvent) -> Void)?
    func scrollTracks(with event: NSEvent) { onScroll?(event) }
    override func scrollWheel(with event: NSEvent) { scrollTracks(with: event) }
    /// A plug-in dragged from the browser onto a track header is inserted on that track.
    var onDropPlugin: ((String, DalnokTrackId) -> Void)?
    private var dropRow: TrackHeaderRow? { didSet { oldValue?.layer?.borderWidth = 0; dropRow?.layer?.borderWidth = 2; dropRow?.layer?.borderColor = Theme.selection.cgColor } }
    private func row(atWindow p: NSPoint) -> TrackHeaderRow? { rows.first { $0.convert($0.bounds, to: nil).contains(p) } }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .dalnokPlugin) != nil, let r = row(atWindow: sender.draggingLocation),
              session.track(r.trackId)?.isBus == false || session.track(r.trackId)?.plugins != nil else { dropRow = nil; return [] }
        dropRow = r
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropRow = nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropRow = nil }
        guard let path = sender.draggingPasteboard.string(forType: .dalnokPlugin), let r = row(atWindow: sender.draggingLocation) else { return false }
        onDropPlugin?(path, r.trackId)
        return true
    }
    var onToggleStack: ((DalnokTrackId, Bool) -> Void)?
    let session: Session
    private(set) var rows: [TrackHeaderRow] = []
    private let rowClip = FlippedView()
    private let insertLine = CALayer()
    private let addButton = IconButton("plus", help: "New Track (⌥⌘N)", size: 12)
    private var dropIndex: Int?
    private var hasSynced = false
    var scrollY: CGFloat = 0 { didSet { needsLayout = true } }
    var selectedTrack: DalnokTrackId? { didSet { rows.forEach { $0.isSelected = $0.trackId == selectedTrack }; onSelect?(selectedTrack) } }
    var onSelect: ((DalnokTrackId?) -> Void)?
    var onAddTrack: (() -> Void)?
    var onInputMenu: ((TrackHeaderRow) -> Void)?
    var contextMenu: NSMenu?

    func select(_ id: DalnokTrackId) { selectedTrack = id }
    func row(_ id: DalnokTrackId) -> TrackHeaderRow? { rows.first { $0.trackId == id } }

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor
        rowClip.wantsLayer = true
        rowClip.layer?.masksToBounds = true
        addSubview(rowClip)
        insertLine.backgroundColor = Theme.selection.cgColor
        insertLine.isHidden = true
        insertLine.zPosition = 5
        rowClip.layer?.addSublayer(insertLine)
        addButton.target = self
        addButton.action = #selector(addTapped)
        addSubview(addButton)
        registerForDraggedTypes([.dalnokPlugin])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    @objc private func addTapped() { onAddTrack?() }

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

    /// Reuses rows by track id so in-progress drags survive model updates.
    func sync() {
        let tracks = session.tracks
        if rows.map(\.trackId) != tracks.map(\.id) {
            var byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.trackId, $0) })
            var added: [TrackHeaderRow] = []
            rows = tracks.enumerated().map { i, t in
                if let row = byId.removeValue(forKey: t.id) { return row }
                let row = TrackHeaderRow(track: t, index: i, session: session)
                added.append(row)
                return row
            }
            // Removed rows fade out; rows added after the first load fade and slide in (not on project open).
            for gone in byId.values {
                Motion.views(Motion.quick, { gone.animator().alphaValue = 0 }, completion: {
                    DispatchQueue.main.async { gone.removeFromSuperview() }
                })
            }
            if hasSynced && added.count <= 4 {
                for row in added {
                    row.alphaValue = 0
                    DispatchQueue.main.async {
                        Motion.layers(Motion.gentle) {
                            let slide = CABasicAnimation(keyPath: "transform.translation.x")
                            slide.fromValue = -24
                            slide.toValue = 0
                            slide.duration = Motion.reduced ? 0 : Motion.gentle
                            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                            row.layer?.add(slide, forKey: "slideIn")
                        }
                        Motion.views(Motion.gentle) { row.animator().alphaValue = 1 }
                    }
                }
            }
            hasSynced = true
            rows.forEach { if $0.superview == nil { rowClip.addSubview($0) } }
            rows.forEach {
                $0.column = self; $0.isSelected = $0.trackId == selectedTrack; $0.onInputMenu = { [weak self] r in self?.onInputMenu?(r) }
                $0.onToggleStack = { [weak self] id, closed in self?.onToggleStack?(id, closed) }
            }
            if let sel = selectedTrack, !tracks.contains(where: { $0.id == sel }) { selectedTrack = nil }
            needsLayout = true
        }
        for (i, (row, t)) in zip(rows, tracks).enumerated() { row.update(t, index: i) }
    }

    override func layout() {
        super.layout()
        rowClip.frame = CGRect(x: 0, y: Theme.rulerHeight, width: bounds.width - 1, height: max(0, bounds.height - Theme.rulerHeight))
        for (i, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(i) * Theme.trackHeight - scrollY, width: rowClip.bounds.width, height: Theme.trackHeight)
        }
        addButton.frame = CGRect(x: bounds.width - 40, y: 0, width: 34, height: Theme.rulerHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.panel.setFill()
        bounds.fill()
        let hiddenCount = session.hiddenCount
        let title = (hiddenCount > 0 ? "TRACKS · \(hiddenCount) HIDDEN" : "TRACKS") as NSString
        title.draw(at: NSPoint(x: 16, y: 7), withAttributes: [.font: Theme.ui(10, .semibold), .foregroundColor: Theme.textDim, .kern: 0.8])
        Theme.separator.setFill()
        NSRect(x: 0, y: Theme.rulerHeight - 1, width: bounds.width, height: 1).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// A view that owns (or forwards to) the shared vertical track viewport. Controls inside it pass wheel and
/// trackpad scrolling up instead of changing their value, so scrolling over a header never nudges a fader.
@MainActor
protocol TrackScrollHost: AnyObject {
    func scrollTracks(with event: NSEvent)
}

extension NSView {
    /// Sends a scroll event to the nearest enclosing `TrackScrollHost`. Returns false when there is none.
    func forwardScrollToTrackHost(_ event: NSEvent) -> Bool {
        var v = superview
        while let s = v {
            if let host = s as? TrackScrollHost { host.scrollTracks(with: event); return true }
            v = s.superview
        }
        return false
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}


/// Warm Analog track name window: a recessed dark display with a glass sheen, lit from below in the track's color.
@MainActor
final class ScribbleStrip: NSView {
    var color: NSColor = .gray { didSet { needsDisplay = true } }
    var lit = true { didSet { if lit != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the row (select, double-click rename)

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let well = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        Theme.hex(0x0D0A08).setFill(); well.fill()
        NSGraphicsContext.saveGraphicsState()
        well.addClip()
        NSGradient(starting: Theme.hex(0xFFFFFF, 0.07), ending: Theme.hex(0xFFFFFF, 0))?
            .draw(in: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2), angle: -90)
        if lit {
            NSGradient(starting: color.withAlphaComponent(0), ending: color.withAlphaComponent(0.14))?
                .draw(in: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), angle: -90)
        }
        Theme.hex(0x000000, 0.7).setFill(); NSRect(x: r.minX, y: r.minY, width: r.width, height: 1).fill() // inner top shadow
        NSGraphicsContext.restoreGraphicsState()
        Theme.hex(0x000000, 0.85).setStroke(); well.lineWidth = 1; well.stroke()
    }
}
