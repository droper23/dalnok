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
    let master = MasterStrip()
    var onSelect: ((DalnokTrackId) -> Void)?
    var onOpenPlugin: ((DalnokTrackId, Int32) -> Void)?
    var onAddPlugin: ((DalnokTrackId) -> Void)?

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
        master.translatesAutoresizingMaskIntoConstraints = false
        addSubview(master)
        master.fader.onBegin = { [weak self] in self?.session.engine.beginGroup("Master Volume") }
        master.fader.onChange = { [weak self] db in self?.session.setMasterGain(db); self?.master.dbLabel.stringValue = FaderControl.format(db) }
        master.fader.onEnd = { [weak self] in self?.session.engine.endGroup() }
        addBusButton.bezelStyle = .inline
        addBusButton.controlSize = .small
        addBusButton.target = self
        addBusButton.action = #selector(addBus)
        addBusButton.toolTip = "New bus (an aux track that mixes what you route or send to it)"
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Analog.on ? Analog.cheekWidth : 0),
            scroll.trailingAnchor.constraint(equalTo: master.leadingAnchor),
            master.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Analog.on ? -Analog.cheekWidth : 0), master.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            master.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
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
        (Analog.on ? Analog.faceplate : Theme.panelRaised).setFill(); bounds.fill()
        (Analog.on ? NSColor.black.withAlphaComponent(0.22) : Theme.panel.withAlphaComponent(0.55)).setFill(); bounds.fill()
        Theme.hairline.setFill(); NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 1).fill()
        if Analog.on { // walnut end cheeks with a rounded, lit inner edge
            let w = Analog.cheekWidth
            for r in [NSRect(x: 0, y: 0, width: w, height: bounds.height), NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height)] {
                Analog.walnut.setFill(); r.fill()
                NSColor(white: 1, alpha: 0.08).setFill(); NSRect(x: r.minX == 0 ? r.maxX - 2 : r.minX, y: 0, width: 1, height: r.height).fill()
                NSColor(white: 0, alpha: 0.5).setFill(); NSRect(x: r.minX == 0 ? r.maxX - 1 : r.minX + 1, y: 0, width: 1, height: r.height).fill()
            }
        }
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
                s.onOpenPlugin = { [weak self] t, slot in self?.onOpenPlugin?(t, slot) }
                s.onAddPlugin = { [weak self] t in self?.onAddPlugin?(t) }
                stack.addArrangedSubview(s)
            }
            stack.addArrangedSubview(addBusButton)
        }
        for (s, t) in zip(strips, tracks) { s.update(t) }
        if !master.fader.tracking { master.fader.db = session.masterGainDb; master.dbLabel.stringValue = FaderControl.format(session.masterGainDb) }
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
    let routingScroll = NSScrollView()
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
    let insertsStack = NSStackView()
    var onOpenPlugin: ((DalnokTrackId, Int32) -> Void)?
    var onAddPlugin: ((DalnokTrackId) -> Void)?
    private var shownInserts: [Int32] = []

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
        fader.colorCap = true
        fader.onBegin = { [weak self] in guard let self else { return }; self.session.engine.beginGroup("Volume"); AutomationWriter.shared?.touch(self.trackId, 0, true) }
        fader.onChange = { [weak self] db in guard let self else { return }; self.session.setGain(self.trackId, db: db); self.dbLabel.stringValue = FaderControl.format(db) }
        fader.onEnd = { [weak self] in guard let self else { return }; self.session.engine.endGroup(); AutomationWriter.shared?.touch(self.trackId, 0, false) }
        pan.onBegin = { [weak self] in guard let self else { return }; self.session.engine.beginGroup("Pan"); AutomationWriter.shared?.touch(self.trackId, 1, true) }
        pan.onPanChange = { [weak self] p in guard let self else { return }; self.session.setPan(self.trackId, p) }
        pan.onEnd = { [weak self] in guard let self else { return }; self.session.engine.endGroup(); AutomationWriter.shared?.touch(self.trackId, 1, false) }
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

        let panLabel = NSTextField(labelWithString: "PAN")
        panLabel.font = Theme.ui(8, .semibold)
        panLabel.textColor = Theme.textDim
        panLabel.alignment = .center
        let routingDoc = FlippedView()
        let routingStack = NSStackView(views: [insertsStack, sendsStack, addSend])
        routingStack.orientation = .vertical
        routingStack.alignment = .centerX
        routingStack.spacing = 3
        routingDoc.translatesAutoresizingMaskIntoConstraints = false
        routingStack.translatesAutoresizingMaskIntoConstraints = false
        routingDoc.addSubview(routingStack)
        routingScroll.documentView = routingDoc
        routingScroll.hasVerticalScroller = true
        routingScroll.autohidesScrollers = true
        routingScroll.scrollerStyle = .overlay
        routingScroll.drawsBackground = false
        routingScroll.toolTip = "Scroll to see all inserts and sends"
        routingScroll.setAccessibilityLabel("Inserts and sends; scroll for more")
        NSLayoutConstraint.activate([
            routingStack.topAnchor.constraint(equalTo: routingDoc.topAnchor),
            routingStack.leadingAnchor.constraint(equalTo: routingDoc.leadingAnchor),
            routingStack.trailingAnchor.constraint(equalTo: routingDoc.trailingAnchor),
            routingDoc.widthAnchor.constraint(equalTo: routingScroll.contentView.widthAnchor),
            routingDoc.heightAnchor.constraint(greaterThanOrEqualTo: routingStack.heightAnchor),
            routingDoc.heightAnchor.constraint(greaterThanOrEqualTo: routingScroll.contentView.heightAnchor),
        ])
        let faderRow = NSStackView(views: [fader, meter])
        faderRow.spacing = 4
        let chips = NSStackView(views: [arm, mute, solo])
        chips.spacing = 3
        insertsStack.orientation = .vertical
        insertsStack.spacing = 1
        for v in [output, routingScroll, panLabel, pan, faderRow, dbLabel, chips, scribble, name] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: MixerPanel.height - 18),
            output.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            output.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            output.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            routingScroll.topAnchor.constraint(equalTo: output.bottomAnchor, constant: 4),
            routingScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            routingScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            routingScroll.heightAnchor.constraint(equalToConstant: 68),
            panLabel.topAnchor.constraint(equalTo: routingScroll.bottomAnchor, constant: 2),
            panLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            pan.topAnchor.constraint(equalTo: panLabel.bottomAnchor, constant: 1),
            pan.centerXAnchor.constraint(equalTo: centerXAnchor),
            pan.widthAnchor.constraint(equalToConstant: 30), pan.heightAnchor.constraint(equalToConstant: 30),
            faderRow.topAnchor.constraint(equalTo: pan.bottomAnchor, constant: 6),
            faderRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            faderRow.bottomAnchor.constraint(equalTo: dbLabel.topAnchor, constant: -2),
            fader.widthAnchor.constraint(equalToConstant: 44),
            meter.widthAnchor.constraint(equalToConstant: 14),
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
        if Analog.on, let ctx = NSGraphicsContext.current?.cgContext { // a channel module: screwed to the frame
            for p in [CGPoint(x: 7, y: 9), CGPoint(x: bounds.width - 8, y: 9), CGPoint(x: 7, y: bounds.height - 8), CGPoint(x: bounds.width - 8, y: bounds.height - 8)] {
                Analog.screw(ctx, at: p, radius: 2.5)
            }
            NSColor.white.withAlphaComponent(0.05).setFill(); NSRect(x: 0, y: 3, width: 1, height: bounds.height - 3).fill() // left bevel
        }
    }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect?(trackId) }

    func update(_ t: TrackView) {
        color = t.muted ? TrackTint(base: t.color).muted : t.color
        needsDisplay = true
        name.stringValue = t.name
        fader.setAccessibilityLabel("Volume, \(t.name)")
        pan.setAccessibilityLabel("Pan, \(t.name)")
        name.textColor = Analog.on ? (t.muted ? Theme.textFaint : OKLCH.adjust(t.color, dl: 0.2, chromaScale: 0.7))
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
        // Insert slots: each plug-in (click to open its window), then + to add one.
        let ids = t.plugins.map(\.id)
        if ids != shownInserts || insertsStack.arrangedSubviews.isEmpty {
            shownInserts = ids
            insertsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for p in t.plugins {
                let b = slotButton((p.instrument ? "♪ " : "") + p.name, dim: !p.loaded)
                b.tag = Int(p.id)
                b.action = #selector(openInsert(_:))
                b.toolTip = p.loaded ? "Open \(p.name)" : "\(p.name) isn't installed: bypassed, settings kept"
                insertsStack.addArrangedSubview(b)
            }
            if !t.isBus || true {
                let add = slotButton("+ Insert", dim: true)
                add.action = #selector(addInsert)
                add.toolTip = "Add a plug-in to this channel"
                insertsStack.addArrangedSubview(add)
            }
        }
        // Output: the master or any bus but this one.
        let buses = session.buses.filter { $0.id != t.id }
        let titles = ["Master"] + buses.map(\.name)
        if output.itemTitles != titles {
            output.removeAllItems()
            for title in titles { output.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: "")) }
        }
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

    private func slotButton(_ title: String, dim: Bool) -> NSButton {
        let b = NSButton(title: title, target: self, action: nil)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = (dim ? Theme.hex(0x000000, 0.25) : Theme.hex(0x000000, 0.45)).cgColor
        b.layer?.cornerRadius = 3
        b.font = Theme.ui(9.5, .medium)
        b.contentTintColor = dim ? Theme.textDim : Theme.text
        b.lineBreakMode = .byTruncatingTail
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 16).isActive = true
        b.widthAnchor.constraint(equalToConstant: ChannelStrip.width - 8).isActive = true
        return b
    }
    @objc func openInsert(_ sender: NSButton) { onOpenPlugin?(trackId, Int32(sender.tag)) }
    @objc func addInsert() { onSelect?(trackId); onAddPlugin?(trackId) }

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

/// The master: fader, meter and level at the right end of the mixer.
@MainActor
final class MasterStrip: NSView {
    let fader = FaderControl()
    let meter = MeterView()
    let dbLabel = NSTextField(labelWithString: "")
    let needle = NeedleMeter() // Warm Analog only
    private let name = NSTextField(labelWithString: "Master")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fader.vertical = true
        fader.colorCap = true
        fader.tint = Theme.accent
        fader.setAccessibilityLabel("Master volume")
        meter.vertical = true
        dbLabel.font = Theme.mono(10); dbLabel.textColor = Theme.textDim; dbLabel.alignment = .center
        name.font = Theme.ui(11.5, .semibold); name.textColor = Theme.accent; name.alignment = .center
        let row = NSStackView(views: [fader, meter])
        row.spacing = 4
        for v in [needle, row, dbLabel, name] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        needle.isHidden = !Analog.on
        needle.setAccessibilityLabel("Master needle meter")
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Analog.on ? 112 : 86),
            needle.topAnchor.constraint(equalTo: topAnchor, constant: 10), needle.centerXAnchor.constraint(equalTo: centerXAnchor),
            needle.widthAnchor.constraint(equalToConstant: 100), needle.heightAnchor.constraint(equalToConstant: Analog.on ? 62 : 0),
            row.topAnchor.constraint(equalTo: needle.bottomAnchor, constant: Analog.on ? 10 : 20), row.centerXAnchor.constraint(equalTo: centerXAnchor),
            fader.widthAnchor.constraint(equalToConstant: 44), meter.widthAnchor.constraint(equalToConstant: 16),
            row.bottomAnchor.constraint(equalTo: dbLabel.topAnchor, constant: -2),
            dbLabel.centerXAnchor.constraint(equalTo: centerXAnchor), dbLabel.bottomAnchor.constraint(equalTo: name.topAnchor, constant: -10),
            name.centerXAnchor.constraint(equalTo: centerXAnchor), name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (Analog.on ? Analog.faceplate : Theme.panelRaised).setFill(); bounds.fill()
        Theme.accent.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 3).fill()
        Theme.separator.setFill(); NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
}
