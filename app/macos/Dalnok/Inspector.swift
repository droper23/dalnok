// View ▸ Inspector (⌥I): the selected track's channel at the window's right edge, in the spirit of Logic's Inspector.
// Input, output and Input Monitoring; volume and pan as large dials with read-outs; mute, solo, record and phase
// invert; the inserts numbered as plates ("01 · EQ": click opens, the lamp bypasses); sends lettered A, B, … with
// a level and its dB. A live level meter sits at the foot.
// Every control goes through the same engine calls as the mixer (fader and knob drags are one undo step each), and
// everything shown is re-read from the session when the selection, the model or a parameter changes.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class InspectorPanel: SidePanelView {
    static let defaultWidth: CGFloat = 240
    static let widthRange: ClosedRange<CGFloat> = 210...360
    static var storedWidth: CGFloat {
        get { let w = UserDefaults.standard.double(forKey: "inspectorWidth"); return w > 0 ? min(max(w, widthRange.lowerBound), widthRange.upperBound) : defaultWidth }
        set { UserDefaults.standard.set(Double(newValue), forKey: "inspectorWidth") }
    }
    let session: Session
    /// The track shown (the selected track); nil shows an empty note.
    var track: DalnokTrackId? { didSet { if track != oldValue { reload() } } }
    var onOpenPlugin: ((DalnokTrackId, Int32) -> Void)?
    var onAddPlugin: ((DalnokTrackId) -> Void)?
    /// A plug-in dragged from the Library or the browser and dropped anywhere on the Inspector: insert it last.
    var onDropPlugin: ((String, DalnokTrackId) -> Void)?
    /// The recording device's inputs ("Input 1 — Scarlett Solo"…); empty when there is none.
    var inputNames: () -> [String] = { [] }
    let resizeEdge = PanelResizeEdge(direction: -1)

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString: "Select a track to see its channel here.")
    // Header
    private let swatch = NSView()
    private let number = NSTextField(labelWithString: "")
    let nameLabel = NSTextField(labelWithString: "")
    // Track
    let input = RuledPopUpButton(frame: .zero, pullsDown: false)
    let output = RuledPopUpButton(frame: .zero, pullsDown: false)
    let monitor = RuledPopUpButton(frame: .zero, pullsDown: false)
    private var inputRow: NSView!, monitorRow: NSView!
    // Channel
    let volume = GainKnob()
    let pan = PanKnob()
    let volumeValue = NSTextField(labelWithString: "")
    let panValue = NSTextField(labelWithString: "")
    let mute = ToggleChip("M", on: Theme.muteOn, onText: Theme.onState(Theme.muteOn), help: "Mute")
    let solo = ToggleChip("S", on: Theme.soloOn, onText: Theme.onState(Theme.soloOn), help: "Solo")
    let arm = ToggleChip("R", on: Theme.recordOn, onText: Theme.onState(Theme.recordOn), help: "Record Enable")
    let phase = ToggleChip("Ø", on: Theme.cycle, onText: Theme.onState(Theme.cycle), help: "Phase Invert")
    // Inserts and sends
    let insertsStack = NSStackView()
    let sendsStack = NSStackView()
    let addSend = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var insertRows: [InspectorInsertRow] = []
    private(set) var sendRows: [InspectorSendRow] = []
    let meter = MeterView()
    /// Atelier: Fig. 3, the track's signal path, at the foot.
    let figure = InspectorFigure()
    private var shown: Int?

    init(session: Session) {
        self.session = session
        super.init(edge: .left)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Inspector")
        build()
        reload()
        registerForDraggedTypes([.dalnokPlugin])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        track != nil && sender.draggingPasteboard.string(forType: .dalnokPlugin) != nil ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let t = track, let path = sender.draggingPasteboard.string(forType: .dalnokPlugin) else { return false }
        onDropPlugin?(path, t)
        return true
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.look.mixer == .instrument ? Theme.title(12) : Theme.ui(11)
        l.textColor = Theme.textDim
        return l
    }
    private func popupRow(_ title: String, _ popup: NSPopUpButton, help: String) -> NSView {
        popup.controlSize = .small
        popup.font = Theme.ui(11)
        popup.toolTip = help
        popup.setAccessibilityLabel(title)
        let l = label(title)
        l.widthAnchor.constraint(equalToConstant: 58).isActive = true
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [l, popup])
        row.spacing = 6
        row.distribution = .fill
        return row
    }
    private func dialColumn(_ title: String, _ knob: RotaryKnob, _ value: NSTextField) -> NSView {
        knob.translatesAutoresizingMaskIntoConstraints = false
        knob.widthAnchor.constraint(equalToConstant: Illustrated.size(58, 1.35)).isActive = true
        knob.heightAnchor.constraint(equalToConstant: Illustrated.size(58, 1.35)).isActive = true
        value.font = Theme.look.mixer == .instrument ? Theme.title(12.5) : Theme.mono(11)
        value.textColor = Theme.text
        value.alignment = .center
        let t = label(title)
        t.alignment = .center
        let col = NSStackView(views: [t, knob, value])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 3
        return col
    }

    private func build() {
        resizeEdge.currentWidth = { [weak self] in self?.bounds.width ?? InspectorPanel.defaultWidth }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 14, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(resizeEdge)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            resizeEdge.leadingAnchor.constraint(equalTo: leadingAnchor), resizeEdge.topAnchor.constraint(equalTo: topAnchor),
            resizeEdge.bottomAnchor.constraint(equalTo: bottomAnchor), resizeEdge.widthAnchor.constraint(equalToConstant: 5),
        ])

        // Header: the track's colour, number and name.
        swatch.wantsLayer = true
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 12).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 12).isActive = true
        number.font = Theme.look.mixer == .instrument ? Theme.note(15) : Theme.mono(12)
        number.textColor = Theme.look.mixer == .instrument ? Atelier.gold : Theme.textDim
        nameLabel.font = Theme.title(17, .semibold)
        nameLabel.textColor = Theme.text
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [swatch, number, nameLabel])
        header.spacing = 7
        empty.font = Theme.look.mixer == .instrument ? Theme.note(13) : Theme.ui(12)
        empty.textColor = Theme.textDim

        // Track
        output.target = self; output.action = #selector(outputChosen)
        input.target = self; input.action = #selector(inputChosen)
        monitor.target = self; monitor.action = #selector(monitorChosen)
        monitor.addItems(withTitles: ["Off", "Input"])
        inputRow = popupRow("Input", input, help: "The recording input this track records and monitors")
        monitorRow = popupRow("Monitor", monitor, help: "Input Monitoring: hear the input through this channel, recording or not")
        let outputRow = popupRow("Output", output, help: "Where this channel goes after its fader")

        // Channel: dials with read-outs, then the state buttons.
        volume.onBegin = { [weak self] in guard let self, let t = self.track else { return }; self.session.engine.beginGroup("Volume"); AutomationWriter.shared?.touch(t, 0, true) }
        volume.onGainChange = { [weak self] db in guard let self, let t = self.track else { return }; self.session.setGain(t, db: db); self.volumeValue.stringValue = FaderControl.format(db) }
        volume.onEnd = { [weak self] in guard let self, let t = self.track else { return }; self.session.engine.endGroup(); AutomationWriter.shared?.touch(t, 0, false) }
        pan.onBegin = { [weak self] in guard let self, let t = self.track else { return }; self.session.engine.beginGroup("Pan"); AutomationWriter.shared?.touch(t, 1, true) }
        pan.onPanChange = { [weak self] p in guard let self, let t = self.track else { return }; self.session.setPan(t, p); self.panValue.stringValue = PanKnob.format(Double(p)) }
        pan.onEnd = { [weak self] in guard let self, let t = self.track else { return }; self.session.engine.endGroup(); AutomationWriter.shared?.touch(t, 1, false) }
        mute.onToggle = { [weak self] on in guard let self, let t = self.track else { return }; self.session.setMute(t, on) }
        solo.onToggle = { [weak self] on in guard let self, let t = self.track else { return }; self.session.setSolo(t, on) }
        arm.onToggle = { [weak self] on in guard let self, let t = self.track else { return }; self.session.setArmed(t, on) }
        phase.onToggle = { [weak self] on in guard let self, let t = self.track else { return }; self.session.setPhaseInvert(t, on) }
        let dials = NSStackView(views: [dialColumn("Volume", volume, volumeValue), dialColumn("Pan", pan, panValue)])
        dials.distribution = .fillEqually
        dials.spacing = 10
        let chips = NSStackView(views: [mute, solo, arm, phase])
        chips.distribution = .equalSpacing
        chips.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)

        insertsStack.orientation = .vertical
        insertsStack.alignment = .leading
        insertsStack.spacing = 3
        sendsStack.orientation = .vertical
        sendsStack.alignment = .leading
        sendsStack.spacing = 4
        addSend.controlSize = .small
        addSend.font = Theme.ui(11)
        addSend.isBordered = false
        addSend.setAccessibilityLabel("Add send")
        addSend.toolTip = "Add a send to a bus"

        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.heightAnchor.constraint(equalToConstant: 12).isActive = true
        meter.setAccessibilityLabel("Level")

        let trackHead = PanelHead("Track"), channelHead = PanelHead("Channel"), insertsHead = PanelHead("Inserts"), sendsHead = PanelHead("Sends")
        let levelHead = PanelHead("Level")
        for v in [header, empty, trackHead, inputRow!, outputRow, monitorRow!, channelHead, dials, chips, insertsHead, insertsStack,
                  sendsHead, sendsStack, addSend, levelHead, meter, figure] as [NSView] {
            stack.addArrangedSubview(v)
        }
        figure.translatesAutoresizingMaskIntoConstraints = false
        figureHeight = figure.heightAnchor.constraint(equalToConstant: 0)
        figureHeight.isActive = true
        stack.setCustomSpacing(22, after: meter)
        // Full-width rows (the stack's leading alignment would otherwise size them to fit).
        for v in [header, trackHead, inputRow!, outputRow, monitorRow!, channelHead, dials, chips, insertsHead, insertsStack, sendsHead, sendsStack, levelHead, meter, figure] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
        empty.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -26).isActive = true
        stack.setCustomSpacing(12, after: header)
        stack.setCustomSpacing(12, after: monitorRow)
        stack.setCustomSpacing(12, after: chips)
        stack.setCustomSpacing(12, after: insertsStack)
        stack.setCustomSpacing(12, after: addSend)
        sectionViews = [trackHead, inputRow!, outputRow, monitorRow!, channelHead, dials, chips, insertsHead, insertsStack, sendsHead, sendsStack, addSend, levelHead, meter, header, figure]
    }
    private var sectionViews: [NSView] = []
    private var figureHeight: NSLayoutConstraint!
    /// The figure takes only the room left below the sections (never makes the panel scroll), and none under 120 pt.
    override func layout() {
        super.layout()
        guard figureHeight != nil else { return }
        let eligible = Theme.look.mixer == .instrument && empty.isHidden
        let used = stack.fittingSize.height - (figure.isHidden ? 0 : figureHeight.constant + 30) // 30: the spacing above it
        let spare = bounds.height - used - 30 - 8
        let h: CGFloat = eligible && spare >= 120 ? min(spare, 190) : 0
        if abs(figureHeight.constant - h) > 0.5 || figure.isHidden != (h == 0) {
            figureHeight.constant = h; figure.isHidden = h == 0; needsLayout = true
        }
    }

    // MARK: Refresh (everything is read back from the session)

    /// After a structural change or a new selection: rebuild what changed and refresh every value.
    func reload() {
        guard let id = track, let t = session.track(id) else {
            sectionViews.forEach { $0.isHidden = true }
            empty.isHidden = false
            shown = nil
            return
        }
        sectionViews.forEach { $0.isHidden = false }
        empty.isHidden = true
        let index = session.tracks.firstIndex { $0.id == id } ?? 0
        number.stringValue = String(format: Theme.look.mixer == .instrument ? "%02d" : "%d", index + 1)
        nameLabel.stringValue = t.name
        swatch.layer?.backgroundColor = t.color.cgColor
        volume.tint = t.color; pan.tint = t.color
        volume.setAccessibilityLabel("Volume, \(t.name)")
        pan.setAccessibilityLabel("Pan, \(t.name)")
        // Input (audio tracks), monitoring (audio tracks), output (all).
        let audio = !t.isBus && !t.isInstrument
        inputRow.isHidden = !audio
        monitorRow.isHidden = !audio
        if audio {
            var names = inputNames()
            if names.isEmpty { names = ["Input 1", "Input 2"] }
            while names.count <= Int(t.inputChannel) { names.append("Input \(names.count + 1)") }
            if input.itemTitles != names { input.removeAllItems(); input.addItems(withTitles: names) }
            input.selectItem(at: Int(t.inputChannel))
            monitor.selectItem(at: t.inputMonitor ? 1 : 0)
        }
        let buses = session.buses.filter { $0.id != t.id }
        let titles = ["Master"] + buses.map(\.name)
        if output.itemTitles != titles { output.removeAllItems(); output.addItems(withTitles: titles) }
        output.item(at: 0)?.tag = 0
        for (i, b) in buses.enumerated() { output.item(at: i + 1)?.tag = Int(b.id) }
        output.selectItem(withTag: Int(t.output))
        arm.isHidden = t.isBus
        phase.isOn = t.phaseInvert
        // Inserts and sends: rebuilt only when they change, so a click mid-gesture never loses its row.
        var h = Hasher()
        h.combine(id)
        for p in t.plugins where !p.instrument { h.combine(p.id); h.combine(p.name); h.combine(p.loaded) }
        for s in t.sends { h.combine(s.bus); h.combine(s.pre) }
        for b in session.buses { h.combine(b.id); h.combine(b.name) }
        let sig = h.finalize()
        if sig != shown {
            shown = sig
            rebuildRows(t)
        }
        needsLayout = true // the figure's room is decided in layout()
        figure.path = InspectorFigure.Path(track: t.name, input: audio ? (input.titleOfSelectedItem.map { $0.components(separatedBy: " — ").first ?? $0 } ?? "In") : (t.isBus ? "Sends" : "Instrument"),
                                           output: output.titleOfSelectedItem ?? "Master",
                                           inserts: t.effects.map { ($0.name, $0.bypassed) })
        updateParameters()
    }

    private func rebuildRows(_ t: TrackView) {
        insertsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        insertRows = []
        for (i, p) in t.effects.enumerated() {
            let row = InspectorInsertRow(number: i + 1, plugin: p)
            row.onOpen = { [weak self] slot in self?.onOpenPlugin?(t.id, slot) }
            row.onBypass = { [weak self] slot, on in self?.session.setPluginBypassed(t.id, slot, on) }
            insertsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: insertsStack.widthAnchor).isActive = true
            insertRows.append(row)
        }
        let add = FocusableButton(title: t.effects.isEmpty ? "+ Add an insert" : "+ Insert", target: self, action: #selector(addInsert))
        add.isBordered = false
        add.font = Theme.look.mixer == .instrument ? Theme.note(12) : Theme.ui(11)
        add.contentTintColor = Theme.textDim
        add.toolTip = "Add a plug-in to this channel"
        insertsStack.addArrangedSubview(add)

        sendsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sendRows = []
        for (i, s) in t.sends.enumerated() {
            let busName = session.track(s.bus)?.name ?? "Bus"
            let row = InspectorSendRow(letter: Self.letter(i), bus: s.bus, name: busName, pre: s.pre)
            row.fader.onBegin = { [weak self] in self?.session.engine.beginGroup("Send") }
            row.fader.onChange = { [weak self, weak row] db in
                guard let self, let cur = self.session.track(t.id)?.sends.first(where: { $0.bus == s.bus }) else { return }
                self.session.setSend(t.id, s.bus, db: db, pre: cur.pre)
                row?.value.stringValue = FaderControl.format(db)
            }
            row.fader.onEnd = { [weak self] in self?.session.engine.endGroup() }
            row.menuProvider = { [weak self] in self?.sendMenu(track: t.id, bus: s.bus, pre: s.pre) }
            sendsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sendsStack.widthAnchor).isActive = true
            sendRows.append(row)
        }
        let candidates = session.buses.filter { b in b.id != t.id && !t.sends.contains { $0.bus == b.id } }
        addSend.removeAllItems()
        addSend.addItem(withTitle: candidates.isEmpty ? (session.buses.isEmpty ? "No buses yet (Track ▸ New Bus)" : "Every bus has a send") : "+ Send")
        for b in candidates {
            addSend.addItem(withTitle: "Send to \(b.name)")
            addSend.lastItem?.tag = Int(b.id)
            addSend.lastItem?.target = self
            addSend.lastItem?.action = #selector(addSendChosen(_:))
        }
        addSend.isEnabled = !candidates.isEmpty
    }

    /// A, B, … Z, then AA, AB…
    static func letter(_ i: Int) -> String {
        let a = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return i < 26 ? String(a[i]) : String(a[i / 26 - 1]) + String(a[i % 26])
    }

    /// Scalars only (gain, pan, mute, solo, arm, phase, send levels, bypass): the per-frame path while things move.
    func updateParameters() {
        guard let id = track, let t = session.track(id) else { return }
        if !volume.tracking { volume.db = t.gainDb; volumeValue.stringValue = FaderControl.format(t.gainDb) }
        if !pan.tracking { pan.pan = t.pan; panValue.stringValue = PanKnob.format(Double(t.pan)) }
        mute.isOn = t.muted
        solo.isOn = t.solo
        arm.isOn = t.armed
        phase.isOn = t.phaseInvert
        for (row, s) in zip(sendRows, t.sends) where !row.fader.tracking {
            row.fader.db = s.db; row.value.stringValue = FaderControl.format(s.db)
        }
        for (row, p) in zip(insertRows, t.effects) { row.bypass.isOn = p.bypassed }
    }

    /// Playback: the automated value at the playhead (as the mixer shows it).
    func showAutomated(volume v: Float?, pan p: Float?) {
        if let v, !volume.tracking { volume.db = v; volumeValue.stringValue = FaderControl.format(v) }
        if let p, !pan.tracking { pan.pan = p; panValue.stringValue = PanKnob.format(Double(p)) }
    }

    // MARK: Actions

    @objc private func outputChosen() {
        guard let t = track else { return }
        if !session.setOutput(t, DalnokTrackId(output.selectedTag())) { session.onMessage?("That output would feed the bus back into itself"); reload() }
    }
    @objc private func inputChosen() { if let t = track { session.setInput(t, Int32(input.indexOfSelectedItem)) } }
    @objc private func monitorChosen() { if let t = track { session.setInputMonitor(t, monitor.indexOfSelectedItem == 1) } }
    @objc private func addInsert() { if let t = track { onAddPlugin?(t) } }
    @objc private func addSendChosen(_ sender: NSMenuItem) {
        guard let t = track else { return }
        if !session.setSend(t, DalnokTrackId(sender.tag), db: 0, pre: false) { session.onMessage?("That send would feed the bus back into itself") }
    }
    private func sendMenu(track: DalnokTrackId, bus: DalnokTrackId, pre: Bool) -> NSMenu {
        let m = NSMenu()
        let toggle = NSMenuItem(title: pre ? "Make Post-Fader" : "Make Pre-Fader", action: #selector(togglePre(_:)), keyEquivalent: "")
        toggle.tag = Int(bus); toggle.target = self
        let remove = NSMenuItem(title: "Remove Send", action: #selector(removeSend(_:)), keyEquivalent: "")
        remove.tag = Int(bus); remove.target = self
        m.addItem(toggle); m.addItem(remove)
        return m
    }
    @objc private func togglePre(_ sender: NSMenuItem) {
        guard let t = track, let s = session.track(t)?.sends.first(where: { $0.bus == DalnokTrackId(sender.tag) }) else { return }
        session.setSend(t, s.bus, db: s.db, pre: !s.pre)
    }
    @objc private func removeSend(_ sender: NSMenuItem) { if let t = track { session.removeSend(t, DalnokTrackId(sender.tag)) } }
}

/// "01 · EQ": click opens the plug-in; the lamp at the right bypasses it (one undo step).
@MainActor
final class InspectorInsertRow: NSView {
    let slot: Int32
    let open: FocusableButton
    let bypass = ToggleChip("B", on: Theme.textDim, onText: Theme.onState(Theme.textDim), help: "Bypass")
    var onOpen: ((Int32) -> Void)?
    var onBypass: ((Int32, Bool) -> Void)?
    init(number: Int, plugin p: TrackView.Plugin) {
        slot = p.id
        let atelier = Theme.look.mixer == .instrument
        open = FocusableButton(title: "", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let title = NSMutableAttributedString(string: String(format: "%02d", number) + " · ",
                                              attributes: [.font: atelier ? Theme.note(13) : Theme.mono(11), .foregroundColor: atelier ? Atelier.gold : Theme.textDim])
        title.append(NSAttributedString(string: p.name, attributes: [.font: atelier ? Theme.title(13) : Theme.ui(12, .medium),
                                                                      .foregroundColor: p.loaded ? Theme.text : Theme.textDim]))
        open.attributedTitle = title
        open.isBordered = false
        open.alignment = .left
        open.lineBreakMode = .byTruncatingTail
        open.target = self
        open.action = #selector(openTapped)
        open.toolTip = p.loaded ? "Open \(p.name)" : "\(p.name) isn't loaded: bypassed, settings kept"
        open.setAccessibilityLabel("Insert \(number), \(p.name)")
        bypass.isOn = p.bypassed
        bypass.setAccessibilityLabel("Bypass \(p.name)")
        bypass.onToggle = { [weak self] on in guard let self else { return }; self.onBypass?(self.slot, on) }
        for v in [open, bypass] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        open.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            open.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), open.centerYAnchor.constraint(equalTo: centerYAnchor),
            open.trailingAnchor.constraint(lessThanOrEqualTo: bypass.leadingAnchor, constant: -6),
            bypass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), bypass.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc private func openTapped() { onOpen?(slot) }
    override func draw(_ dirtyRect: NSRect) {
        // A ruled box in Atelier, a quiet slot elsewhere.
        if Theme.look.mixer == .instrument, let ctx = NSGraphicsContext.current?.cgContext {
            Atelier.box(ctx, bounds.insetBy(dx: 0.5, dy: 0.5), weight: Atelier.hair, color: Theme.ink(0.55))
            return
        }
        Theme.ink(Theme.look.mixer == .glass ? 0.05 : 0.04).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.look.mixer == .glass ? 8 : 3, yRadius: Theme.look.mixer == .glass ? 8 : 3).fill()
    }
}

/// "A  Plate  ———|———  −12.0 dB": a lettered send with its level. Right-click: pre/post and removal.
@MainActor
final class InspectorSendRow: NSView {
    let bus: DalnokTrackId
    let fader = FaderControl()
    let value = NSTextField(labelWithString: "")
    var menuProvider: (() -> NSMenu?)?
    init(letter: String, bus: DalnokTrackId, name: String, pre: Bool) {
        self.bus = bus
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let atelier = Theme.look.mixer == .instrument
        let l = NSTextField(labelWithString: letter)
        l.font = atelier ? Theme.note(14) : Theme.mono(11, .semibold)
        l.textColor = atelier ? Atelier.gold : Theme.textDim
        l.setAccessibilityElement(false)
        let n = NSTextField(labelWithString: (pre ? "pre · " : "") + name)
        n.font = atelier ? Theme.title(12.5) : Theme.ui(11.5, .medium)
        n.textColor = Theme.text
        n.lineBreakMode = .byTruncatingTail
        n.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        n.setAccessibilityElement(false)
        value.font = atelier ? Theme.title(11.5) : Theme.mono(10.5)
        value.textColor = Theme.textDim
        value.alignment = .right
        fader.setAccessibilityLabel("Send \(letter) to \(name)")
        fader.toolTip = "Send \(letter) to \(name) (\(pre ? "pre" : "post")-fader). Right-click for options."
        for v in [l, n, fader, value] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), l.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            l.widthAnchor.constraint(equalToConstant: 18),
            n.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 2), n.firstBaselineAnchor.constraint(equalTo: l.firstBaselineAnchor),
            n.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -4),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), value.firstBaselineAnchor.constraint(equalTo: l.firstBaselineAnchor),
            value.widthAnchor.constraint(equalToConstant: 64),
            fader.leadingAnchor.constraint(equalTo: n.leadingAnchor), fader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            fader.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1), fader.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// Atelier's figure at the Inspector's foot (the owner asked for an illustration there; the audit: "never a static
/// decoration"): the selected track's signal path drawn as engraved solids in the shared oblique. The input jack, one
/// block per insert lettered A, B, … (a bypassed one drawn open, its blade raised), the fader block and the output, with a
/// legend on clean plate below and a "Fig." caption. Redrawn only when the path changes.
@MainActor
final class InspectorFigure: NSView {
    struct Path: Equatable { var track = "", input = "In", output = "Master"; var inserts: [(name: String, off: Bool)] = []
        static func == (a: Path, b: Path) -> Bool {
            a.track == b.track && a.input == b.input && a.output == b.output && a.inserts.map(\.name) == b.inserts.map(\.name) && a.inserts.map(\.off) == b.inserts.map(\.off)
        }
    }
    var path = Path() { didSet { if path != oldValue { needsDisplay = true; setAccessibilityValue(summary) } } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Signal path figure")
    }
    required init?(coder: NSCoder) { fatalError() }
    var summary: String {
        ([path.input] + path.inserts.map { $0.off ? "\($0.name) (bypassed)" : $0.name } + ["fader", path.output]).joined(separator: ", then ")
    }
    static let maxShown = 5

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 60, bounds.width > 120, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ink = Theme.text, dim = Theme.ink(0.55)
        Atelier.rule(ctx, CGPoint(x: 0, y: 0.5), CGPoint(x: bounds.width, y: 0.5), weight: Atelier.hair, color: Theme.ink(0.45))
        let shown = Array(path.inserts.prefix(Self.maxShown)), more = path.inserts.count - shown.count
        let y = 40.0 // the signal's axis
        let left: CGFloat = 16, right = bounds.width - 18
        // Stations: jack, inserts, fader, output terminal.
        let n = CGFloat(shown.count + 2)
        let step = (right - left) / max(1, n)
        var xs: [CGFloat] = []
        for i in 0...(shown.count + 2) { xs.append(left + CGFloat(i) * step) }
        // The line of signal, behind everything, with an arrow into each station.
        Atelier.rule(ctx, CGPoint(x: left, y: y), CGPoint(x: right, y: y), weight: Atelier.fine, color: dim)
        // A: the input jack, a turned cylinder seen end on.
        let jack = CGRect(x: left - 6, y: y - 6, width: 12, height: 12)
        Atelier.obliqueSide(ctx, circle: jack)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: jack)
        Atelier.loop(ctx, jack, weight: Atelier.fine, color: ink)
        Atelier.loop(ctx, jack.insetBy(dx: 3.5, dy: 3.5), weight: Atelier.fine, color: ink)
        // Inserts: blocks in the shared oblique; a bypassed one is drawn in outline only, hatched through.
        let bw = min(22, step * 0.62), bh: CGFloat = 16
        for (i, p) in shown.enumerated() {
            let cx = (xs[i] + xs[i + 1]) / 2 + step / 2
            let front = CGRect(x: cx - bw / 2, y: y - bh / 2, width: bw, height: bh)
            Atelier.arrowhead(ctx, at: CGPoint(x: front.minX, y: y), angle: 0, color: dim, size: 5)
            solid(ctx, front, open: p.off)
            Atelier.callout(ctx, Self.letter(i), from: CGPoint(x: front.midX + 2, y: front.minY - 2), to: CGPoint(x: front.midX + 9, y: front.minY - 12))
        }
        // The fader: a slide block on its rail.
        let fx = (xs[shown.count] + xs[shown.count + 1]) / 2 + step / 2
        Atelier.rule(ctx, CGPoint(x: fx, y: y - 13), CGPoint(x: fx, y: y + 13), weight: Atelier.fine, color: ink)
        Atelier.slideBlock(ctx, center: CGPoint(x: fx, y: y + 3), width: 14, height: 10, ink: ink, active: false)
        // The output: a terminal post.
        let out = CGPoint(x: right, y: y)
        Atelier.arrowhead(ctx, at: CGPoint(x: out.x - 4, y: y), angle: 0, color: dim, size: 5)
        let post = CGRect(x: out.x - 4, y: y - 4, width: 8, height: 8)
        Atelier.obliqueSide(ctx, circle: post)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: post)
        Atelier.loop(ctx, post, weight: Atelier.fine, color: ink)
        // Captions under the stations (on clean plate), then the legend and the figure's title.
        Atelier.note(ctx, path.input, at: CGPoint(x: left - 6, y: y + 12), size: 9, color: Theme.textDim)
        Atelier.note(ctx, path.output, at: CGPoint(x: right + 6, y: y + 12), size: 9, color: Theme.textDim, align: .right)
        var ly = y + 30
        let legend = shown.enumerated().map { "\(Self.letter($0.offset)) · \($0.element.name)\($0.element.off ? " (off)" : "")" } + (more > 0 ? ["and \(more) more"] : [])
        for line in legend where ly + 14 < bounds.height - 18 {
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.title(10.5, .regular), .foregroundColor: Theme.text]
            let s = NSAttributedString(string: line, attributes: attrs)
            s.draw(with: CGRect(x: 4, y: ly, width: bounds.width - 8, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            ly += 14
        }
        if shown.isEmpty { Atelier.note(ctx, "No inserts: the signal runs straight to the fader", at: CGPoint(x: 4, y: ly), size: 9.5, color: Theme.textDim) }
        Atelier.note(ctx, "Fig. 3 · Signal path of \(path.track)", at: CGPoint(x: bounds.midX, y: bounds.height - 15), size: 9.5, color: Theme.textDim, align: .center)
    }

    /// An insert as a block in the shared oblique (y down): front, top and right faces, the right one hatched.
    private func solid(_ ctx: CGContext, _ front: CGRect, open: Bool) {
        let v = Atelier.recede, ink = Theme.ink(open ? 0.5 : 0.95)
        let top = CGMutablePath(), side = CGMutablePath()
        top.addLines(between: [CGPoint(x: front.minX, y: front.minY), CGPoint(x: front.minX + v.dx, y: front.minY + v.dy),
                               CGPoint(x: front.maxX + v.dx, y: front.minY + v.dy), CGPoint(x: front.maxX, y: front.minY)]); top.closeSubpath()
        side.addLines(between: [CGPoint(x: front.maxX, y: front.minY), CGPoint(x: front.maxX + v.dx, y: front.minY + v.dy),
                                CGPoint(x: front.maxX + v.dx, y: front.maxY + v.dy), CGPoint(x: front.maxX, y: front.maxY)]); side.closeSubpath()
        ctx.saveGState()
        ctx.setFillColor(Theme.panelRaised.cgColor)
        ctx.addPath(top); ctx.fillPath(); ctx.addPath(side); ctx.fillPath(); ctx.fill(front)
        ctx.addPath(side); ctx.clip(); Atelier.hatch(ctx, side.boundingBox.insetBy(dx: -1, dy: -1), spacing: 1.2, color: Theme.ink(0.5), weight: 0.4)
        ctx.restoreGState()
        if open {
            ctx.saveGState(); ctx.clip(to: front); Atelier.hatch(ctx, front, spacing: 3, color: Theme.ink(0.25), weight: 0.4); ctx.restoreGState()
        } else {
            // Engraved face: two fine rules, like a plate's border.
            Atelier.box(ctx, front.insetBy(dx: 2.5, dy: 2.5), weight: Atelier.hair, color: Theme.ink(0.5))
        }
        for p in [top, side] { ctx.addPath(p); ctx.setStrokeColor(Theme.ink(0.75).cgColor); ctx.setLineWidth(0.55); ctx.strokePath() }
        Atelier.box(ctx, front, weight: Atelier.fine, color: ink)
    }

    static func letter(_ i: Int) -> String { InspectorPanel.letter(i) }
}
