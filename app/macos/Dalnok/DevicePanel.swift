// Device panel (bottom of the main window, like Ableton's device view): the selected track's plug-ins
// as devices, each with a custom controller of knobs. Which parameters the knobs control is chosen per
// plug-in ("Edit Controls"), saved in the project and undoable. Knob turns go straight to the plug-in;
// changes made in the plug-in's own window show up here (the knobs glide and light their ring).
// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import AppKit
import DalnokEngine

@MainActor
final class DevicePanel: NSView {
    static var height: CGFloat { Analog.on ? 268 : 218 } // Warm Analog: upright stomp boxes; Graphite: two rows of faceplate controls
    let session: Session
    var track: DalnokTrackId? { didSet { if oldValue != track { rebuild() } } }
    private(set) var devices: [DeviceView] = []
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let emptyCard = NSView()
    private let emptyTitle = NSTextField(labelWithString: "DEVICE CHAIN")
    private let empty = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "Add Plug-in…", target: nil, action: nil)
    private lazy var addTile: NSButton = {
        let b = NSButton(title: "+  Add Plug-in", target: self, action: #selector(addTapped))
        b.isBordered = false
        b.font = Theme.ui(11, .medium)
        b.contentTintColor = Theme.textDim
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.layer?.borderWidth = 1
        b.layer?.borderColor = Theme.hairline.cgColor
        b.toolTip = "Add a plug-in after the last one on this track"
        b.setAccessibilityLabel("Add plug-in")
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 120).isActive = true
        b.heightAnchor.constraint(equalToConstant: DevicePanel.height - 20).isActive = true
        return b
    }()
    var onOpen: ((DalnokTrackId, Int32) -> Void)?
    var onAdd: (() -> Void)?
    /// A plug-in dropped from the browser: (add path, track, chain position).
    var onDropPlugin: ((String, DalnokTrackId, Int) -> Void)?
    private let dropLine = CALayer()

    /// The chain position for a drop at this window point (between the units).
    func chainIndex(atWindow p: NSPoint) -> Int {
        let x = convert(p, from: nil).x
        for (i, d) in devices.enumerated() where x < d.convert(d.bounds, to: self).midX { return i }
        return devices.count
    }
    private func showDropLine(_ index: Int?) {
        guard let index, let doc = scroll.documentView else { dropLine.isHidden = true; return }
        let frames = devices.map { $0.convert($0.bounds, to: doc) }
        let x = index < frames.count ? frames[index].minX - (Analog.on ? 20 : 5) : (frames.last.map { $0.maxX + (Analog.on ? 20 : 5) } ?? 12)
        if dropLine.superlayer == nil { doc.wantsLayer = true; doc.layer?.addSublayer(dropLine) }
        dropLine.backgroundColor = Theme.selection.cgColor
        dropLine.zPosition = 50
        dropLine.frame = CGRect(x: x - 1.5, y: 8, width: 3, height: DevicePanel.height - 16)
        dropLine.isHidden = false
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        guard track != nil, pb.string(forType: .dalnokPlugin) != nil || pb.string(forType: .dalnokSlot) != nil else { showDropLine(nil); return [] }
        showDropLine(chainIndex(atWindow: sender.draggingLocation))
        return pb.string(forType: .dalnokSlot) != nil ? .move : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { showDropLine(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropLine(nil)
        guard let t = track else { return false }
        let index = chainIndex(atWindow: sender.draggingLocation)
        if let path = sender.draggingPasteboard.string(forType: .dalnokPlugin) { onDropPlugin?(path, t, index); return true }
        if let s = sender.draggingPasteboard.string(forType: .dalnokSlot), let slot = Int32(s) { return move(slot, toDropIndex: index) }
        return false
    }
    /// Moves a unit so it lands before the unit now at `drop` (a drop past its own position counts the gap it leaves).
    @discardableResult func move(_ slot: Int32, toDropIndex drop: Int) -> Bool {
        guard let t = track, let from = devices.firstIndex(where: { $0.slot == slot }) else { return false }
        let to = drop > from ? drop - 1 : drop
        guard to != from else { return false }
        let ok = session.movePlugin(t, slot, to: to)
        rebuild()
        return ok
    }

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        // Settings ▸ Plug-ins ▸ meters applies to the units on screen at once.
        metersObserver = NotificationCenter.default.addObserver(forName: Faceplate.metersChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.devices.forEach { $0.applyMeterSetting() } }
        }
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor
        registerForDraggedTypes([.dalnokPlugin, .dalnokSlot])
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
        emptyCard.wantsLayer = true
        emptyCard.layer?.backgroundColor = (Analog.on ? Theme.hex(0x211914) : Theme.hex(0x202228)).cgColor
        emptyCard.layer?.borderColor = Theme.hairline.cgColor
        emptyCard.layer?.borderWidth = 1
        emptyCard.layer?.cornerRadius = 6
        emptyTitle.font = Theme.ui(10, .semibold)
        emptyTitle.textColor = Theme.textDim
        empty.font = Theme.ui(12)
        empty.textColor = Theme.textDim
        empty.maximumNumberOfLines = 2
        empty.lineBreakMode = .byTruncatingTail
        addButton.target = self
        addButton.action = #selector(addTapped)
        for v in [scroll, emptyCard] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        for v in [emptyTitle, empty, addButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; emptyCard.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.topAnchor.constraint(equalTo: doc.topAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            doc.widthAnchor.constraint(greaterThanOrEqualTo: stack.widthAnchor),
            doc.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            emptyCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Analog.on ? 64 : 12),
            emptyCard.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyCard.widthAnchor.constraint(equalToConstant: 360), emptyCard.heightAnchor.constraint(equalToConstant: 132),
            emptyTitle.leadingAnchor.constraint(equalTo: emptyCard.leadingAnchor, constant: 16),
            emptyTitle.topAnchor.constraint(equalTo: emptyCard.topAnchor, constant: 14),
            empty.leadingAnchor.constraint(equalTo: emptyTitle.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: emptyCard.trailingAnchor, constant: -16),
            empty.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 10),
            addButton.leadingAnchor.constraint(equalTo: emptyTitle.leadingAnchor),
            addButton.topAnchor.constraint(equalTo: empty.bottomAnchor, constant: 10),
        ])
        setAccessibilityLabel("Device panel")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if Analog.on, let ctx = NSGraphicsContext.current?.cgContext { PedalDraw.board(ctx, bounds) } // a pedalboard
        else { Theme.panel.setFill(); bounds.fill() }
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
                let d = DeviceView(session: session, track: t!.id, slot: p.id, name: p.name, loaded: p.loaded, color: t!.color, vendor: p.vendor, instrument: p.instrument, error: p.error, path: p.path)
                d.onOpen = { [weak self] in self?.onOpen?(t!.id, p.id) }
                d.onMove = { [weak self] delta in
                    guard let self, let from = self.devices.firstIndex(where: { $0.slot == p.id }) else { return }
                    self.move(p.id, toDropIndex: delta > 0 ? from + 2 : from - 1)
                }
                return d
            }
            devices.forEach { stack.addArrangedSubview($0) }
            addTile.removeFromSuperview()
            if let last = devices.last {
                stack.addArrangedSubview(addTile)
                stack.setCustomSpacing(Analog.on ? 96 : 10, after: last) // analog: past the OUT jack
            }
            for d in devices where !Motion.reduced {
                d.alphaValue = 0
                Motion.views(Motion.gentle) { d.animator().alphaValue = 1 }
            }
        }
        needsLayout = true
        emptyCard.isHidden = !plugins.isEmpty
        addButton.isHidden = !plugins.isEmpty || t == nil
        empty.stringValue = t == nil ? "Select a track to see its plug-ins." :
            t!.isInstrument ? "\(t!.name) plays the built-in Dalnok Poly. Add an instrument or effect plug-in."
                            : "No plug-ins on \(t!.name) yet."
    }

    /// Picks up parameter changes made elsewhere (the plug-in's own editor, undo of controls).
    func refreshValues() { devices.forEach { $0.refreshValues() } }
    /// Graphite device meters (every frame).
    func pollMeters() { devices.forEach { $0.pollMeters() } }
    private var metersObserver: NSObjectProtocol?

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
    private var cableFrames: [CGRect] = []
    private var cableSlots: [Int32] = []
    private var cableTrack: DalnokTrackId?
    override func layout() {
        super.layout()
        layoutCables()
    }
    /// The signal path drawn as patch cables: track → first unit → … → last unit → track output.
    func layoutCables() {
        guard Analog.on, let doc = scroll.documentView else { return }
        doc.wantsLayer = true
        doc.layoutSubtreeIfNeeded()
        let frames = devices.map { $0.convert($0.bounds, to: doc) }
        let slots = devices.map(\.slot)
        if frames == cableFrames && slots == cableSlots && track == cableTrack { return }
        cableFrames = frames
        cableSlots = slots
        cableTrack = track
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cableLayers.forEach { $0.removeFromSuperlayer() }
        cableLayers = []
        CATransaction.commit()
        guard !devices.isEmpty else { knownCables = []; return }
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
                Motion.connectCable(cable, plug: plug, paths: [12, 37, 27, 31, 30].map {
                    Analog.cablePath(from: a, to: b, sag: CGFloat($0))
                })
            }
        }
        knownCables = Set(links.map { $0.2 })
    }
}

@MainActor
final class DeviceView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    let session: Session
    let trackId: DalnokTrackId
    let slot: Int32
    let loaded: Bool
    private let unavailableMessage: String
    private let color: NSColor
    private let title = NSTextField(labelWithString: "")
    private let openButton = PlateButton(title: "Open", label: "EDITOR")
    private let editButton = PlateButton(title: "Edit Controls", label: "CONTROLS")
    private let etchedTitle = EtchedLabel("")
    private(set) var knobs: [(knob: any ParameterControl, label: NSTextField, value: NSTextField, id: UInt32)] = []
    /// Warm Analog: the plug-in drawn as a stomp box (nil in Graphite).
    private(set) var pedal: PedalBody?
    /// Graphite: the faceplate's sections (between the input and output meters).
    private let sectionsRow = NSStackView()
    let inMeter = FaceplateMeter(caption: "IN"), outMeter = FaceplateMeter(caption: "OUT")
    /// Graphite: the unit's instrument panel (gain-reduction meter, response screen or oscilloscope).
    private(set) var displayKind: FaceplateDisplay.Kind = .scope
    private(set) var display: NSView?
    private var displaySize: [NSLayoutConstraint] = []
    private var analyzer: SpectrumAnalyzer?
    private var tick = 0
    private let path: String
    private let power = PlateButton(title: "", label: "")
    var bypassed: Bool { session.pluginBypassed(trackId, slot) }
    private(set) var allParameters: [DalnokPluginParameter] = []
    private var indexOf: [UInt32: Int32] = [:]
    var onOpen: (() -> Void)?
    static let defaultCount = 8
    static var ear: CGFloat { Analog.on ? 12 : 0 } // rack ear width

    init(session: Session, track: DalnokTrackId, slot: Int32, name: String, loaded: Bool, color: NSColor, vendor: String = "", instrument: Bool = false, error: String = "", path: String = "") {
        self.session = session
        self.trackId = track
        self.slot = slot
        self.loaded = loaded
        self.unavailableMessage = (instrument ? "Not loaded: instrument silent." : "Not loaded: effect bypassed.")
            + (error.isEmpty ? " Settings are kept." : " " + error)
        self.color = color
        self.path = path
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Analog.on ? 2 : 5
        title.stringValue = name
        if !loaded { title.toolTip = unavailableMessage; setAccessibilityHelp(unavailableMessage) }
        title.font = Theme.ui(12, .semibold)
        title.textColor = loaded ? Theme.text : Theme.textFaint
        if !Analog.on { // engraved into the faceplate
            let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.7); s.shadowOffset = NSSize(width: 0, height: -1); s.shadowBlurRadius = 0
            title.shadow = s
        }
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
        // Sidechain source (plug-ins with an auxiliary input only).
        sidechain.controlSize = .small
        sidechain.font = Theme.ui(10, .medium)
        sidechain.target = self
        sidechain.action = #selector(sidechainChosen)
        sidechain.toolTip = "Sidechain: which track's signal this plug-in listens to (for ducking and keyed effects)"
        sidechain.isHidden = !(loaded && dalnok_plugin_has_sidechain(session.engine.handle, slot))
        // Bypass: the pedal's footswitch in Warm Analog, a power button here in Graphite.
        power.bezelStyle = .inline
        power.isBordered = false
        power.setButtonType(.toggle)
        power.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Bypass")
        power.target = self
        power.action = #selector(toggleBypass)
        power.toolTip = "On/Off: bypass \(name) (undoable)"
        power.setAccessibilityLabel("Bypass \(name)")
        power.isEnabled = loaded
        power.isHidden = Analog.on
        if !Analog.on { // Graphite: hardware keys and an etched name
            etchedTitle.text = name
            title.isHidden = true
            for b in [editButton, openButton] { b.style = .key }
            power.style = .power
            power.lit = color.blended(withFraction: 0.25, of: .white) ?? color
        } else { etchedTitle.isHidden = true }
        let header = NSStackView(views: [power, title, etchedTitle, NSView(), sidechain, editButton, openButton])
        header.spacing = 6
        header.setContentHuggingPriority(.required, for: .vertical) // stays at the top whatever the controls' height
        if Analog.on {
            title.isHidden = true // the name is lettered on the pedal
            for b in [editButton, openButton] { b.contentTintColor = Theme.textDim; b.font = Theme.ui(9.5, .semibold) }
            editButton.title = "Controls…"
            let p = PedalBody(name: name)
            p.vendor = vendor
            p.footswitch.onStomp = { [weak self] in self?.toggleBypass() }
            p.footswitch.isEnabled = loaded
            p.menuProvider = { [weak self] in self?.deviceMenu() }
            pedal = p
        }
        // Graphite: input meter, the faceplate's sections, output meter; the controls sit mid-height.
        let above = NSView(), below = NSView()
        sectionsRow.orientation = .horizontal
        sectionsRow.alignment = .top
        sectionsRow.spacing = 6
        if !Analog.on && loaded {
            displayKind = FaceplateDisplay.kind(name: name, path: path, instrument: instrument)
            let d: NSView = switch displayKind {
            case .gainReduction: GainReductionMeter()
            case .response: ResponseScreen()
            case .scope: ScopeScreen()
            }
            (d as? ResponseScreen)?.tint = color.blended(withFraction: 0.35, of: .white) ?? color
            d.translatesAutoresizingMaskIntoConstraints = false
            display = d
        }
        let faceRow = NSStackView(views: [inMeter] + (display.map { [$0] } ?? []) + [sectionsRow, NSView(), outMeter])
        faceRow.alignment = .centerY
        faceRow.spacing = 8
        for m in [inMeter, outMeter] {
            m.translatesAutoresizingMaskIntoConstraints = false
            m.widthAnchor.constraint(equalToConstant: FaceplateMeter.width).isActive = true
            m.heightAnchor.constraint(equalToConstant: 118).isActive = true
            m.isHidden = !(loaded && Faceplate.showMeters)
        }
        let body = NSStackView(views: pedal.map { [header, $0] } ?? [header, above, faceRow, below])
        body.orientation = .vertical
        body.alignment = pedal == nil ? .leading : .centerX
        body.spacing = 4
        body.edgeInsets = pedal == nil ? NSEdgeInsets(top: 7, left: 14 + Self.ear, bottom: 10, right: 14 + Self.ear)
                                       : NSEdgeInsets(top: 0, left: Self.ear, bottom: 2, right: Self.ear)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: DevicePanel.height - 20),
        ])
        if let pedal {
            NSLayoutConstraint.activate([
                header.widthAnchor.constraint(equalTo: pedal.widthAnchor),
                widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            ])
            pedal.setContentHuggingPriority(.defaultLow, for: .vertical)
        } else {
            NSLayoutConstraint.activate([
                above.heightAnchor.constraint(equalTo: below.heightAnchor),
                header.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28 - 2 * Self.ear),
                faceRow.widthAnchor.constraint(equalTo: header.widthAnchor),
                widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            ])
        }
        loadParameters()
        refreshControls()
        setAccessibilityElement(true)
        setAccessibilityLabel("\(name) device")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard Analog.on else {
            Faceplate.plate(ctx, bounds, accent: color, dimmed: !loaded || bypassed)
            return
        }
        // A pedal: the enclosure is the PedalBody; here only the input and output jacks on its sides.
        let ear = Self.ear
        for x in [CGFloat(0), bounds.width - ear] {
            let nut = CGRect(x: x + 1, y: bounds.midY - 6, width: ear - 2, height: 12)
            NSColor(white: 0.55, alpha: 1).setFill(); NSBezierPath(roundedRect: nut, xRadius: 1.5, yRadius: 1.5).fill()
            NSColor(white: 0.3, alpha: 1).setFill(); NSRect(x: nut.minX, y: nut.midY - 0.5, width: nut.width, height: 1).fill()
            Analog.jack(ctx, at: CGPoint(x: x + ear / 2, y: bounds.midY), radius: 4)
        }
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
    let sidechain = NSPopUpButton(frame: .zero, pullsDown: false)
    private func refreshSidechain() {
        guard !sidechain.isHidden else { return }
        let others = session.allTracks.filter { $0.id != trackId }
        let titles = ["SC: None"] + others.map { "SC: \($0.name)" }
        if sidechain.itemTitles != titles { sidechain.removeAllItems(); sidechain.addItems(withTitles: titles) }
        sidechain.item(at: 0)?.tag = 0
        for (i, t) in others.enumerated() { sidechain.item(at: i + 1)?.tag = Int(t.id) }
        sidechain.selectItem(withTag: Int(dalnok_plugin_sidechain(session.engine.handle, trackId, slot)))
    }
    @objc private func sidechainChosen() {
        if dalnok_plugin_set_sidechain(session.engine.handle, trackId, slot, DalnokTrackId(sidechain.selectedTag())) != DALNOK_OK {
            session.onMessage?("That sidechain would feed the track back into its source")
        }
        session.refresh()
    }

    func refreshControls() {
        refreshSidechain()
        refreshBypass()
        let ids = controlIds
        if knobs.map(\.id) == ids { return refreshValues() }
        if let pedal { return buildPedal(pedal, ids) }
        return buildFaceplate(ids)
    }

    /// Graphite: the controller as a hardware faceplate. Each parameter gets the control that suits it, related
    /// parameters share an engraved section, and knob scales print the plug-in's own values at their ends.
    private func buildFaceplate(_ ids: [UInt32]) {
        sectionsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        knobs = []
        func note(_ text: String) {
            let l = label(text, dim: true)
            l.toolTip = text
            l.maximumNumberOfLines = 3
            l.lineBreakMode = .byWordWrapping
            l.preferredMaxLayoutWidth = 220
            sectionsRow.addArrangedSubview(l)
        }
        if !loaded { return note(unavailableMessage) }
        if ids.isEmpty { return note("No automatable parameters. Use Open for the plug-in's own window.") }
        let params = ids.compactMap { id in current(id).map { (id: id, p: $0) } }
        let rows = params.count > 6 ? 2 : 1
        if let display {
            NSLayoutConstraint.deactivate(displaySize)
            let size = FaceplateDisplay.size(displayKind, rows: rows)
            displaySize = [display.widthAnchor.constraint(equalToConstant: size.width), display.heightAnchor.constraint(equalToConstant: size.height)]
            NSLayoutConstraint.activate(displaySize)
        }
        let groups = Faceplate.sections(params.map { (id: $0.id, title: fixedString($0.p.title)) })
        var views: [FaceplateSection] = []
        for g in groups {
            var controls: [FaceplateControl] = []
            for item in g.items {
                guard let p = current(item.id) else { continue }
                let id = item.id
                let c = FaceplateControl(name: item.label, steps: p.step_count)
                c.value = p.value
                c.defaultValue = p.default_value
                c.tint = color
                c.legends = legends(id, p)
                c.bipolar = c.kind == .knob && abs(p.default_value - 0.5) < 1e-6 && (c.legends.first?.hasPrefix("-") ?? false)
                c.format = { [weak self] _ in self?.current(id).map { self?.display($0) ?? "" } ?? "" }
                c.onChange = { [weak self] v in self?.set(id, v) }
                c.toolTip = "\(fixedString(p.title)): drag up or down (⇧ fine), scroll or use the arrow keys; double-click for the default."
                c.setAccessibilityLabel(fixedString(p.title))
                controls.append(c)
                knobs.append((c, label(fixedString(p.title), dim: false), label(display(p), dim: true), id))
            }
            let section = FaceplateSection(title: g.title, controls: controls, rows: g.items.count > 1 ? rows : 1)
            views.append(section)
        }
        views.last?.groove = false
        views.forEach { sectionsRow.addArrangedSubview($0) }
        refreshBypass()
    }

    /// Printed scale legends: the plug-in's own text at the ends of the travel (every position for short selectors).
    private func legends(_ id: UInt32, _ p: DalnokPluginParameter) -> [String] {
        guard p.step_count != 1 else { return [] }
        func text(_ v: Double) -> String? {
            var buf = [CChar](repeating: 0, count: 64)
            guard dalnok_plugin_parameter_text(session.engine.handle, slot, id, v, &buf, 64) == DALNOK_OK else { return nil }
            return Faceplate.legend(String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        guard let lo = text(0), let hi = text(1), !lo.isEmpty, !hi.isEmpty else { return [] }
        return [lo, hi]
    }

    func applyMeterSetting() {
        for m in [inMeter, outMeter] { m.isHidden = !(loaded && Faceplate.showMeters) }
    }

    /// Graphite: reads this unit's levels and feeds its meters and display (called every frame while the panel shows).
    func pollMeters() {
        guard pedal == nil, loaded else { return }
        var il: Float = 0, ir: Float = 0, ol: Float = 0, orr: Float = 0
        guard dalnok_meter_plugin(session.engine.handle, slot, &il, &ir, &ol, &orr) == DALNOK_OK else { return }
        if !inMeter.isHidden { inMeter.push(il, ir); outMeter.push(ol, orr) }
        tick += 1
        updateDisplay()
    }

    /// The display's data: gain reduction (reported or measured), the response curve and spectrum, or the scope trace.
    private func updateDisplay() {
        guard let display else { return }
        let h = session.engine.handle
        let off = bypassed
        switch displayKind {
        case .gainReduction:
            guard let meter = display as? GainReductionMeter else { return }
            if off { return meter.update(reported: 0, inRms: 0, outRms: 0) }
            var inBuf = [Float](repeating: 0, count: 1_024), outBuf = inBuf
            let n = Int(dalnok_plugin_tap(h, slot, &inBuf, &outBuf, 1_024))
            func rms(_ x: [Float]) -> Float { var r: Float = 0; vDSP_rmsqv(x, 1, &r, vDSP_Length(n)); return r }
            meter.update(reported: reportedReduction(), inRms: n > 0 ? rms(inBuf) : 0, outRms: n > 0 ? rms(outBuf) : 0)
        case .response:
            guard let screen = display as? ResponseScreen else { return }
            let freqs = ResponseScreen.frequencies
            if tick % 3 == 0 {
                var db = [Double](repeating: 0, count: freqs.count)
                if dalnok_plugin_response(h, slot, freqs, Int32(freqs.count), &db) == DALNOK_OK {
                    screen.curve = off ? [Double](repeating: 0, count: freqs.count) : db
                    screen.measured = false
                    screen.markers = off ? [] : bandMarkers()
                } else if let a = analyzer, a.frames > 3, !off {
                    // Hosted EQs: the response measured from the signal, held where the input is too quiet.
                    let rate = Double(dalnok_engine_sample_rate(h)), floor = a.inputPeak * 1e-6
                    var c = screen.curve ?? [Double](repeating: 0, count: freqs.count)
                    for (i, f) in freqs.enumerated() { if let v = a.responseDb(at: f, rate: rate, floor: floor) { c[i] += (Double(v) - c[i]) * 0.3 } }
                    screen.curve = c
                    screen.measured = true
                }
            }
            if tick % 2 == 0 {
                var inBuf = [Float](repeating: 0, count: SpectrumAnalyzer.n), outBuf = inBuf
                if dalnok_plugin_tap(h, slot, &inBuf, &outBuf, Int32(SpectrumAnalyzer.n)) == Int32(SpectrumAnalyzer.n) {
                    let a = analyzer ?? SpectrumAnalyzer()
                    analyzer = a
                    if outBuf.contains(where: { $0 != 0 }) {
                        a.push(input: inBuf, output: outBuf)
                        let rate = Double(dalnok_engine_sample_rate(h))
                        screen.spectrum = freqs.map { a.outputDb(at: $0, rate: rate) }
                    } else if screen.spectrum != nil { screen.spectrum = nil }
                }
            }
        case .scope:
            guard let scope = display as? ScopeScreen, tick % 2 == 0 else { return }
            var outBuf = [Float](repeating: 0, count: 2_048)
            let n = Int(dalnok_plugin_tap(h, slot, nil, &outBuf, 2_048))
            if n == 2_048, outBuf.contains(where: { abs($0) > 1e-5 }) { scope.push(outBuf) } else { scope.clear() }
        }
    }

    /// Dalnok Channel EQ's enabled bands, numbered like its sections (1 low cut … 8 high cut), for the screen.
    private func bandMarkers() -> [(hz: Double, label: String)] {
        guard path == "channel-eq" else { return [] }
        let bands: [UInt32] = [0, 4, 8, 12, 16, 20, 24, 28]
        var out: [(Double, String)] = []
        for (i, base) in bands.enumerated() {
            var on = DalnokPluginParameter(), freq = DalnokPluginParameter()
            guard let a = indexOf[base], let b = indexOf[base + 1],
                  dalnok_plugin_parameter(session.engine.handle, slot, a, &on) == DALNOK_OK, on.value >= 0.5,
                  dalnok_plugin_parameter(session.engine.handle, slot, b, &freq) == DALNOK_OK,
                  let hz = Double(fixedString(freq.display).filter { "0123456789.".contains($0) }) else { continue }
            out.append((hz, String(i + 1)))
        }
        return out
    }

    /// A gain reduction the plug-in reports itself (a read-only parameter such as "Gain Reduction" or
    /// "Compression Amount"), in dB.
    private func reportedReduction() -> Double? {
        guard let p = allParameters.first(where: { p in
            let t = fixedString(p.title).lowercased()
            return p.read_only && (t.contains("reduction") || t == "gr" || t.contains("compression amount"))
        }), let now = current(p.id) else { return nil }
        let digits = fixedString(now.display).filter { "0123456789.-".contains($0) }
        return Double(digits).map(abs)
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
        refreshBypass()
        for k in knobs where !k.knob.tracking {
            guard let p = current(k.id) else { continue }
            if abs(p.value - k.knob.value) > 1e-6 { k.knob.glide(to: p.value) }
            k.value.stringValue = display(p)
        }
    }

    @objc private func openTapped() { onOpen?() }

    // MARK: Bypass and the pedal (Warm Analog)

    @objc func toggleBypass() {
        guard loaded else { return }
        session.setPluginBypassed(trackId, slot, !bypassed)
        refreshBypass()
        session.onMessage?(bypassed ? "\(title.stringValue) bypassed" : "\(title.stringValue) on")
    }
    private func refreshBypass() {
        let off = bypassed
        power.state = off ? .off : .on
        power.contentTintColor = off ? Theme.textFaint : Theme.accent
        title.textColor = !loaded || off ? Theme.textFaint : (Analog.on ? Theme.text : Faceplate.engraving)
        etchedTitle.dimmed = !loaded || off
        pedal?.engaged = loaded && !off
        if pedal == nil {
            for k in knobs { (k.knob as? FaceplateControl)?.dimmed = off }
            needsDisplay = true
        }
    }

    private func buildPedal(_ pedal: PedalBody, _ ids: [UInt32]) {
        knobs = []
        pedal.message = !loaded ? unavailableMessage : ids.isEmpty ? "No automatable parameters. Use Open." : nil
        var controls: [PedalControl] = [], names: [NSTextField] = []
        for id in loaded ? ids : [] {
            guard let p = current(id) else { continue }
            let kind = PedalStore.kind(pedal.name, id) ?? PedalControl.defaultKind(steps: p.step_count)
            let c = PedalControl(kind: kind, look: pedal.look)
            c.steps = p.step_count
            c.value = p.value
            c.defaultValue = p.default_value
            c.format = { [weak self] _ in self?.current(id).map { self?.display($0) ?? "" } ?? "" }
            c.onChange = { [weak self] v in self?.set(id, v); c.toolTip = self?.current(id).map { "\(fixedString($0.title)): \(self?.display($0) ?? "")" } }
            c.onKindChange = { [weak pedal] k in if let pedal { PedalStore.setKind(pedal.name, id, k) } }
            c.setAccessibilityLabel(fixedString(p.title))
            c.toolTip = "\(fixedString(p.title)): \(display(p)). Drag up or down (⇧ fine), double-click for the default; right-click to change the control."
            let name = NSTextField(labelWithString: fixedString(p.title).uppercased())
            name.font = Theme.ui(6.8, .bold)
            name.alignment = .center
            name.lineBreakMode = .byTruncatingTail
            name.toolTip = fixedString(p.title)
            let value = label(display(p), dim: true) // read by tests and VoiceOver; the bubble shows it while turning
            controls.append(c); names.append(name)
            knobs.append((c, name, value, id))
        }
        pedal.setControls(controls, labels: names)
    }

    /// Right-click a device: bypass, window, controls, chain order and removal (and, on a pedal, its look).
    func deviceMenu() -> NSMenu {
        let m = NSMenu()
        func item(_ t: String, _ f: @escaping () -> Void, on: Bool = false, enabled: Bool = true) -> NSMenuItem {
            let i = ClosureMenuItem(title: t, action: f); i.state = on ? .on : .off; i.isEnabled = enabled; return i
        }
        m.autoenablesItems = false
        let chain = session.track(trackId)?.plugins.map(\.id) ?? []
        let i = chain.firstIndex(of: slot) ?? 0
        m.addItem(item(bypassed ? "Turn On" : "Bypass", { [weak self] in self?.toggleBypass() }, enabled: loaded))
        m.addItem(item("Open Plug-in Window", { [weak self] in self?.onOpen?() }, enabled: loaded))
        m.addItem(item("Edit Controls…", { [weak self] in self?.editTapped(self?.editButton) }, enabled: loaded))
        m.addItem(.separator())
        m.addItem(item("Move Left (Earlier in Chain)", { [weak self] in self?.onMove?(-1) }, enabled: i > 0))
        m.addItem(item("Move Right (Later in Chain)", { [weak self] in self?.onMove?(1) }, enabled: i < chain.count - 1))
        m.addItem(item("Remove Plug-in", { [weak self] in guard let self else { return }; self.session.removePlugin(self.trackId, self.slot) }))
        if pedal != nil { m.addItem(.separator()); pedalLookItems(m) }
        return m
    }
    override func menu(for event: NSEvent) -> NSMenu? { deviceMenu() }
    /// Moves this unit by `delta` places in the chain (menu and keyboard alternative to dragging).
    var onMove: ((Int) -> Void)?

    // Dragging a unit by its empty surface reorders the chain.
    private var dragStart: NSPoint?
    override func mouseDown(with event: NSEvent) { dragStart = event.locationInWindow }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } // drag a unit even when another window is key
    /// Empty surface (layout containers, labels, the pedal enclosure) belongs to the unit, so a press there can start
    /// a drag (and is accepted as a first click); real controls keep their clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        if v is NSStackView || v is NSGridView || v is PedalBody || v is FaceplateSection || (v as? NSTextField).map({ !$0.isEditable && !$0.isSelectable }) == true { return self }
        return v
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart, hypot(event.locationInWindow.x - s.x, event.locationInWindow.y - s.y) > 6 else { return }
        dragStart = nil
        let item = NSPasteboardItem()
        item.setString(String(slot), forType: .dalnokSlot)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = bitmapImageRepForCachingDisplay(in: bounds).map { rep -> NSImage in
            cacheDisplay(in: bounds, to: rep); let i = NSImage(size: bounds.size); i.addRepresentation(rep); return i
        }
        dragItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil }

    /// The pedal's look entries (Warm Analog).
    private func pedalLookItems(_ m: NSMenu) {
        guard let pedal else { return }
        func item(_ t: String, _ f: @escaping () -> Void, on: Bool = false) -> NSMenuItem {
            let i = ClosureMenuItem(title: t, action: f); i.state = on ? .on : .off; return i
        }
        let name = pedal.name
        let apply = { [weak self, weak pedal] in pedal?.look = PedalStore.look(name); self?.needsDisplay = true }
        m.addItem(item("New Random Look", { PedalStore.reroll(name); apply() }))
        func sub(_ title: String, _ entries: [(String, String)], field: String, current: String) {
            let s = NSMenu()
            for (t, v) in entries { s.addItem(item(t, { PedalStore.set(name, field, v); apply() }, on: v == current)) }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""); parent.submenu = s; m.addItem(parent)
        }
        let l = pedal.look
        sub("Colour", PedalLook.enclosures.enumerated().map { ($0.element.0, String($0.offset)) }, field: "enclosure", current: String(l.enclosure))
        sub("Finish", PedalLook.Finish.allCases.map { ($0.title, $0.rawValue) }, field: "finish", current: l.finish.rawValue)
        sub("Knobs", PedalLook.Knob.allCases.map { ($0.title, $0.rawValue) }, field: "knob", current: l.knob.rawValue)
        sub("Artwork", PedalLook.Artwork.allCases.map { ($0.title, $0.rawValue) }, field: "artwork", current: l.artwork.rawValue)
        sub("LED", PedalLook.leds.enumerated().map { ($0.element.0, String($0.offset)) }, field: "led", current: String(l.led))
        sub("Footswitch", PedalLook.Switch.allCases.map { ($0.title, $0.rawValue) }, field: "footswitch", current: l.footswitch.rawValue)
        m.addItem(item("Reset Look", { PedalStore.reset(name); apply() }))
    }

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
