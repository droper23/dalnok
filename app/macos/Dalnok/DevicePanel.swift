// Device panel (bottom of the main window, like Ableton's device view): the selected track's plug-ins
// as devices, each with a custom controller of knobs. Which parameters the knobs control is chosen per
// plug-in ("Edit Controls"), saved in the project and undoable. Knob turns go straight to the plug-in;
// changes made in the plug-in's own window show up here (the knobs glide and light their ring).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class DevicePanel: NSView {
    static let height: CGFloat = 196
    let session: Session
    var track: DalnokTrackId? { didSet { if oldValue != track { rebuild() } } }
    private(set) var devices: [DeviceView] = []
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let empty = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "Add Plug-in…", target: nil, action: nil)
    var onOpen: ((DalnokTrackId, Int32) -> Void)?
    var onAdd: (() -> Void)?

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = Analog.on ? 40 : 10 // analog: room for the patch cables between units
        stack.edgeInsets = NSEdgeInsets(top: 10, left: Analog.on ? 64 : 12, bottom: 10, right: Analog.on ? 64 : 12)
        let doc = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        empty.font = Theme.ui(12)
        empty.textColor = Theme.textDim
        addButton.target = self
        addButton.action = #selector(addTapped)
        for v in [scroll, empty, addButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.topAnchor.constraint(equalTo: doc.topAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            doc.widthAnchor.constraint(greaterThanOrEqualTo: stack.widthAnchor),
            doc.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            addButton.centerXAnchor.constraint(equalTo: centerXAnchor), addButton.topAnchor.constraint(equalTo: empty.bottomAnchor, constant: 8),
        ])
        setAccessibilityLabel("Device panel")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        (Analog.on ? Theme.hex(0x15100C) : Theme.panel).setFill(); bounds.fill()
        Theme.separator.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func addTapped() { onAdd?() }

    /// Rebuilds the device list when the track or its plug-ins change.
    func rebuild() {
        let t = track.flatMap { session.track($0) }
        let plugins = t?.plugins ?? []
        if devices.map(\.slot) == plugins.map(\.id), devices.allSatisfy({ $0.trackId == t?.id }) {
            devices.forEach { $0.refreshControls() }
        } else {
            devices.forEach { $0.removeFromSuperview() }
            if devices.first?.trackId != t?.id { knownCables = [] } // a different track: draw its cables fresh
            devices = plugins.map { p in
                let d = DeviceView(session: session, track: t!.id, slot: p.id, name: p.name, loaded: p.loaded, color: t!.color)
                d.onOpen = { [weak self] in self?.onOpen?(t!.id, p.id) }
                return d
            }
            devices.forEach { stack.addArrangedSubview($0) }
            for d in devices where !Motion.reduced {
                d.alphaValue = 0
                Motion.views(Motion.gentle) { d.animator().alphaValue = 1 }
            }
        }
        needsLayout = true
        empty.isHidden = !plugins.isEmpty
        addButton.isHidden = !plugins.isEmpty || t == nil
        empty.stringValue = t == nil ? "Select a track to see its plug-ins." :
            "No plug-ins on \(t!.name)\(t!.isInstrument ? " (it plays Dalnok Poly)" : ""). Add one from Audio ▸ Plug-ins."
    }

    /// Picks up parameter changes made elsewhere (the plug-in's own editor, undo of controls).
    func refreshValues() { devices.forEach { $0.refreshValues() } }

    // MARK: Patch cables (Warm Analog)

    private var cableLayers: [CALayer] = []
    /// Patch cables currently drawn (Warm Analog): track IN → units → track OUT.
    var cableCount: Int { cableLayers.filter { ($0 as? CAShapeLayer)?.lineWidth == 4 }.count }
    private static let jackImage: CGImage? = {
        let ctx = CGContext(data: nil, width: 36, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.scaleBy(x: 2, y: 2)
        if let ctx { Analog.jack(ctx, at: CGPoint(x: 9, y: 9), radius: 7) }
        return ctx?.makeImage()
    }()
    private var knownCables = Set<String>()
    override func layout() {
        super.layout()
        layoutCables()
    }
    /// The signal path drawn as patch cables: track → first unit → … → last unit → track output.
    func layoutCables() {
        guard Analog.on, let doc = scroll.documentView else { return }
        doc.wantsLayer = true
        doc.layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cableLayers.forEach { $0.removeFromSuperlayer() }
        cableLayers = []
        CATransaction.commit()
        guard !devices.isEmpty else { return }
        let frames = devices.map { $0.convert($0.bounds, to: doc) }
        var links: [(CGPoint, CGPoint, String)] = []
        let first = frames[0], last = frames[frames.count - 1]
        // The track's patch points: IN (left of the chain) and OUT (right of it).
        let trackIn = CGPoint(x: 26, y: first.midY), trackOut = CGPoint(x: last.maxX + 38, y: last.midY)
        for (p, label) in [(trackIn, "IN"), (trackOut, "OUT")] {
            let jack = CALayer()
            jack.frame = CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)
            jack.contents = Self.jackImage
            jack.zPosition = 19
            let text = CATextLayer()
            text.string = label
            text.font = Theme.mono(9, .semibold)
            text.fontSize = 9
            text.foregroundColor = Theme.textDim.cgColor
            text.alignmentMode = .center
            text.contentsScale = 2
            text.frame = CGRect(x: p.x - 16, y: p.y - 24, width: 32, height: 12)
            doc.layer?.addSublayer(jack)
            doc.layer?.addSublayer(text)
            cableLayers += [jack, text]
        }
        links.append((trackIn, CGPoint(x: first.minX + DeviceView.ear / 2, y: first.midY), "in-\(devices[0].slot)"))
        for i in 1..<max(1, frames.count) where frames.count > 1 {
            links.append((CGPoint(x: frames[i - 1].maxX - DeviceView.ear / 2, y: frames[i - 1].midY),
                          CGPoint(x: frames[i].minX + DeviceView.ear / 2, y: frames[i].midY), "\(devices[i - 1].slot)-\(devices[i].slot)"))
        }
        links.append((CGPoint(x: last.maxX - DeviceView.ear / 2, y: last.midY), trackOut, "\(devices[devices.count - 1].slot)-out"))
        for (i, (a, b, key)) in links.enumerated() {
            let color = Analog.cableColors[i % Analog.cableColors.count]
            let cable = CAShapeLayer()
            cable.path = Analog.cablePath(from: a, to: b, sag: 30)
            cable.strokeColor = color.cgColor
            cable.fillColor = nil
            cable.lineWidth = 4
            cable.lineCap = .round
            cable.shadowColor = NSColor.black.cgColor
            cable.shadowOpacity = 0.6
            cable.shadowRadius = 2
            cable.shadowOffset = CGSize(width: 0, height: 2)
            cable.zPosition = 20
            let plug = CAShapeLayer() // the plug barrel seated in the input jack
            plug.path = CGPath(roundedRect: CGRect(x: b.x - 9, y: b.y - 3.5, width: 9, height: 7), cornerWidth: 2, cornerHeight: 2, transform: nil)
            plug.fillColor = color.blended(withFraction: 0.35, of: .black)?.cgColor
            plug.strokeColor = NSColor(white: 0, alpha: 0.6).cgColor
            plug.zPosition = 21
            doc.layer?.addSublayer(cable)
            doc.layer?.addSublayer(plug)
            cableLayers += [cable, plug]
            if !knownCables.contains(key) && !Motion.reduced && window != nil {
                // Plugging in: the cable draws toward the jack, then the plug seats with a small push.
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0
                draw.toValue = 1
                draw.duration = 0.35
                draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cable.add(draw, forKey: "plug")
                let seat = CAKeyframeAnimation(keyPath: "transform.translation.x")
                seat.values = [-12, -12, 1.5, 0]
                seat.keyTimes = [0, 0.6, 0.85, 1]
                seat.duration = 0.5
                plug.add(seat, forKey: "seat")
            }
            knownCables.insert(key)
        }
    }
}

@MainActor
final class DeviceView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let session: Session
    let trackId: DalnokTrackId
    let slot: Int32
    let loaded: Bool
    private let color: NSColor
    private let title = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit Controls", target: nil, action: nil)
    private let grid = NSGridView()
    private(set) var knobs: [(knob: RotaryKnob, label: NSTextField, value: NSTextField, id: UInt32)] = []
    private(set) var allParameters: [DalnokPluginParameter] = []
    private var indexOf: [UInt32: Int32] = [:]
    var onOpen: (() -> Void)?
    static let columns = 4, defaultCount = 8
    static var ear: CGFloat { Analog.on ? 12 : 0 } // rack ear width

    init(session: Session, track: DalnokTrackId, slot: Int32, name: String, loaded: Bool, color: NSColor) {
        self.session = session
        self.trackId = track
        self.slot = slot
        self.loaded = loaded
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Analog.on ? nil : Theme.panelRaised.cgColor
        layer?.cornerRadius = Analog.on ? 2 : 6
        layer?.borderWidth = 1
        layer?.borderColor = Theme.hairline.cgColor
        title.stringValue = name
        title.font = Theme.ui(12, .semibold)
        title.textColor = loaded ? Theme.text : Theme.textFaint
        title.lineBreakMode = .byTruncatingTail
        for b in [openButton, editButton] {
            b.bezelStyle = .inline
            b.controlSize = .small
            b.font = Theme.ui(10.5, .medium)
            b.target = self
        }
        openButton.action = #selector(openTapped)
        openButton.toolTip = "Open the plug-in's window (its own editor and every parameter)"
        editButton.action = #selector(editTapped(_:))
        editButton.toolTip = "Choose which parameters this controller shows"
        openButton.isEnabled = loaded
        editButton.isEnabled = loaded
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        let header = NSStackView(views: [title, NSView(), editButton, openButton])
        header.spacing = 6
        let body = NSStackView(views: [header, grid])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.edgeInsets = NSEdgeInsets(top: 8, left: 12 + Self.ear, bottom: 8, right: 10 + Self.ear)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -22 - 2 * Self.ear),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            heightAnchor.constraint(equalToConstant: DevicePanel.height - 20),
        ])
        loadParameters()
        refreshControls()
        setAccessibilityElement(true)
        setAccessibilityLabel("\(name) device")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard Analog.on, let ctx = NSGraphicsContext.current?.cgContext else {
            (loaded ? color : Theme.textFaint).setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
            return
        }
        // A rack unit: textured faceplate, darker rack ears with screws, IN and OUT jacks, and a power LED.
        Analog.faceplate.setFill(); bounds.fill()
        let ear = Self.ear
        for x in [CGFloat(0), bounds.width - ear] {
            NSColor(white: 0.10, alpha: 1).setFill()
            NSRect(x: x, y: 0, width: ear, height: bounds.height).fill()
            Analog.screw(ctx, at: CGPoint(x: x + ear / 2, y: 10), radius: 3)
            Analog.screw(ctx, at: CGPoint(x: x + ear / 2, y: bounds.height - 10), radius: 3)
            Analog.jack(ctx, at: CGPoint(x: x + ear / 2, y: bounds.midY), radius: 4.5)
        }
        NSColor(white: 1, alpha: 0.06).setFill(); NSRect(x: ear, y: bounds.height - 1, width: bounds.width - 2 * ear, height: 1).fill()
        Analog.led(ctx, in: CGRect(x: ear + 6, y: bounds.height - 18, width: 6, height: 6),
                   color: loaded ? Theme.hex(0x52D273) : Theme.recordOn, lit: true)
    }

    private func loadParameters() {
        guard loaded else { return }
        allParameters = []
        indexOf = [:]
        for i in 0..<dalnok_plugin_parameter_count(session.engine.handle, slot) {
            var p = DalnokPluginParameter()
            guard dalnok_plugin_parameter(session.engine.handle, slot, i, &p) == DALNOK_OK, !p.hidden else { continue }
            allParameters.append(p)
            indexOf[p.id] = i
        }
    }

    /// The controller's parameter ids: the saved choice, else the first automatable parameters.
    var controlIds: [UInt32] {
        var ids = [UInt32](repeating: 0, count: 32)
        let n = Int(dalnok_plugin_controls(session.engine.handle, trackId, slot, &ids, 32))
        if n > 0 { return Array(ids.prefix(n)) }
        return Array(allParameters.filter { $0.automatable && !$0.read_only }.prefix(Self.defaultCount).map(\.id))
    }

    func current(_ id: UInt32) -> DalnokPluginParameter? {
        var p = DalnokPluginParameter()
        guard let i = indexOf[id], dalnok_plugin_parameter(session.engine.handle, slot, i, &p) == DALNOK_OK else { return nil }
        return p
    }

    /// Rebuilds the knob grid from the controller's ids.
    func refreshControls() {
        let ids = controlIds
        if knobs.map(\.id) == ids { return refreshValues() }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        knobs = []
        if !loaded {
            grid.addRow(with: [label("Not loaded: bypassed. Its settings are kept.", dim: true)])
            return
        }
        if ids.isEmpty {
            grid.addRow(with: [label("No automatable parameters. Use Open for the plug-in's own window.", dim: true)])
            return
        }
        var cells: [NSView] = []
        for id in ids {
            guard let p = current(id) else { continue }
            let knob = RotaryKnob()
            knob.bipolar = false
            knob.value = p.value
            knob.tint = color
            knob.format = { [weak self] _ in self?.current(id).map { fixedString($0.display) } ?? "" }
            knob.onChange = { [weak self] v in self?.set(id, v) }
            knob.setAccessibilityLabel(fixedString(p.title))
            knob.translatesAutoresizingMaskIntoConstraints = false
            knob.widthAnchor.constraint(equalToConstant: 30).isActive = true
            knob.heightAnchor.constraint(equalToConstant: 30).isActive = true
            let name = label(fixedString(p.title), dim: false)
            let value = label(display(p), dim: true)
            let cell = NSStackView(views: [knob, name, value])
            cell.orientation = .vertical
            cell.spacing = 2
            cell.widthAnchor.constraint(equalToConstant: 64).isActive = true
            cells.append(cell)
            knobs.append((knob, name, value, id))
        }
        for row in stride(from: 0, to: cells.count, by: Self.columns) {
            var r = Array(cells[row..<min(row + Self.columns, cells.count)])
            while r.count < Self.columns { r.append(NSGridCell.emptyContentView) }
            grid.addRow(with: r)
        }
        for c in 0..<grid.numberOfColumns { grid.column(at: c).width = 64; grid.column(at: c).xPlacement = .center }
    }

    private func display(_ p: DalnokPluginParameter) -> String {
        let d = fixedString(p.display), u = fixedString(p.units)
        return u.isEmpty || d.contains(u) ? d : "\(d) \(u)"
    }

    private func label(_ text: String, dim: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = dim ? Theme.mono(9.5) : Theme.ui(10, .medium)
        l.textColor = dim ? Theme.textDim : Theme.text
        l.alignment = .center
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    func set(_ id: UInt32, _ value: Double) {
        dalnok_plugin_set_parameter(session.engine.handle, slot, id, max(0, min(1, value)))
        if let k = knobs.first(where: { $0.id == id }), let p = current(id) { k.value.stringValue = display(p) }
    }

    /// External changes (the plug-in's own editor) glide the knob and light its ring.
    func refreshValues() {
        for k in knobs where !k.knob.tracking {
            guard let p = current(k.id) else { continue }
            if abs(p.value - k.knob.value) > 1e-6 { k.knob.glide(to: p.value) }
            k.value.stringValue = display(p)
        }
    }

    @objc private func openTapped() { onOpen?() }

    // MARK: Edit Controls (searchable list; checked parameters are on the controller, in order)

    private var picker: NSPopover?
    private var pickerRows: [DalnokPluginParameter] = []
    private let pickerTable = NSTableView()
    private let pickerSearch = NSSearchField()

    @objc func editTapped(_ sender: NSButton?) {
        let vc = NSViewController()
        let col = NSTableColumn(identifier: .init("p"))
        col.width = 260
        if pickerTable.tableColumns.isEmpty {
            pickerTable.addTableColumn(col)
            pickerTable.headerView = nil
            pickerTable.dataSource = self
            pickerTable.delegate = self
            pickerTable.rowHeight = 22
        }
        pickerSearch.placeholderString = "Search \(allParameters.count) parameters"
        pickerSearch.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = pickerTable
        scroll.hasVerticalScroller = true
        let note = NSTextField(wrappingLabelWithString: "Checked parameters appear on the controller (up to 32). Changes are one undo step.")
        note.font = Theme.ui(10.5)
        note.textColor = Theme.textDim
        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetControls))
        reset.controlSize = .small
        let stack = NSStackView(views: [pickerSearch, scroll, note, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 380)
        scroll.widthAnchor.constraint(equalToConstant: 280).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        pickerSearch.widthAnchor.constraint(equalToConstant: 280).isActive = true
        note.widthAnchor.constraint(equalToConstant: 280).isActive = true
        vc.view = stack
        filterPicker("")
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        picker = pop
        if let sender, sender.window != nil { pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY) }
    }

    func filterPicker(_ q: String) {
        let query = q.lowercased()
        pickerRows = allParameters.filter { query.isEmpty || fixedString($0.title).lowercased().contains(query) }
        pickerTable.reloadData()
    }
    func controlTextDidChange(_ obj: Notification) { filterPicker(pickerSearch.stringValue) }

    /// Adds or removes a parameter on the controller (tests use this directly).
    func toggleControl(_ id: UInt32) {
        var ids = controlIds
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else if ids.count < 32 { ids.append(id) }
        session.setPluginControls(trackId, slot, ids)
        refreshControls()
        pickerTable.reloadData()
    }
    @objc func resetControls() {
        session.setPluginControls(trackId, slot, [])
        refreshControls()
        pickerTable.reloadData()
    }
    @objc private func checkToggled(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < pickerRows.count else { return }
        toggleControl(pickerRows[sender.tag].id)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pickerRows.count }
    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let p = pickerRows[row]
        let b = NSButton(checkboxWithTitle: fixedString(p.title), target: self, action: #selector(checkToggled(_:)))
        b.tag = row
        b.state = controlIds.contains(p.id) ? .on : .off
        b.isEnabled = !p.read_only
        return b
    }
}
