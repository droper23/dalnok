// Control bar (in the title bar) and track headers.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

// MARK: - Control bar

/// Accepts only a tempo while typing: digits and one decimal point (a comma counts as one), up to 6 characters.
final class TempoFormatter: Formatter {
    override func string(for obj: Any?) -> String? { (obj as? String) ?? (obj as? NSNumber)?.stringValue }
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString
        return true
    }
    override func isPartialStringValid(_ partial: String, newEditingString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        Self.valid(partial)
    }
    static func valid(_ s: String) -> Bool {
        s.count <= 6 && s.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }
            && s.filter { $0 == "." || $0 == "," }.count <= 1
    }
}

/// The tempo readout. Drag up or down to change the tempo (⇧ for 0.1 BPM steps); click to type a value. It is
/// editable only on purpose (click or Transport ▸ Edit Tempo): as an ordinary text field it became the window's first
/// responder at launch, which made Space, R and Delete count as typing.
final class TempoField: NSTextField {
    private var armed = false
    /// Called with the new tempo while dragging, then once with nil when the drag ends.
    var onDrag: ((Double?) -> Void)?
    /// A click arms it from mouseDown (a drag changes the tempo instead); Tab reaches it like any field (keyboard-only use).
    override var acceptsFirstResponder: Bool { armed || CommittingWindow.navigating }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if !armed { armed = true; showEditing(true) }
        return true
    }
    override init(frame: NSRect) { super.init(frame: frame); setUp() }
    required init?(coder: NSCoder) { super.init(coder: coder); setUp() }
    private func setUp() {
        formatter = TempoFormatter()
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.borderWidth = 0
    }
    override func resetCursorRects() { if !armed { addCursorRect(bounds, cursor: .resizeUpDown) } }
    func beginEditing() {
        armed = true
        showEditing(true)
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
    /// While typing: a lit box with a bright frame, so it is obvious the tempo is being edited.
    private func showEditing(_ on: Bool) {
        drawsBackground = on
        backgroundColor = on ? Theme.hex(0x0B0D10) : .clear
        layer?.borderWidth = on ? 1.5 : 0
        layer?.borderColor = Theme.accent.cgColor
        layer?.backgroundColor = on ? Theme.hex(0x0B0D10).cgColor : nil
        window?.invalidateCursorRects(for: self)
    }
    override func mouseDown(with event: NSEvent) {
        guard !armed else { return super.mouseDown(with: event) }
        // Drag to change; a click without movement starts typing.
        let start = event.locationInWindow, startBpm = Double(stringValue.replacingOccurrences(of: ",", with: ".")) ?? 120
        var dragging = false, bpm = startBpm, last = start.y
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let dy = e.locationInWindow.y - start.y
            if !dragging && abs(dy) < 3 && abs(e.locationInWindow.x - start.x) < 3 { continue }
            dragging = true
            let fine = e.modifierFlags.contains(.shift)
            bpm += Double(e.locationInWindow.y - last) * (fine ? 0.1 : 0.5)
            last = e.locationInWindow.y
            bpm = min(400, max(20, bpm))
            let shown = fine ? (bpm * 10).rounded() / 10 : bpm.rounded()
            stringValue = String(format: "%g", shown)
            onDrag?(shown)
        }
        if dragging { onDrag?(nil) } else { beginEditing() }
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        armed = false
        showEditing(false)
    }
}

@MainActor
final class TransportBar: NSView {
    let titleLabel = NSTextField(labelWithString: "Untitled")
    /// Secondary line under the title: audio status, or a transient message.
    let statusLabel = NSTextField(labelWithString: "")
    /// Shown beside the status while a project's plug-ins load (ADR-0013); stops loading the rest.
    let stopLoadingButton = NSButton(title: "Stop", target: nil, action: nil)
    let timeLabel = NSTextField(labelWithString: "0:00.000")
    /// Small second readout under the main one: real time when the main shows bars, and bars when it shows time.
    let subTimeLabel = NSTextField(labelWithString: "")
    /// Settings ▸ Clock: show the small second readout.
    static var showsSecondaryClock: Bool {
        get { UserDefaults.standard.bool(forKey: "secondaryClock") }
        set { UserDefaults.standard.set(newValue, forKey: "secondaryClock"); NotificationCenter.default.post(name: clockChanged, object: nil) }
    }
    static let clockChanged = Notification.Name("DalnokClockChanged")
    private var timeCenter: NSLayoutConstraint?, ghostCenter: NSLayoutConstraint?
    private var lcdWidth: NSLayoutConstraint?, timeCenterX: NSLayoutConstraint?, subCenterX: NSLayoutConstraint?
    private var subBottom: NSLayoutConstraint?, subCenterY: NSLayoutConstraint?
    /// Atelier's counter: one drum window, or two side by side (position | the other readout) so neither is cut.
    static func housingSize(split: Bool) -> CGSize {
        CGSize(width: Illustrated.size(split ? 238 : 150, 1.2), height: Illustrated.size(34, 1.2))
    }
    /// The left window's share of a split housing.
    static let splitFraction: CGFloat = 0.6
    /// Lays the display out for one or two readouts.
    func applyClockSetting() {
        let on = Self.showsSecondaryClock
        subTimeLabel.isHidden = !on
        timeLabel.font = Theme.look.transport == .lcd || Theme.look.transport == .tapeDeck ? Theme.mono(on ? 17 : 20, .medium) : Theme.display(on ? 17 : 20)
        ghost.font = timeLabel.font
        timeCenter?.constant = on ? -5 : 0
        ghostCenter?.constant = on ? -5 : 0
        lcdWidth?.constant = Theme.look.transport == .typeset ? Self.housingSize(split: false).width : 150
        timeCenterX?.constant = 0; subCenterX?.constant = 0
        subBottom?.isActive = true; subCenterY?.isActive = false
        if Theme.look.transport == .typeset {
            // Two drums side by side: the position large on the left, the other readout on the right, both centred.
            let size = Self.housingSize(split: on)
            lcdWidth?.constant = size.width
            timeLabel.font = Theme.display(Illustrated.size(on ? 18 : 20, 1.2))
            subTimeLabel.font = Theme.display(Illustrated.size(13.5, 1.2))
            timeCenter?.constant = 0
            if on {
                let split = size.width * Self.splitFraction
                timeCenterX?.constant = split / 2 - size.width / 2
                subCenterX?.constant = split + (size.width - split) / 2 - size.width / 2
                subBottom?.isActive = false; subCenterY?.isActive = true
            }
            lcdWell.layer?.contents = Atelier.counterHousing(size: size, split: on ? Self.splitFraction : nil)
        }
    }
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
    /// Optional count-in, lit while on (Logic's control bar has the same pair: metronome and count-in).
    let countInButton = IconButton("123.rectangle", help: "Count-In (⇧K): one bar of clicks before recording starts")
    var onCountIn: (() -> Void)?
    var onMetronome: (() -> Void)?
    let cycleButton = IconButton("repeat", help: "Cycle (C): loop playback between the yellow markers in the ruler")
    var onCycle: (() -> Void)?
    private let rewind = IconButton("backward.end.fill", help: "Go to Start (Return)")
    private let paletteButton = IconButton("magnifyingglass", help: "Command Palette (⌘K)")
    private let importButton = IconButton("plus.rectangle.on.rectangle", help: "Import Audio… (⌘I)")
    /// View toggles, lit while their view is open (Logic's control bar and Bitwig's panel buttons put these in reach
    /// so nobody has to know the shortcut or the menu).
    let launcherButton = IconButton("square.grid.3x2", help: "Clip Launcher (⌘L)")
    let automationButton = IconButton("point.topleft.down.to.point.bottomright.curvepath", help: "Automation (A)")
    let mixerButton = IconButton("slider.vertical.3", help: "Mixer (X)")
    let devicesButton = IconButton("rectangle.3.group", help: "Device Panel (⌥⌘D): the selected track's plug-ins")
    var onLauncher: (() -> Void)?, onAutomation: (() -> Void)?, onMixer: (() -> Void)?, onDevices: (() -> Void)?
    /// The side panels, just left of the transport (as Logic's control bar has them).
    let libraryButton = IconButton("sidebar.left", help: "Library (Y): plug-ins, collections and projects")
    let inspectorButton = IconButton("sidebar.right", help: "Inspector (I): the selected track's channel")
    var onLibrary: (() -> Void)?, onInspector: (() -> Void)?
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
        layer?.backgroundColor = Theme.look.transport == .glassCapsule ? nil : Theme.panel.cgColor

        titleLabel.font = Theme.ui(13, .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = Theme.ui(11)
        statusLabel.textColor = Theme.textDim
        statusLabel.lineBreakMode = .byTruncatingTail
        stopLoadingButton.bezelStyle = .inline
        stopLoadingButton.controlSize = .small
        stopLoadingButton.font = Theme.ui(10)
        stopLoadingButton.isHidden = true
        stopLoadingButton.toolTip = "Stop loading plug-ins; the rest stay unloaded with their settings"
        stopLoadingButton.setAccessibilityLabel("Stop loading plug-ins")
        let statusRow = NSStackView(views: [statusLabel, stopLoadingButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        let titles = NSStackView(views: [titleLabel, statusRow])
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
        if Theme.look.tapeDeck {
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
            ghostCenter = ghost.centerYAnchor.constraint(equalTo: lcd.centerYAnchor)
            NSLayoutConstraint.activate([ghost.centerXAnchor.constraint(equalTo: lcd.centerXAnchor), ghostCenter!])
        }
        lcd.addSubview(timeLabel)
        subTimeLabel.font = Theme.mono(9, .medium)
        subTimeLabel.textColor = (Theme.look.tapeDeck ? Theme.hex(0x7DF0D8) : Theme.accent).withAlphaComponent(0.65)
        subTimeLabel.alignment = .center
        subTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        subTimeLabel.setAccessibilityLabel("Secondary position")
        lcd.addSubview(subTimeLabel)
        lcd.setAccessibilityElement(true)
        lcd.setAccessibilityLabel("Position")

        rewind.target = self; rewind.action = #selector(rewindTapped)
        playButton.target = self; playButton.action = #selector(playTapped)
        recordButton.target = self; recordButton.action = #selector(recordTapped)
        metronomeButton.target = self; metronomeButton.action = #selector(metronomeTapped)
        countInButton.target = self; countInButton.action = #selector(countInTapped)
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
        tempoField.toolTip = "Tempo in BPM: drag up or down (⇧ fine), or click to type and press Return"
        tempoField.setAccessibilityLabel("Tempo, beats per minute")
        let bpmLabel = NSTextField(labelWithString: "BPM")
        bpmLabel.font = Theme.mono(9, .medium)
        bpmLabel.textColor = Theme.textDim
        meterPopup.addItems(withTitles: ["2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "12/8"])
        meterPopup.isBordered = false
        meterPopup.font = Theme.mono(12, .medium)
        if Theme.activeStyle == .atelier { // the borderless pop-up draws its item in the system face unless told
            for item in meterPopup.itemArray { item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: Theme.display(15), .foregroundColor: Theme.text]) }
        }
        meterPopup.toolTip = "Time signature"
        meterPopup.setAccessibilityLabel("Time signature")
        let tempo = NSStackView(views: [tempoField, bpmLabel, meterPopup, metronomeButton, countInButton])
        tempo.spacing = 3
        tempo.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        tempoField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        reels.setAccessibilityElement(false)
        let transport = NSStackView(views: Theme.look.tapeDeck ? [tapeStrip, lcd, tempo]
                                                     : [rewind, playButton, recordButton, cycleButton, lcd, tempo])
        transport.spacing = 6
        transportCluster = transport
        styleDisplayForFamily(lcd)
        Atelier.unifyFonts(in: self)
        titleGroup = titles

        masterMeter.toolTip = "Output level (click to reset the clip indicator)"
        masterMeter.setAccessibilityLabel("Master level meter")
        masterMeter.needle = Theme.look.meters == .graduated // Atelier
        for (b, sel) in [(launcherButton, #selector(launcherTapped)), (automationButton, #selector(automationTapped)),
                         (mixerButton, #selector(mixerTapped)), (devicesButton, #selector(devicesTapped)),
                         (libraryButton, #selector(libraryTapped)), (inspectorButton, #selector(inspectorTapped))] {
            b.target = self; b.action = sel
        }
        let views = NSStackView(views: [launcherButton, automationButton, mixerButton, devicesButton])
        views.spacing = 2
        let tools = NSStackView(views: [views, masterMeter, paletteButton, importButton])
        tools.spacing = 8
        toolsGroup = tools
        tools.setCustomSpacing(16, after: views)

        let panes = NSStackView(views: [libraryButton, inspectorButton])
        panes.spacing = 2
        for v in [titles, panes, transport, tools] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titles.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.trafficLightInset + 8),
            titles.centerYAnchor.constraint(equalTo: centerYAnchor),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: panes.leadingAnchor, constant: -12),
            panes.trailingAnchor.constraint(equalTo: transport.leadingAnchor, constant: -14),
            panes.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Centred while there is room; in a narrow window the transport moves left rather than under the tools.
            transport.centerXAnchor.constraint(equalTo: centerXAnchor).withPriority(.defaultHigh),
            tools.leadingAnchor.constraint(greaterThanOrEqualTo: transport.trailingAnchor, constant: 20),
            transport.centerYAnchor.constraint(equalTo: centerYAnchor),

            lcd.heightAnchor.constraint(equalToConstant: Theme.look.transport == .typeset ? Illustrated.size(34, 1.2) : 34),

            tools.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tools.centerYAnchor.constraint(equalTo: centerYAnchor),
            masterMeter.widthAnchor.constraint(equalToConstant: Theme.look.meters == .graduated ? 84 : 132),
            masterMeter.heightAnchor.constraint(equalToConstant: Theme.look.meters == .graduated ? 32 : 8),
        ])
        timeCenter = timeLabel.centerYAnchor.constraint(equalTo: lcd.centerYAnchor)
        timeCenter?.isActive = true
        lcdWidth = lcd.widthAnchor.constraint(equalToConstant: 150)
        timeCenterX = timeLabel.centerXAnchor.constraint(equalTo: lcd.centerXAnchor)
        subCenterX = subTimeLabel.centerXAnchor.constraint(equalTo: lcd.centerXAnchor)
        subBottom = subTimeLabel.bottomAnchor.constraint(equalTo: lcd.bottomAnchor, constant: -1)
        subCenterY = subTimeLabel.centerYAnchor.constraint(equalTo: lcd.centerYAnchor)
        NSLayoutConstraint.activate([lcdWidth!, timeCenterX!, subCenterX!, subBottom!])
        applyClockSetting()
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The transport buttons, display and tempo (Prism floats them on a glass capsule).
    private weak var transportCluster: NSView?, titleGroup: NSView?, toolsGroup: NSView?

    /// Prism: a glass-encased display with light-weight figures; Atelier: a ruled frame with the position typeset large.
    private func styleDisplayForFamily(_ lcd: NSView) {
        switch Theme.look.transport {
        case .glassCapsule:
            lcd.layer?.backgroundColor = (Theme.isLight ? Theme.hex(0xFFFFFF, 0.55) : Theme.hex(0x05070F, 0.55)).cgColor
            lcd.layer?.cornerRadius = 13
            lcd.layer?.borderColor = Theme.hex(0xFFFFFF, Theme.isLight ? 0.9 : 0.18).cgColor
            timeLabel.textColor = displayColor
            let glow = NSShadow()
            glow.shadowColor = Theme.accent.withAlphaComponent(0.65)
            glow.shadowBlurRadius = 8
            timeLabel.shadow = glow
            subTimeLabel.textColor = Theme.accent.withAlphaComponent(0.75)
        case .typeset:
            lcd.layer?.backgroundColor = Theme.lcd.cgColor
            lcd.layer?.cornerRadius = 0
            // An engraved counter: a ruled housing screwed to the plate, the figures on a drum (shaded top and bottom).
            lcd.layer?.contents = Atelier.counterHousing(size: Self.housingSize(split: Self.showsSecondaryClock),
                                                         split: Self.showsSecondaryClock ? Self.splitFraction : nil)
            lcd.layer?.contentsScale = 2
            timeLabel.textColor = Theme.text
            subTimeLabel.textColor = Theme.ink(0.85)
            tempoField.font = Theme.display(15)
        case .lcd, .tapeDeck: break
        }
        if Theme.look.transport != .lcd && Theme.look.transport != .tapeDeck { applyClockSetting() }
    }
    /// The position display's normal colour (recording turns it red).
    private var displayColor: NSColor {
        switch Theme.look.transport {
        case .tapeDeck: Theme.hex(0x7DF0D8)
        case .glassCapsule: Theme.isLight ? Theme.text : Theme.hex(0xF2F6FF)
        case .typeset: Theme.text
        case .lcd: Theme.accent
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch Theme.look.transport {
        case .glassCapsule:
            // No bar at all: the title, the transport and the tools float as three capsules of glass over the light.
            Prism.drawField(in: self, frosted: false)
            for (group, dx, prominence) in [(titleGroup, CGFloat(14), CGFloat(0)), (transportCluster, 14, 0.6), (toolsGroup, 10, 0)] {
                guard let f = group?.frame else { continue }
                let capsule = CGRect(x: f.minX - dx, y: bounds.midY - 19, width: f.width + 2 * dx, height: 38)
                Prism.liquidPane(self, capsule, radius: 19, prominence: prominence)
            }
            return
        case .typeset:
            Theme.panel.setFill(); bounds.fill()
            if let ctx = NSGraphicsContext.current?.cgContext {
                // A title block's rules: heavy below, hairline above it.
                Atelier.rule(ctx, CGPoint(x: 0, y: 0.75), CGPoint(x: bounds.width, y: 0.75), weight: Atelier.medium)
                Atelier.rule(ctx, CGPoint(x: 0, y: 3.5), CGPoint(x: bounds.width, y: 3.5), weight: Atelier.hair, color: Theme.ink(0.4))
            }
            return
        case .lcd, .tapeDeck: break
        }
        (Theme.look.tapeDeck ? Analog.faceplate : Theme.panel).setFill(); bounds.fill()
        Theme.separator.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        if Theme.look.tapeDeck, let ctx = NSGraphicsContext.current?.cgContext {
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
    @objc private func countInTapped() { onCountIn?() }
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
        timeLabel.textColor = recording ? Theme.recordOn : displayColor
        if Theme.look.tapeDeck { timeLabel.shadow?.shadowColor = (recording ? Theme.recordOn : Theme.hex(0x7DF0D8)).withAlphaComponent(0.8) }
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
    @objc private func launcherTapped() { onLauncher?() }
    @objc private func automationTapped() { onAutomation?() }
    @objc private func mixerTapped() { onMixer?() }
    @objc private func devicesTapped() { onDevices?() }
    @objc private func libraryTapped() { onLibrary?() }
    @objc private func inspectorTapped() { onInspector?() }
}

// MARK: - Track header

@MainActor
final class TrackHeaderRow: NSView, NSTextFieldDelegate {
    /// Lane heights a track can be dragged to (points).
    static let minHeight: CGFloat = 48, maxHeight: CGFloat = 400
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
    private let mute = ToggleChip("M", on: Theme.muteOn, onText: Theme.onState(Theme.muteOn), help: "Mute (⌃M)")
    private let solo = ToggleChip("S", on: Theme.soloOn, onText: Theme.onState(Theme.soloOn), help: "Solo (⌃S)")
    private let arm = ToggleChip("R", on: Theme.recordOn, onText: Theme.onState(Theme.recordOn), help: "Record Enable (⌃R)")
    private let monitor = ToggleChip("I", on: Theme.monitorOn, onText: Theme.onState(Theme.monitorOn), help: "Input Monitoring: hear this track's input now, recording or not (⌃I)")
    var onInputMonitor: ((DalnokTrackId) -> Void)?
    /// Input source: "IN 1" for audio tracks, "MIDI" for instrument tracks. Click to choose.
    let inputButton = NSButton(title: "IN 1", target: nil, action: nil)
    var onInputMenu: ((TrackHeaderRow) -> Void)?
    /// The input label's two parts: the source ("IN 1", a bus, the instrument's name) and its counts ("2 FX", the group).
    /// When both don't fit on one line the counts take a second line, so a long name never hides them.
    private(set) var inputSource = "", inputCounts = ""
    func setInput(source: String, counts: String) {
        inputSource = source; inputCounts = counts
        applyInputTitle()
    }
    private func applyInputTitle() {
        let font = inputButton.font ?? Theme.mono(10, .medium)
        func width(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width + 6 }
        let avail = pan.frame.maxX > 0 ? solo.frame.maxX - pan.frame.maxX - 8 : .greatestFiniteMagnitude
        let one = inputSource + (inputCounts.isEmpty ? "" : " · " + inputCounts)
        var title = one
        if !inputCounts.isEmpty, width(one) > avail {
            var src = inputSource
            while width(src) > avail, src.count > 2 { src = String(src.dropLast(2)) + "…" }
            title = src + "\n" + inputCounts
        }
        let two = title.contains("\n")
        (inputButton.cell as? NSButtonCell)?.lineBreakMode = two ? .byClipping : .byTruncatingTail
        inputButton.alignment = .right
        if inputButton.title != title { inputButton.title = title }
    }
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
        switch Theme.look.headers {
        case .glass:
            // Prism: the selected header is a raised pane of glass; the colour edge is a light pipe that glows.
            selectionLayer.backgroundColor = (Theme.isLight ? Theme.hex(0xFFFFFF, 0.55) : Theme.hex(0x9FB2FF, 0.12)).cgColor
            selectionLayer.cornerRadius = 10
            selectionLayer.borderWidth = 1
            selectionLayer.borderColor = Theme.hex(0xFFFFFF, Theme.isLight ? 0.9 : 0.22).cgColor
            selectionLayer.shadowColor = NSColor.black.cgColor
            selectionLayer.shadowOpacity = 0.5
            selectionLayer.shadowRadius = 8
            selectionLayer.shadowOffset = CGSize(width: 0, height: -2)
            strip.cornerRadius = 1.5
            strip.shadowRadius = 5
            strip.shadowOpacity = 0.9
            strip.shadowOffset = .zero
        case .scoreLabels:
            // Atelier: the selected header is marked in the margin (vermilion rule) on a faint ochre wash.
            selectionLayer.backgroundColor = Theme.laneHighlight.cgColor
            selectionLayer.borderWidth = 0
        case .rows, .channelStrips: break
        }
        layer?.addSublayer(selectionLayer)
        layer?.addSublayer(strip)

        number.font = Theme.mono(11)
        number.textColor = Theme.textFaint
        number.alignment = .right
        nameLabel.font = Theme.ui(13, .semibold)
        nameLabel.textColor = Theme.text
        if Theme.look.headers == .scoreLabels {
            // A typeset score label: the name in the text serif, the number as an old-style figure in the margin.
            nameLabel.font = Theme.title(14, .semibold)
            number.font = Theme.title(12, .regular)
        }
        if Theme.look.channelStripHeaders {
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
        monitor.onToggle = { [weak self] _ in guard let self else { return }; self.onInputMonitor?(self.trackId) }
        inputButton.isBordered = false
        inputButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (inputButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        inputButton.font = Theme.mono(10, .medium)
        inputButton.contentTintColor = Theme.textDim
        inputButton.target = self
        inputButton.action = #selector(inputTapped)
        gain.onBegin = { [weak self] in guard let self else { return }; self.session.engine.beginGroup("Volume"); AutomationWriter.shared?.touch(self.trackId, 0, true) }
        gain.onGainChange = { [weak self] db in guard let self else { return }; self.session.setGain(self.trackId, db: db); self.showReadouts(db: db) }
        gain.onEnd = { [weak self] in guard let self else { return }; self.session.engine.endGroup(); AutomationWriter.shared?.touch(self.trackId, 0, false) }
        pan.onBegin = { [weak self] in guard let self else { return }; self.session.engine.beginGroup("Pan"); AutomationWriter.shared?.touch(self.trackId, 1, true) }
        pan.onPanChange = { [weak self] p in guard let self else { return }; self.session.setPan(self.trackId, p); self.showReadouts(pan: p) }
        pan.onEnd = { [weak self] in guard let self else { return }; self.session.engine.endGroup(); AutomationWriter.shared?.touch(self.trackId, 1, false) }
        if Theme.look.headers == .scoreLabels { inputButton.font = Theme.note(11) }
        for label in [gainLabel, panLabel] {
            label.font = Theme.mono(9, .medium) // fits the row the old GAIN/PAN captions had
            label.textColor = Theme.textDim
            label.setAccessibilityElement(false) // the knob reports its own value
            label.alignment = .center
        }
        meter.vertical = true
        meter.toolTip = "Post-fader level (click to reset the clip indicator)"

        if Theme.look.channelStripHeaders { addSubview(scribble) } // first, so the name draws on top of it
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.contentTintColor = Theme.textDim
        disclosure.target = self
        disclosure.action = #selector(toggleStack)
        disclosure.isHidden = true
        for v in [number, nameLabel, arm, monitor, mute, solo, gain, pan, gainLabel, panLabel, meter, inputButton, disclosure] as [NSView] {
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
            nameLabel.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: Theme.look.channelStripHeaders ? 14 : 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: arm.leadingAnchor, constant: Theme.look.channelStripHeaders ? -16 : -8),
            arm.trailingAnchor.constraint(equalTo: monitor.leadingAnchor, constant: -4),
            arm.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            monitor.trailingAnchor.constraint(equalTo: mute.leadingAnchor, constant: -4),
            monitor.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            inputButton.trailingAnchor.constraint(equalTo: solo.trailingAnchor),
            inputButton.centerYAnchor.constraint(equalTo: pan.centerYAnchor),
            // Never over the pan knob: a long instrument name truncates instead.
            inputButton.leadingAnchor.constraint(greaterThanOrEqualTo: pan.trailingAnchor, constant: 8),
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
            gainLabel.topAnchor.constraint(equalTo: gain.bottomAnchor, constant: 0),
            panLabel.centerXAnchor.constraint(equalTo: pan.centerXAnchor),
            panLabel.topAnchor.constraint(equalTo: pan.bottomAnchor, constant: 0),
            meter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            meter.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            meter.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            meter.widthAnchor.constraint(equalToConstant: 7),
        ])
        // Long names truncate; the chips never shrink.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for chip in [arm, monitor, mute, solo] { chip.setContentCompressionResistancePriority(.required, for: .horizontal) }
        update(track, index: index)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Applies model values (after edits, undo, or scripts) without fighting an active drag.
    /// The values under the knobs (the audit: a producer reads levels without hovering). Same row height as the old
    /// GAIN and PAN captions; the knobs' accessibility names still say what they are.
    func showReadouts(db: Float? = nil, pan p: Float? = nil) {
        if let db { let s = db <= -95 ? "−∞ dB" : String(format: "%@%.1f dB", db >= 0 ? "+" : "−", abs(db)); if gainLabel.stringValue != s { gainLabel.stringValue = s } }
        if let p { let s = PanKnob.format(Double(p)); if panLabel.stringValue != s { panLabel.stringValue = s } }
    }
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
        if Theme.look.channelStripHeaders {
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
        Motion.layers(Motion.gentle) {
            strip.backgroundColor = (t.muted ? TrackTint(base: t.color).muted : t.color).cgColor
            strip.shadowColor = t.muted ? nil : t.color.cgColor // Prism's light pipe goes out when muted
        }
        mute.isOn = t.muted
        solo.isOn = t.solo
        arm.isOn = t.armed
        monitor.isOn = t.inputMonitor
        monitor.isHidden = t.isBus || t.isInstrument
        monitor.setAccessibilityLabel("Input monitoring \(t.name)")
        let fx = t.effects.count
        let instrument = t.instrumentName ?? "Dalnok Poly"
        let group = t.group != 0 ? session.groupName(t.group).map { " · " + $0 } ?? "" : ""
        setInput(source: t.isBus ? "BUS" : t.isInstrument ? instrument : "IN \(t.inputChannel + 1)",
                 counts: [fx > 0 ? "\(fx) FX" : "", group.isEmpty ? "" : String(group.dropFirst(3))].filter { !$0.isEmpty }.joined(separator: " · "))
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
        if !gain.tracking { showReadouts(db: db) }
        if !pan.tracking { showReadouts(pan: t.pan) }
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
        selectionLayer.frame = Theme.look.headers == .glass ? CGRect(x: 8, y: 3, width: bounds.width - 12, height: bounds.height - 6)
                                                            : CGRect(x: 0, y: 1, width: bounds.width, height: bounds.height - 2)
        // Short tracks show their name and buttons only; the knobs and input return when there is room.
        let compact = bounds.height < 76
        for v in [gain, pan, gainLabel, panLabel, inputButton] as [NSView] where v.isHidden != compact { v.isHidden = compact }
        if !compact { applyInputTitle() }
        strip.frame = Theme.look.headers == .glass ? CGRect(x: 5, y: 10, width: isSelected ? 3.5 : 2.5, height: bounds.height - 20)
                                                  : CGRect(x: 0, y: 0, width: isSelected ? 5 : 3, height: bounds.height - 1)
        CATransaction.commit()
        if Theme.look.channelStripHeaders {
            let n = nameLabel.frame
            scribble.frame = NSRect(x: n.minX - 7, y: n.midY - 11, width: max(40, arm.frame.minX - 9 - (n.minX - 7)), height: 22)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch Theme.look.headers {
        case .glass:
            // Rows sit on the column's glass: a breath of the track's colour from the left and a hairline between rows.
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState(); ctx.clip(to: CGRect(x: 4, y: 0, width: bounds.width - 4, height: bounds.height))
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [(muted ? Theme.textFaint : color).withAlphaComponent(0.09).cgColor,
                                                                                       color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
                ctx.drawLinearGradient(g, start: CGPoint(x: 4, y: 0), end: CGPoint(x: bounds.width * 0.5, y: 0), options: [])
                ctx.restoreGState()
                Theme.ink(0.07).setFill(); NSRect(x: 14, y: bounds.height - 0.5, width: bounds.width - 22, height: 0.5).fill()
            }
            return
        case .scoreLabels:
            Theme.panelRaised.setFill(); bounds.fill()
            if let ctx = NSGraphicsContext.current?.cgContext {
                // Rules as in a score's system: a hairline between tracks, a fine margin rule after the number column.
                Atelier.rule(ctx, CGPoint(x: 0, y: 0.25), CGPoint(x: bounds.width, y: 0.25), weight: Atelier.hair, color: Theme.ink(0.3))
                Atelier.rule(ctx, CGPoint(x: 30.5, y: 6), CGPoint(x: 30.5, y: bounds.height - 6), weight: Atelier.hair, color: Theme.ink(0.22))
                if isSelected { Atelier.vermilion.setFill(); NSRect(x: bounds.width - 3, y: 0, width: 3, height: bounds.height).fill() }
            }
            return
        case .rows, .channelStrips: break
        }
        (Theme.look.channelStripHeaders ? Analog.faceplate : Theme.panelRaised).setFill()
        bounds.fill()
        if !Theme.look.channelStripHeaders { // a wash of the track colour helps find a track in a long list
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
        nameLabel.backgroundColor = Theme.look.channelStripHeaders ? Theme.hex(0x0D0A08) : Theme.window
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

    // MARK: Mouse: select, double-click rename, drag to reorder, drag the bottom edge to resize

    /// The strip along the bottom edge that resizes the track (and double-clicks back to the default height).
    static let resizeGrip: CGFloat = 5
    private var resizing: (startY: CGFloat, startHeight: CGFloat)?
    private func onResizeGrip(_ p: CGPoint) -> Bool { p.y >= bounds.height - Self.resizeGrip } // flipped
    override func resetCursorRects() {
        addCursorRect(CGRect(x: 0, y: bounds.height - Self.resizeGrip, width: bounds.width, height: Self.resizeGrip), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        column?.select(trackId)
        if onResizeGrip(convert(event.locationInWindow, from: nil)) {
            if event.clickCount == 2 { session.setTrackHeight(trackId, 0); return } // back to the default
            resizing = (event.locationInWindow.y, frame.height)
            session.engine.beginGroup("Track Height") // the whole drag is one undo step
            return
        }
        if event.clickCount == 2, nameLabel.frame.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) {
            beginRename()
            return
        }
        dragStartY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        if let r = resizing {
            let h = (r.startHeight + (r.startY - event.locationInWindow.y)).clamped(to: TrackHeaderRow.minHeight...TrackHeaderRow.maxHeight)
            if abs(h - frame.height) >= 0.5 { session.setTrackHeight(trackId, h.rounded()) }
            return
        }
        guard let start = dragStartY, abs(event.locationInWindow.y - start) > 4 else { return }
        column?.dragUpdate(row: self, windowPoint: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        if resizing != nil { resizing = nil; session.engine.endGroup(); return }
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
    var onDropPlugin: (([String], DalnokTrackId) -> Void)?
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
        let paths = sender.draggingPasteboard.dalnokPluginPaths
        guard !paths.isEmpty, let r = row(atWindow: sender.draggingLocation) else { return false }
        onDropPlugin?(paths, r.trackId)
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
    var onInputMonitorColumn: ((DalnokTrackId) -> Void)?
    var contextMenu: NSMenu?

    func select(_ id: DalnokTrackId) { selectedTrack = id }
    func row(_ id: DalnokTrackId) -> TrackHeaderRow? { rows.first { $0.trackId == id } }

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.look.headers == .glass ? nil : Theme.panel.cgColor
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
        let slot = (0...rows.count).min { abs(session.laneTop($0) - y) < abs(session.laneTop($1) - y) } ?? 0
        dropIndex = slot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insertLine.isHidden = false
        insertLine.frame = CGRect(x: 0, y: session.laneTop(slot) - scrollY - 1, width: rowClip.bounds.width, height: 2)
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
                $0.onInputMonitor = { [weak self] id in self?.onInputMonitorColumn?(id) }
                $0.onToggleStack = { [weak self] id, closed in self?.onToggleStack?(id, closed) }
            }
            if let sel = selectedTrack, !tracks.contains(where: { $0.id == sel }) { selectedTrack = nil }
            needsLayout = true
        }
        for (i, (row, t)) in zip(rows, tracks).enumerated() { row.update(t, index: i) }
        // Heights can change without the rows changing (a resized track): lay the rows out again when they do.
        let heights = tracks.indices.map { session.laneHeight($0) }
        if heights != laidOutHeights { laidOutHeights = heights; needsLayout = true }
    }
    private var laidOutHeights: [CGFloat] = []

    override func layout() {
        super.layout()
        rowClip.frame = CGRect(x: 0, y: Theme.rulerHeight, width: bounds.width - 1, height: max(0, bounds.height - Theme.rulerHeight))
        for (i, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: session.laneTop(i) - scrollY, width: rowClip.bounds.width, height: session.laneHeight(i))
        }
        addButton.frame = CGRect(x: bounds.width - 40, y: 0, width: 34, height: Theme.rulerHeight)
        // The foot fades while more tracks lie below (audit C5), as the lanes beside it do.
        if lowerFade.superview == nil { addSubview(lowerFade, positioned: .above, relativeTo: rowClip) }
        lowerFade.frame = CGRect(x: 0, y: bounds.height - 26, width: bounds.width - 1, height: 26)
        lowerFade.isHidden = Theme.look.headers == .glass || scrollY >= session.lanesHeight - rowClip.bounds.height - 1
    }
    private let lowerFade = LowerEdgeFade()

    override func draw(_ dirtyRect: NSRect) {
        if Theme.look.headers == .glass {
            // Prism: the track list is one pane of glass (the title on a small capsule above it).
            Prism.drawField(in: self, frosted: false)
            Prism.liquidPane(self, CGRect(x: 4, y: 3, width: bounds.width - 4, height: Theme.rulerHeight - 4), radius: (Theme.rulerHeight - 4) / 2)
            Prism.liquidPane(self, CGRect(x: 4, y: Theme.rulerHeight + 4, width: bounds.width - 4, height: bounds.height - Theme.rulerHeight - 8), radius: 14)
            let hiddenCount = session.hiddenCount
            let title = (hiddenCount > 0 ? "TRACKS · \(hiddenCount) HIDDEN" : "TRACKS") as NSString
            title.draw(at: NSPoint(x: 16, y: 7), withAttributes: [.font: Theme.ui(10, .semibold), .foregroundColor: Theme.textDim, .kern: 0.8])
            return
        }
        Theme.panel.setFill()
        bounds.fill()
        let hiddenCount = session.hiddenCount
        if Theme.look.headers == .scoreLabels, let ctx = NSGraphicsContext.current?.cgContext {
            // Atelier: the column's head as a plate's title, "Tracks" in the serif (on the gold band of the umber plate).
            let head = CGRect(x: 0, y: 3, width: bounds.width - 46, height: Theme.rulerHeight - 7)
            let band = !Theme.palette.light
            if band { // the band, and its rules carried on under the + to the divider (audit V3: it stopped short)
                Atelier.gold.setFill(); head.fill()
                Atelier.rule(ctx, CGPoint(x: head.maxX, y: head.minY + 0.5), CGPoint(x: bounds.width, y: head.minY + 0.5), weight: Atelier.medium, color: Atelier.gold)
                Atelier.rule(ctx, CGPoint(x: head.maxX, y: head.maxY - 0.5), CGPoint(x: bounds.width, y: head.maxY - 0.5), weight: Atelier.medium, color: Atelier.gold)
            }
            let t = (hiddenCount > 0 ? "Tracks · \(hiddenCount) hidden" : "Tracks") as NSString
            t.draw(at: NSPoint(x: 12, y: head.midY - 9), withAttributes: [.font: Theme.title(14, .semibold), .foregroundColor: band ? Theme.window : Theme.text])
            if !band {
                Atelier.rule(ctx, CGPoint(x: 8, y: Theme.rulerHeight - 4.5), CGPoint(x: bounds.width - 8, y: Theme.rulerHeight - 4.5), weight: Atelier.medium)
                Atelier.rule(ctx, CGPoint(x: 8, y: Theme.rulerHeight - 2), CGPoint(x: bounds.width - 8, y: Theme.rulerHeight - 2), weight: Atelier.hair)
            }
        } else {
            let title = (hiddenCount > 0 ? "TRACKS · \(hiddenCount) HIDDEN" : "TRACKS") as NSString
            title.draw(at: NSPoint(x: 16, y: 7), withAttributes: [.font: Theme.ui(10, .semibold), .foregroundColor: Theme.textDim, .kern: 0.8])
        }
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
        NSGradient(starting: Theme.ink(0.07), ending: Theme.ink(0))?
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

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

extension NSLayoutConstraint {
    /// The constraint with `priority` set (for inline use in `NSLayoutConstraint.activate`).
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

/// A fade into the panel's colour at a list's foot (more below). Clicks pass through it.
@MainActor
final class LowerEdgeFade: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: Theme.panel.withAlphaComponent(0), ending: Theme.panel.withAlphaComponent(0.92))?.draw(in: bounds, angle: 90)
    }
}
