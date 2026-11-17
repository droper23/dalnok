// Mixer (View ▸ Mixer, X): a channel strip per track and bus, like a console. Each strip: output (master or a
// bus), sends with levels (⌥-click a send knob for pre/post), pan, fader with meter, mute/solo/arm, and name.
// Buses are created from the + strip or Track ▸ New Bus. Everything goes through undoable engine commands.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class MixerPanel: NSView {
    static let height: CGFloat = 360
    let session: Session
    private(set) var strips: [ChannelStrip] = []
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let addBusButton = NSButton(title: "+ Bus", target: nil, action: nil)
    var onSelect: ((DalnokTrackId) -> Void)?

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addBusButton.bezelStyle = .inline
        addBusButton.controlSize = .small
        addBusButton.target = self
        addBusButton.action = #selector(addBus)
        addBusButton.toolTip = "New bus (an aux track that mixes what you route or send to it)"
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.topAnchor.constraint(equalTo: doc.topAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            doc.widthAnchor.constraint(greaterThanOrEqualTo: stack.widthAnchor),
            doc.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])
        setAccessibilityLabel("Mixer")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        (Analog.on ? Theme.hex(0x15100C) : Theme.panel).setFill(); bounds.fill()
        Theme.separator.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func addBus() { session.addBus() }

    /// Rebuilds strips when tracks are added, removed or reordered; otherwise updates values in place.
    func rebuild() {
        let tracks = session.tracks
        if strips.map(\.trackId) != tracks.map(\.id) {
            strips.forEach { $0.removeFromSuperview() }
            addBusButton.removeFromSuperview()
            strips = tracks.map { ChannelStrip(session: session, trackId: $0.id) }
            for s in strips {
                s.onSelect = { [weak self] id in self?.onSelect?(id) }
                stack.addArrangedSubview(s)
            }
            stack.addArrangedSubview(addBusButton)
        }
        for (s, t) in zip(strips, tracks) { s.update(t) }
    }

    func pushMeters(_ read: (DalnokTrackId) -> (Float, Float)) {
        for s in strips { let (l, r) = read(s.trackId); s.meter.push(l, r) }
    }
    func select(_ id: DalnokTrackId?) { strips.forEach { $0.isSelected = $0.trackId == id } }
}

@MainActor
final class ChannelStrip: NSView {
    static let width: CGFloat = 92
    let session: Session
    let trackId: DalnokTrackId
    let output = NSPopUpButton(frame: .zero, pullsDown: false)
    let sendsStack = NSStackView()
    let addSend = NSPopUpButton(frame: .zero, pullsDown: true)
    let pan = PanKnob()
    let fader = FaderControl()
    let meter = MeterView()
    let dbLabel = NSTextField(labelWithString: "")
    let mute = ToggleChip("M", on: Theme.muteOn, onText: .white, help: "Mute")
    let solo = ToggleChip("S", on: Theme.soloOn, onText: Theme.hex(0x1A1400), help: "Solo")
    let arm = ToggleChip("R", on: Theme.recordOn, onText: .white, help: "Record Enable")
    let name = NSTextField(labelWithString: "")
    private let scribble = ScribbleStrip()
    private var color = NSColor.gray
    var onSelect: ((DalnokTrackId) -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private var sendKnobs: [(bus: DalnokTrackId, knob: GainKnob, pre: Bool)] = []

    init(session: Session, trackId: DalnokTrackId) {
        self.session = session
        self.trackId = trackId
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        output.controlSize = .small
        output.font = Theme.ui(10, .medium)
        output.target = self
        output.action = #selector(outputChosen)
        output.toolTip = "Output: where this channel goes after its fader"
        addSend.controlSize = .small
        addSend.font = Theme.ui(10, .medium)
        addSend.isBordered = false
        addSend.toolTip = "Add a send to a bus"
        sendsStack.orientation = .vertical
        sendsStack.alignment = .centerX
        sendsStack.spacing = 2
        fader.vertical = true
        fader.onBegin = { [weak self] in self?.session.engine.beginGroup("Volume") }
        fader.onChange = { [weak self] db in guard let self else { return }; self.session.setGain(self.trackId, db: db); self.dbLabel.stringValue = FaderControl.format(db) }
        fader.onEnd = { [weak self] in self?.session.engine.endGroup() }
        pan.onBegin = { [weak self] in self?.session.engine.beginGroup("Pan") }
        pan.onPanChange = { [weak self] p in guard let self else { return }; self.session.setPan(self.trackId, p) }
        pan.onEnd = { [weak self] in self?.session.engine.endGroup() }
        mute.onToggle = { [weak self] on in guard let self else { return }; self.session.setMute(self.trackId, on) }
        solo.onToggle = { [weak self] on in guard let self else { return }; self.session.setSolo(self.trackId, on) }
        arm.onToggle = { [weak self] on in guard let self else { return }; self.session.setArmed(self.trackId, on) }
        meter.vertical = true
        dbLabel.font = Theme.mono(10)
        dbLabel.textColor = Theme.textDim
        dbLabel.alignment = .center
        name.font = Analog.on ? NSFont.systemFont(ofSize: 11.5, weight: .semibold, width: .condensed) : Theme.ui(11.5, .semibold)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail

        let faderRow = NSStackView(views: [fader, meter])
        faderRow.spacing = 4
        let chips = NSStackView(views: [arm, mute, solo])
        chips.spacing = 3
        for v in [output, sendsStack, addSend, pan, faderRow, dbLabel, chips, scribble, name] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: MixerPanel.height - 18),
            output.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            output.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            output.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sendsStack.topAnchor.constraint(equalTo: output.bottomAnchor, constant: 4),
            sendsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            sendsStack.widthAnchor.constraint(equalTo: widthAnchor, constant: -8),
            addSend.topAnchor.constraint(equalTo: sendsStack.bottomAnchor, constant: 2),
            addSend.centerXAnchor.constraint(equalTo: centerXAnchor),
            pan.topAnchor.constraint(equalTo: addSend.bottomAnchor, constant: 6),
            pan.centerXAnchor.constraint(equalTo: centerXAnchor),
            pan.widthAnchor.constraint(equalToConstant: 30), pan.heightAnchor.constraint(equalToConstant: 30),
            faderRow.topAnchor.constraint(equalTo: pan.bottomAnchor, constant: 6),
            faderRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            faderRow.bottomAnchor.constraint(equalTo: dbLabel.topAnchor, constant: -2),
            fader.widthAnchor.constraint(equalToConstant: 30),
            meter.widthAnchor.constraint(equalToConstant: 8),
            dbLabel.bottomAnchor.constraint(equalTo: chips.topAnchor, constant: -4),
            dbLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            chips.bottomAnchor.constraint(equalTo: scribble.topAnchor, constant: -6),
            chips.centerXAnchor.constraint(equalTo: centerXAnchor),
            scribble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            scribble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            scribble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            scribble.heightAnchor.constraint(equalToConstant: 22),
            name.centerYAnchor.constraint(equalTo: scribble.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: scribble.leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: scribble.trailingAnchor, constant: -4),
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        (Analog.on ? Analog.faceplate : Theme.panelRaised).setFill()
        bounds.fill()
        if isSelected { Theme.selectedHeader.setFill(); bounds.fill() }
        color.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 3).fill() // track color along the top
        Theme.separator.setFill(); NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect?(trackId) }

    func update(_ t: TrackView) {
        color = t.muted ? TrackTint(base: t.color).muted : t.color
        needsDisplay = true
        name.stringValue = t.name
        name.textColor = Analog.on ? (t.muted ? Theme.hex(0x5E554A) : OKLCH.adjust(t.color, dl: 0.2, chromaScale: 0.7))
                                   : (t.muted ? Theme.textDim : Theme.text)
        scribble.color = t.color
        scribble.lit = !t.muted
        scribble.isHidden = !Analog.on
        if !fader.tracking { fader.db = t.gainDb; dbLabel.stringValue = FaderControl.format(t.gainDb) }
        fader.tint = t.color
        if !pan.tracking { pan.pan = t.pan }
        pan.tint = t.color
        mute.isOn = t.muted
        solo.isOn = t.solo
        arm.isOn = t.armed
        arm.isHidden = t.isBus
        // Output: the master or any bus but this one.
        let buses = session.buses.filter { $0.id != t.id }
        let titles = ["Master"] + buses.map(\.name)
        if output.itemTitles != titles { output.removeAllItems(); output.addItems(withTitles: titles) }
        for (i, b) in buses.enumerated() { output.item(at: i + 1)?.tag = Int(b.id) }
        output.item(at: 0)?.tag = 0
        output.selectItem(withTag: Int(t.output))
        // Sends: one knob per send, then a menu to add one.
        if sendKnobs.map(\.bus) != t.sends.map(\.bus) || zip(sendKnobs, t.sends).contains(where: { $0.pre != $1.pre }) {
            sendsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            sendKnobs = []
            for snd in t.sends { sendsStack.addArrangedSubview(sendRow(snd)) }
        }
        for (k, snd) in zip(sendKnobs, t.sends) where !k.knob.tracking { k.knob.db = snd.db }
        addSend.removeAllItems()
        addSend.addItem(withTitle: "+ Send")
        let candidates = session.buses.filter { b in b.id != t.id && !t.sends.contains { $0.bus == b.id } }
        for b in candidates {
            addSend.addItem(withTitle: "Send to \(b.name)")
            addSend.lastItem?.tag = Int(b.id)
            addSend.lastItem?.target = self
            addSend.lastItem?.action = #selector(addSendChosen(_:))
        }
        addSend.isHidden = candidates.isEmpty
    }

    private func sendRow(_ snd: DalnokSend) -> NSView {
        let knob = GainKnob()
        knob.translatesAutoresizingMaskIntoConstraints = false
        knob.widthAnchor.constraint(equalToConstant: 22).isActive = true
        knob.heightAnchor.constraint(equalToConstant: 22).isActive = true
        knob.db = snd.db
        knob.tint = session.track(snd.bus)?.color ?? Theme.accent
        let bus = snd.bus
        knob.onBegin = { [weak self] in self?.session.engine.beginGroup("Send") }
        knob.onGainChange = { [weak self] db in
            guard let self, let s = self.session.track(self.trackId)?.sends.first(where: { $0.bus == bus }) else { return }
            self.session.setSend(self.trackId, bus, db: db, pre: s.pre)
        }
        knob.onEnd = { [weak self] in self?.session.engine.endGroup() }
        let label = NSTextField(labelWithString: (snd.pre ? "pre " : "") + (session.track(bus)?.name ?? "Bus"))
        label.font = Theme.ui(9.5, .medium)
        label.textColor = snd.pre ? Theme.accent : Theme.textDim
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = "Send to \(session.track(bus)?.name ?? "bus") (\(snd.pre ? "pre" : "post")-fader). Right-click for options."
        let row = SendRow(views: [knob, label])
        row.spacing = 3
        row.menuProvider = { [weak self] in self?.sendMenu(bus: bus, pre: snd.pre) }
        sendKnobs.append((bus, knob, snd.pre))
        return row
    }

    private func sendMenu(bus: DalnokTrackId, pre: Bool) -> NSMenu {
        let m = NSMenu()
        let toggle = NSMenuItem(title: pre ? "Make Post-Fader" : "Make Pre-Fader", action: #selector(togglePre(_:)), keyEquivalent: "")
        toggle.tag = Int(bus); toggle.target = self
        let remove = NSMenuItem(title: "Remove Send", action: #selector(removeSendChosen(_:)), keyEquivalent: "")
        remove.tag = Int(bus); remove.target = self
        m.addItem(toggle); m.addItem(remove)
        return m
    }

    @objc func outputChosen() {
        let bus = DalnokTrackId(output.selectedTag())
        if !session.setOutput(trackId, bus) { session.onMessage?("That output would feed the bus back into itself") }
    }
    @objc func addSendChosen(_ sender: NSMenuItem) {
        if !session.setSend(trackId, DalnokTrackId(sender.tag), db: 0, pre: false) {
            session.onMessage?("That send would feed the bus back into itself")
        }
    }
    @objc func togglePre(_ sender: NSMenuItem) {
        guard let s = session.track(trackId)?.sends.first(where: { $0.bus == DalnokTrackId(sender.tag) }) else { return }
        session.setSend(trackId, s.bus, db: s.db, pre: !s.pre)
    }
    @objc func removeSendChosen(_ sender: NSMenuItem) { session.removeSend(trackId, DalnokTrackId(sender.tag)) }
}

/// A send's row; right-click offers pre/post and removal.
final class SendRow: NSStackView {
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
