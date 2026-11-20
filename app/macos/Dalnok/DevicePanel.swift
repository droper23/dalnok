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
    static var height: CGFloat { Analog.on ? 268 : 226 } // Warm Analog: upright stomp boxes; Graphite: two rows of faceplate controls
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
    var onShowControls: ((DalnokTrackId, Int32) -> Void)?
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
        wearObserver = NotificationCenter.default.addObserver(forName: Faceplate.wearChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.devices.forEach { $0.applyWear() } }
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
    /// Units animating out of the chain (removed plug-ins); no longer in `devices`.
    private(set) var leaving: [DeviceView] = []

    func rebuild() {
        let t = track.flatMap { session.track($0) }
        let plugins = t?.plugins ?? []
        func matches(_ d: DeviceView, _ p: TrackView.Plugin) -> Bool {
            d.slot == p.id && d.loaded == p.loaded && d.error == p.error && d.trackId == t?.id
        }
        if devices.count == plugins.count, zip(devices, plugins).allSatisfy({ matches($0, $1) }) {
            devices.forEach { $0.refreshControls() }
            for (d, p) in zip(devices, plugins) { d.setFolded(p.folded, animated: true) }
        } else {
            // Units still leaving from an earlier change go at once.
            leaving.forEach { $0.finishTransition(); $0.removeFromSuperview() }
            leaving = []
            let old = devices
            let sameTrack = !old.isEmpty && old.allSatisfy { $0.trackId == t?.id }
            if !sameTrack { knownCables = [] } // a different track: draw its cables fresh
            // The same track keeps the units whose plug-in is unchanged; only arrivals and departures animate.
            var next: [DeviceView] = [], arrived: [DeviceView] = []
            for p in plugins {
                if sameTrack, let d = old.first(where: { matches($0, p) }) {
                    d.refreshControls()
                    d.setFolded(p.folded, animated: true)
                    next.append(d)
                    continue
                }
                let d = DeviceView(session: session, track: t!.id, slot: p.id, name: p.name, loaded: p.loaded, color: t!.color, vendor: p.vendor, instrument: p.instrument, error: p.error, path: p.path)
                d.onOpen = { [weak self] in self?.onOpen?(t!.id, p.id) }
                d.onShowControls = { [weak self] in self?.onShowControls?(t!.id, p.id) }
                d.onSelect = { [weak self] in self?.selectedSlot = p.id }
                d.onMove = { [weak self] delta in
                    guard let self, let from = self.devices.firstIndex(where: { $0.slot == p.id }) else { return }
                    self.move(p.id, toDropIndex: delta > 0 ? from + 2 : from - 1)
                }
                d.setFolded(p.folded, animated: false)
                next.append(d)
                arrived.append(d)
            }
            let departed = sameTrack ? old.filter { o in !next.contains { $0 === o } } : []
            if !sameTrack { old.forEach { $0.removeFromSuperview() } }
            // Arrange: the new chain, with departing units kept at their old place while they leave.
            var arranged = next
            for d in departed {
                let at = min(old.firstIndex { $0 === d } ?? arranged.count, arranged.count)
                arranged.insert(d, at: at)
            }
            for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
            arranged.forEach { stack.addArrangedSubview($0) }
            devices = next
            leaving = departed
            if let s = selectedSlot, !devices.contains(where: { $0.slot == s }) { selectedSlot = nil }
            devices.forEach { $0.isSelected = $0.slot == selectedSlot }
            if let last = arranged.last {
                stack.addArrangedSubview(addTile)
                stack.setCustomSpacing(Analog.on ? 96 : 10, after: last) // analog: past the OUT jack
            }
            if sameTrack {
                arrived.forEach { $0.animateArrival() }
                for d in departed {
                    d.animateDeparture { [weak self, weak d] in
                        MainActor.assumeIsolated {
                            guard let self, let d else { return }
                            d.removeFromSuperview()
                            self.leaving.removeAll { $0 === d }
                            self.needsLayout = true
                        }
                    }
                }
            } else {
                for d in devices where !Motion.reduced {
                    d.alphaValue = 0
                    Motion.views(Motion.gentle) { d.animator().alphaValue = 1 }
                }
            }
        }
        needsLayout = true
        emptyCard.isHidden = !plugins.isEmpty
        addButton.isHidden = !plugins.isEmpty || t == nil
        empty.stringValue = t == nil ? "Select a track to see its plug-ins." :
            t!.isInstrument ? "\(t!.name) plays the built-in Dalnok Poly. Add an instrument or effect plug-in."
                            : "No plug-ins on \(t!.name) yet."
    }

    /// Rebuilds every unit from scratch (a display choice changed for all of them).
    func rebuildAll() {
        devices.forEach { $0.removeFromSuperview() }
        devices = []
        rebuild()
    }

    /// Picks up parameter changes made elsewhere (the plug-in's own editor, undo of controls).
    func refreshValues() { devices.forEach { $0.refreshValues() } }
    /// Graphite device meters (every frame).
    func pollMeters() { devices.forEach { $0.pollMeters() } }
    private var metersObserver: NSObjectProtocol?, wearObserver: NSObjectProtocol?

    /// The unit last clicked (white outline glow); nil when none is.
    var selectedSlot: Int32? { didSet { devices.forEach { $0.isSelected = $0.slot == selectedSlot } } }

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

/// Reports every primary press in its view (including on controls inside it) without taking the event.
final class PressRecognizer: NSGestureRecognizer {
    private let onPress: () -> Void
    init(_ onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(target: nil, action: nil)
        delaysPrimaryMouseButtonEvents = false
        delaysSecondaryMouseButtonEvents = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onPress(); state = .failed }
    override func rightMouseDown(with event: NSEvent) { onPress(); state = .failed }
}

@MainActor
final class DeviceView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    let session: Session
    let trackId: DalnokTrackId
    let slot: Int32
    let loaded: Bool
    let error: String
    private let unavailableMessage: String
    private let color: NSColor
    private let title = NSTextField(labelWithString: "")
    private let openButton = PlateButton(title: "Open", label: "OPEN")
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
    private var instrument = false
    private weak var faceRow: NSStackView?
    private let path: String
    private let power = PlateButton(title: "", label: "")
    /// The unit's power key (Graphite), for tests.
    var powerKey: PlateButton? { Analog.on ? nil : power }
    var bypassed: Bool { session.pluginBypassed(trackId, slot) }
    private(set) var allParameters: [DalnokPluginParameter] = []
    private var indexOf: [UInt32: Int32] = [:]
    var onOpen: (() -> Void)?
    /// Dalnok's controls window for this plug-in (every parameter).
    var onShowControls: (() -> Void)?
    /// A press anywhere on the unit (its surface or any control) selects it.
    var onSelect: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { applySelection() } } }
    /// Bypassed in Graphite: the unit sits back slightly (drawn at this scale about its centre).
    private var recessed = false
    static let defaultCount = 8
    static var ear: CGFloat { Analog.on ? 12 : 0 } // rack ear width
    // Folding (dalnok_plugin_set_folded): the unit holds either its full body or a narrow FoldStrip.
    private var bodyStack: NSStackView!
    private var minWidth: NSLayoutConstraint!
    private var bodyConstraints: [NSLayoutConstraint] = []
    private var stripConstraints: [NSLayoutConstraint] = []
    private var transitionWidth: NSLayoutConstraint?
    let foldButton = NSButton(title: "", target: nil, action: nil)
    /// Shown folded (the engine's state, applied by DevicePanel.rebuild).
    private(set) var folded = false
    /// Running a fold, unfold, arrival or departure animation.
    private(set) var transitioning = false
    private(set) lazy var strip: FoldStrip = {
        let s = FoldStrip(name: etchedTitle.text.isEmpty ? title.stringValue : etchedTitle.text)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.look = pedal?.look
        s.onUnfold = { [weak self] in guard let self else { return }; self.session.setPluginFolded(self.trackId, self.slot, false) }
        s.menuProvider = { [weak self] in self?.deviceMenu() }
        s.onToggle = { [weak self] in self?.toggleBypass() }
        return s
    }()

    init(session: Session, track: DalnokTrackId, slot: Int32, name: String, loaded: Bool, color: NSColor, vendor: String = "", instrument: Bool = false, error: String = "", path: String = "") {
        self.session = session
        self.trackId = track
        self.slot = slot
        self.loaded = loaded
        self.error = error
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
        openButton.toolTip = "Open the plug-in's own window (its title bar's Controls shows every parameter)"
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
            power.style = .powerIcon
            power.lit = color.blended(withFraction: 0.25, of: .white) ?? color
        } else { etchedTitle.isHidden = true }
        foldButton.bezelStyle = .inline
        foldButton.isBordered = false
        foldButton.image = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: "Fold")
        foldButton.contentTintColor = Theme.textDim
        foldButton.target = self
        foldButton.action = #selector(foldTapped)
        foldButton.toolTip = "Fold \(name) to a narrow strip (click the strip to unfold)"
        foldButton.setAccessibilityLabel("Fold \(name)")
        // One button opens the plug-in; choosing the controller's parameters is in the unit's menu (Edit Controls…).
        let header = NSStackView(views: [foldButton, power, title, etchedTitle, NSView(), sidechain, openButton])
        header.spacing = 6
        header.setContentHuggingPriority(.required, for: .vertical) // stays at the top whatever the controls' height
        if Analog.on {
            title.isHidden = true // the name is lettered on the pedal
            for b in [editButton, openButton] { b.contentTintColor = Theme.textDim; b.font = Theme.ui(9.5, .semibold) }
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
        self.instrument = instrument
        if !Analog.on && loaded {
            loadParameters()
            display = makeDisplay(automaticKind())
        }
        let faceRow = NSStackView(views: [inMeter] + (display.map { [$0] } ?? []) + [sectionsRow, NSView(), outMeter])
        self.faceRow = faceRow
        faceRow.alignment = .centerY
        faceRow.spacing = 8
        for m in [inMeter, outMeter] {
            m.translatesAutoresizingMaskIntoConstraints = false
            m.widthAnchor.constraint(equalToConstant: FaceplateMeter.width).isActive = true
            m.heightAnchor.constraint(equalToConstant: 118).isActive = true
            m.isHidden = !(loaded && Faceplate.showMeters) || (m === inMeter && instrument) // an instrument has no audio input
        }
        let body = NSStackView(views: pedal.map { [header, $0] } ?? [header, above, faceRow, below])
        body.orientation = .vertical
        body.alignment = pedal == nil ? .leading : .centerX
        body.spacing = 4
        body.edgeInsets = pedal == nil ? NSEdgeInsets(top: 12, left: 16 + Self.ear, bottom: 10, right: 16 + Self.ear)
                                       : NSEdgeInsets(top: 0, left: Self.ear, bottom: 2, right: Self.ear)
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyStack = body
        attachBody()
        heightAnchor.constraint(equalToConstant: DevicePanel.height - 20).isActive = true
        if let pedal {
            header.widthAnchor.constraint(equalTo: pedal.widthAnchor).isActive = true
            minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
            pedal.setContentHuggingPriority(.defaultLow, for: .vertical)
        } else {
            NSLayoutConstraint.activate([
                above.heightAnchor.constraint(equalTo: below.heightAnchor),
                header.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28 - 2 * Self.ear),
                faceRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            ])
            minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        }
        minWidth.isActive = true
        loadParameters()
        refreshControls()
        setAccessibilityElement(true)
        setAccessibilityLabel("\(name) device")
        let press = PressRecognizer { [weak self] in self?.onSelect?() }
        addGestureRecognizer(press)
    }

    /// Selection: a white outline with a soft glow around the unit (Settings ▸ Plug-ins can turn it off).
    private func applySelection() {
        guard let layer else { return }
        let shown = isSelected && Faceplate.selectionGlow
        layer.masksToBounds = false
        layer.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        layer.borderWidth = shown ? 1.5 : 0
        layer.shadowColor = NSColor.white.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 7
        layer.shadowOpacity = shown ? 0.55 : 0
        setAccessibilitySelected(isSelected)
    }

    /// The scale a bypassed unit sits back to (Settings ▸ Plug-ins ▸ Shrink).
    static var recessedScale: CGFloat { 1 - CGFloat(Faceplate.bypassShrink) }
    /// A thin dark veil over a bypassed unit (Settings ▸ Plug-ins ▸ Dim).
    private lazy var veil: CALayer = {
        let l = CALayer()
        l.backgroundColor = NSColor.black.cgColor
        l.opacity = 0
        l.zPosition = 100
        l.cornerRadius = 5
        layer?.addSublayer(l)
        return l
    }()

    /// Bypass (Graphite): the unit shrinks a little about its centre and dims slightly, over Settings' motion time,
    /// while its lights fade (see `fadeLights`). Reduce Motion makes the change immediate.
    func setRecessed(_ on: Bool) {
        guard !Analog.on, on != recessed else { return }
        recessed = on
        let animate = !Motion.reduced && window != nil
        let from = layer?.presentation()?.transform ?? layer?.transform ?? CATransform3DIdentity
        let fromOpacity = veil.presentation()?.opacity ?? veil.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyRecess()
        CATransaction.commit()
        guard animate, let layer else { return }
        let duration = Faceplate.bypassMotion
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: from)
        move.toValue = NSValue(caTransform3D: layer.transform)
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(move, forKey: "recess")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = veil.opacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        veil.add(fade, forKey: "dim")
    }
    private func applyRecess() {
        let s = recessed ? Self.recessedScale : 1
        layer?.setAffineTransform(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: bounds.width * (1 - s) / 2, ty: bounds.height * (1 - s) / 2))
        veil.frame = bounds
        veil.opacity = recessed ? Float(Faceplate.bypassDim) : 0
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); applyRecess(); CATransaction.commit()
    }

    /// Lights (LED rings, switch lamps, readouts, meters, screens, VU lamps) fade to `target` over Settings' fade time.
    private var lightLevel: CGFloat?
    private var lightTimer: Timer?
    private func fadeLights(to target: CGFloat) {
        let duration = Motion.reduced || window == nil ? 0 : Faceplate.lightFade
        guard let from = lightLevel, duration > 0.01 else { lightTimer?.invalidate(); return setLights(target) }
        lightTimer?.invalidate()
        lightFade = (from, target, CACurrentMediaTime(), duration)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.lightStep() } }
        lightTimer = t
        RunLoop.main.add(t, forMode: .common)
    }
    private var lightFade: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: Double)?
    private func lightStep() {
        guard let f = lightFade else { lightTimer?.invalidate(); return }
        let p = min(1, (CACurrentMediaTime() - f.start) / f.duration)
        // Filaments cool fast at first; warming up eases in and out.
        let eased = f.to < f.from ? 1 - pow(1 - p, 2) : p * p * (3 - 2 * p)
        setLights(f.from + (f.to - f.from) * CGFloat(eased))
        if p >= 1 { lightTimer?.invalidate(); lightFade = nil }
    }
    private func setLights(_ v: CGFloat) {
        lightLevel = v
        for k in knobs { (k.knob as? FaceplateControl)?.light = v }
        inMeter.light = v; outMeter.light = v
        (display as? FaceplateScreen)?.light = v
    }

    /// Settings ▸ wear changed: redraw the metal and the glass.
    func applyWear() {
        needsDisplay = true
        display?.needsDisplay = true
        applySelection()
        CATransaction.begin(); CATransaction.setDisableActions(true); applyRecess(); CATransaction.commit()
        for k in knobs { (k.knob as? FaceplateControl)?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard Analog.on else {
            Faceplate.plate(ctx, bounds, accent: color, dimmed: !loaded || bypassed, seed: Faceplate.seed(title.stringValue), wear: Faceplate.wear)
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
        if sidechain.itemTitles != titles {
            sidechain.removeAllItems()
            // NSPopUpButton.addItems drops duplicate titles; tracks can share a name.
            for title in titles { sidechain.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: "")) }
        }
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
        if instrument { inMeter.isHidden = true } // an instrument has no audio input
    }

    /// Graphite: reads this unit's levels and feeds its meters and display (called every frame while the panel shows).
    func pollMeters() {
        if let pedal { return pollPedal(pedal) }
        guard loaded else { return }
        var il: Float = 0, ir: Float = 0, ol: Float = 0, orr: Float = 0
        guard dalnok_meter_plugin(session.engine.handle, slot, &il, &ir, &ol, &orr) == DALNOK_OK else { return }
        if folded { // the strip's level column: −48…0 dBFS, falling back slowly
            let peak = max(ol, orr), db = peak > 0 ? 20 * log10(peak) : -96
            let target = CGFloat(max(0, min(1, (db + 48) / 48)))
            strip.level = target >= strip.level ? target : max(target, strip.level - 0.04)
            return
        }
        if !inMeter.isHidden { inMeter.push(il, ir); outMeter.push(ol, orr) }
        tick += 1
        updateDisplay()
    }

    /// Warm Analog: the pedal's signal LEDs and readout window (the same data a Graphite faceplate shows).
    private func pollPedal(_ pedal: PedalBody) {
        guard loaded, !folded, !pedal.screen.isHidden else { return }
        let h = session.engine.handle
        var il: Float = 0, ir: Float = 0, ol: Float = 0, orr: Float = 0
        if dalnok_meter_plugin(h, slot, &il, &ir, &ol, &orr) == DALNOK_OK {
            pedal.inLevel = CGFloat(min(1, max(il, ir))); pedal.outLevel = CGFloat(min(1, max(ol, orr)))
        }
        tick += 1
        let screen = pedal.screen
        if screen.showingValue { screen.needsDisplay = true; return } // let it time out
        guard tick % 2 == 0, !bypassed else { return }
        switch automaticKind() {
        case .vu: // a level meter: the output level on the ladder, −48…0 dBFS
            screen.mode = .ladder
            let peak = Double(max(ol, orr)), db = peak > 0 ? 20 * log10(peak) : -96
            screen.reduction += ((max(-48, db) + 48) / 2 - screen.reduction) * 0.35 // 0…24 on the ladder's scale
            screen.reading = peak > 1e-5 ? String(format: "%.0f dBFS", db) : "NO SIGNAL"
        case .gainReduction:
            screen.mode = .ladder
            var inBuf = [Float](repeating: 0, count: 1_024), outBuf = inBuf
            let n = Int(dalnok_plugin_tap(h, slot, &inBuf, &outBuf, 1_024))
            var ri: Float = 0, ro: Float = 0
            if n > 0 { vDSP_rmsqv(inBuf, 1, &ri, vDSP_Length(n)); vDSP_rmsqv(outBuf, 1, &ro, vDSP_Length(n)) }
            let measured = ri > 1e-4 && ro > 0 ? max(0, Double(20 * log10(ri / max(ro, 1e-9)))) : 0
            let gr = reportedReduction() ?? measured
            screen.reduction += (gr - screen.reduction) * 0.35
            screen.reading = String(format: "-%.1f dB GR", screen.reduction)
        case .response, .analyzer:
            screen.mode = .curve
            guard tick % 6 == 0 else { return }
            let freqs = (0..<48).map { 20 * pow(1000, Double($0) / 47) }
            var db = [Double](repeating: 0, count: freqs.count)
            if dalnok_plugin_response(h, slot, freqs, Int32(freqs.count), &db) == DALNOK_OK {
                screen.curve = db
                let peak = db.max(by: { abs($0) < abs($1) }) ?? 0
                screen.reading = String(format: "%+.1f dB", peak)
            } else {
                var inBuf = [Float](repeating: 0, count: SpectrumAnalyzer.n), outBuf = inBuf
                guard dalnok_plugin_tap(h, slot, &inBuf, &outBuf, Int32(SpectrumAnalyzer.n)) == Int32(SpectrumAnalyzer.n) else { return }
                let a = analyzer ?? SpectrumAnalyzer()
                analyzer = a
                a.push(input: inBuf, output: outBuf)
                let rate = Double(dalnok_engine_sample_rate(h))
                screen.curve = freqs.map { Double(a.outputDb(at: $0, rate: rate)) / 3 + 12 } // spectrum, scaled into view
                screen.reading = "SPECTRUM"
            }
        case .scope, .goniometer, .history, .transfer:
            screen.mode = .scope
            var outBuf = [Float](repeating: 0, count: 1_024)
            let n = Int(dalnok_plugin_tap(h, slot, nil, &outBuf, 1_024))
            guard n == 1_024 else { return }
            screen.trace = stride(from: 0, to: n, by: 8).map { outBuf[$0] }
            let peak = outBuf.map(abs).max() ?? 0
            screen.reading = peak > 1e-5 ? String(format: "%.0f dBFS", 20 * log10(peak)) : "NO SIGNAL"
        }
    }

    /// The display's data: gain reduction (reported or measured), the response curve and spectrum, or the scope trace.
    private func updateDisplay() {
        guard let display else { return }
        let h = session.engine.handle
        let off = bypassed
        switch displayKind {
        case .gainReduction, .vu:
            guard let meter = display as? MovingCoilMeter else { return }
            var inBuf = [Float](repeating: 0, count: 1_024), outBuf = inBuf
            let n = Int(dalnok_plugin_tap(h, slot, &inBuf, &outBuf, 1_024))
            func rms(_ x: [Float]) -> Float { var r: Float = 0; if n > 0 { vDSP_rmsqv(x, 1, &r, vDSP_Length(n)) }; return r }
            if meter.mode == .output { return meter.update(rms: off ? 0 : rms(outBuf)) }
            if off { return meter.update(reported: 0, inRms: 0, outRms: 0) }
            meter.update(reported: reportedReduction(), inRms: rms(inBuf), outRms: rms(outBuf))
        case .transfer:
            guard let screen = display as? TransferScreen, tick % 2 == 0 else { return }
            var inBuf = [Float](repeating: 0, count: 1_024), outBuf = inBuf
            if !off, dalnok_plugin_tap(h, slot, &inBuf, &outBuf, 1_024) == 1_024 { screen.push(input: inBuf, output: outBuf) } else { screen.clear() }
        case .history:
            guard let screen = display as? HistoryScreen, tick % 2 == 0 else { return }
            var inBuf = [Float](repeating: 0, count: 1_536), outBuf = inBuf
            let n = Int(dalnok_plugin_tap(h, slot, &inBuf, &outBuf, 1_536))
            var ri: Float = 0, ro: Float = 0
            if n > 0 { vDSP_rmsqv(inBuf, 1, &ri, vDSP_Length(n)); vDSP_rmsqv(outBuf, 1, &ro, vDSP_Length(n)) }
            screen.push(inRms: ri, outRms: off ? 0 : ro)
        case .goniometer:
            guard let screen = display as? GoniometerScreen, tick % 2 == 0 else { return }
            var l = [Float](repeating: 0, count: 1_024), r = l
            if !off, dalnok_plugin_tap_stereo(h, slot, &l, &r, 1_024) == 1_024 { screen.push(left: l, right: r) } else { screen.clear() }
        case .analyzer:
            guard let screen = display as? LedAnalyzer, tick % 2 == 0 else { return }
            var inBuf = [Float](repeating: 0, count: SpectrumAnalyzer.n), outBuf = inBuf
            guard dalnok_plugin_tap(h, slot, &inBuf, &outBuf, Int32(SpectrumAnalyzer.n)) == Int32(SpectrumAnalyzer.n) else { return }
            let a = analyzer ?? SpectrumAnalyzer()
            analyzer = a
            a.push(input: inBuf, output: off ? [Float](repeating: 0, count: SpectrumAnalyzer.n) : outBuf)
            let rate = Double(dalnok_engine_sample_rate(h))
            screen.push(LedAnalyzer.bands.map { a.outputDb(at: $0, rate: rate) })
        case .response:
            guard let screen = display as? ResponseScreen else { return }
            let freqs = ResponseScreen.frequencies
            if tick % 3 == 0 {
                var db = [Double](repeating: 0, count: freqs.count)
                if dalnok_plugin_response(h, slot, freqs, Int32(freqs.count), &db) == DALNOK_OK {
                    screen.curve = off ? [Double](repeating: 0, count: freqs.count) : db
                    screen.measured = false
                } else if let a = analyzer, a.frames > 3, !off {
                    // Hosted EQs: the response measured from the signal, held where the input is too quiet.
                    let rate = Double(dalnok_engine_sample_rate(h)), floor = a.inputPeak * 1e-6
                    var c = screen.curve ?? [Double](repeating: 0, count: freqs.count)
                    for (i, f) in freqs.enumerated() { if let v = a.responseDb(at: f, rate: rate, floor: floor) { c[i] += (Double(v) - c[i]) * 0.3 } }
                    screen.curve = c
                    screen.measured = true
                }
                if screen.dragging == nil { screen.markers = bandMarkers() }
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

    /// The display this plug-in gets (FaceplateDisplay.kind): the owner's choice, else what it declares, its
    /// parameters, then its name.
    func automaticKind() -> FaceplateDisplay.Kind {
        var buf = [CChar](repeating: 0, count: 1_024)
        dalnok_plugin_categories(session.engine.handle, slot, &buf, buf.count)
        let declared = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: "|").map(String.init)
        return FaceplateDisplay.kind(name: title.stringValue, path: path, instrument: instrument, declared: declared,
                                     parameters: allParameters.map { fixedString($0.title) })
    }

    private func makeDisplay(_ kind: FaceplateDisplay.Kind) -> NSView {
        displayKind = kind
        analyzer = nil
        let d: NSView = switch kind {
        case .gainReduction: MovingCoilMeter(mode: .gainReduction)
        case .vu: MovingCoilMeter(mode: .output)
        case .response: ResponseScreen()
        case .transfer: TransferScreen()
        case .history: HistoryScreen()
        case .goniometer: GoniometerScreen()
        case .analyzer: LedAnalyzer()
        case .scope: ScopeScreen()
        }
        if let screen = d as? FaceplateScreen { screen.seed = Faceplate.seed(title.stringValue); screen.poweredOff = loaded && bypassed }
        if let screen = d as? ResponseScreen {
            screen.tint = color.blended(withFraction: 0.35, of: .white) ?? color
            findBands()
            screen.onBandDrag = { [weak self] i, hz, db in self?.bandDragged(i, hz: hz, db: db) }
            screen.onBandScroll = { [weak self] i, d in self?.bandScrolled(i, d) }
            screen.onBandToggle = { [weak self] i in self?.bandToggled(i) }
            screen.markers = bandMarkers()
        }
        (d as? HistoryScreen)?.tint = color.blended(withFraction: 0.35, of: .white) ?? color
        d.translatesAutoresizingMaskIntoConstraints = false
        return d
    }

    /// Right-click ▸ Display: replaces the unit's display and remembers the choice for this plug-in (nil: automatic).
    func chooseDisplay(_ kind: FaceplateDisplay.Kind?) {
        FaceplateDisplay.setOverride(title.stringValue, kind)
        guard let row = faceRow, let old = display, let i = row.arrangedSubviews.firstIndex(of: old) else { return }
        NSLayoutConstraint.deactivate(displaySize)
        old.removeFromSuperview()
        let d = makeDisplay(kind ?? automaticKind())
        display = d
        row.insertArrangedSubview(d, at: i)
        let rows = knobs.count > 6 ? 2 : 1
        let size = FaceplateDisplay.size(displayKind, rows: rows)
        displaySize = [d.widthAnchor.constraint(equalToConstant: size.width), d.heightAnchor.constraint(equalToConstant: size.height)]
        NSLayoutConstraint.activate(displaySize)
    }

    /// EQ bands found in the plug-in's parameters (EqBands), shown as handles on the response screen.
    private var eqBands: [EqBand] = []
    private func findBands() {
        eqBands = EqBands.find(allParameters.map { EqBands.Param(id: $0.id, title: fixedString($0.title), steps: $0.step_count, readOnly: $0.read_only) })
    }
    private func bandMarkers() -> [ResponseScreen.Marker] {
        eqBands.compactMap { b in
            guard let hz = b.fixedHz ?? b.freq.flatMap({ current($0) }).flatMap({ EqBands.hz(display($0)) }) else { return nil }
            let db = b.gain.flatMap { current($0) }.flatMap { EqBands.db(fixedString($0.display)) }
            let on = b.enable.flatMap { current($0) }.map { ($0.value >= 0.5) != b.enableInverted } ?? true
            return ResponseScreen.Marker(hz: hz, db: db, label: b.label, on: on, fixedFrequency: b.freq == nil)
        }
    }
    /// Text of parameter `id` at normalized `v`.
    private func text(_ id: UInt32, _ v: Double) -> String? {
        var buf = [CChar](repeating: 0, count: 64)
        guard dalnok_plugin_parameter_text(session.engine.handle, slot, id, v, &buf, 64) == DALNOK_OK else { return nil }
        let t = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let u = current(id).map { fixedString($0.units) } ?? ""
        return u.isEmpty || t.contains(u) ? t : "\(t) \(u)"
    }
    /// The normalized value at which the plug-in shows `target` (its value text read back through `parse`), found by
    /// bisection; works for any monotonic mapping without knowing it.
    private func normalized(_ id: UInt32, for target: Double, parse: (String) -> Double?) -> Double? {
        guard let v0 = text(id, 0).flatMap(parse), let v1 = text(id, 1).flatMap(parse), v0 != v1 else { return nil }
        let rising = v1 > v0
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            guard let v = text(id, mid).flatMap(parse) else { return nil }
            if (v < target) == rising { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
    private func bandDragged(_ i: Int, hz: Double, db: Double) {
        guard eqBands.indices.contains(i) else { return }
        let b = eqBands[i]
        if let f = b.freq, let v = normalized(f, for: hz, parse: EqBands.hz) { set(f, v) }
        if let g = b.gain, let v = normalized(g, for: db, parse: EqBands.db) { set(g, v) }
        refreshValues()
    }
    private func bandScrolled(_ i: Int, _ delta: Double) {
        guard eqBands.indices.contains(i), let q = eqBands[i].q, let p = current(q) else { return }
        set(q, p.value + delta * 0.25)
        refreshValues()
    }
    private func bandToggled(_ i: Int) {
        guard eqBands.indices.contains(i), let e = eqBands[i].enable, let p = current(e) else { return }
        set(e, p.value >= 0.5 ? 0 : 1)
        refreshValues()
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

    @objc private func foldTapped() { session.setPluginFolded(trackId, slot, true) }

    // MARK: Folding and arrival/departure animations

    /// Puts the body in the unit: pinned on every side, or (during a transition) at a fixed width, clipped by the unit.
    private func attachBody(width: CGFloat? = nil) {
        if bodyStack.superview !== self { addSubview(bodyStack, positioned: .below, relativeTo: nil) }
        NSLayoutConstraint.deactivate(bodyConstraints)
        var cs = [bodyStack.leadingAnchor.constraint(equalTo: leadingAnchor),
                  bodyStack.topAnchor.constraint(equalTo: topAnchor), bodyStack.bottomAnchor.constraint(equalTo: bottomAnchor)]
        cs.append(width.map { bodyStack.widthAnchor.constraint(equalToConstant: $0) } ?? bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor))
        bodyConstraints = cs
        NSLayoutConstraint.activate(cs)
    }
    private func attachStrip() {
        if strip.superview !== self { addSubview(strip) }
        NSLayoutConstraint.deactivate(stripConstraints)
        let w = strip.widthAnchor.constraint(equalToConstant: FoldStrip.width)
        w.priority = .defaultHigh // a transition's width wins while it runs
        stripConstraints = [strip.leadingAnchor.constraint(equalTo: leadingAnchor), strip.trailingAnchor.constraint(equalTo: trailingAnchor),
                            // Warm Analog: level with the pedals, below the units' header row.
                            strip.topAnchor.constraint(equalTo: topAnchor, constant: Analog.on ? 20 : 0), strip.bottomAnchor.constraint(equalTo: bottomAnchor), w]
        NSLayoutConstraint.activate(stripConstraints)
        refreshStrip()
    }
    private func refreshStrip() {
        strip.engaged = !bypassed
        strip.loaded = loaded
        strip.look = pedal?.look
    }
    /// A picture of a view's current pixels on a layer (the face that rotates or fades away while the new one arrives).
    private func snapshot(_ v: NSView) -> CALayer? {
        guard v.bounds.width > 0, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let l = CALayer()
        l.contents = rep.cgImage
        l.frame = v.frame
        l.zPosition = 200
        return l
    }
    /// The width this unit takes when laid out normally.
    private var naturalWidth: CGFloat {
        if folded { return FoldStrip.width }
        return max(fittingSize.width, minWidth.constant)
    }
    /// Animates the unit's width from `from` to `to` with a temporary constraint, then hands layout back.
    private func transition(from: CGFloat, to: CGFloat, duration: Double = 0.34, done: @escaping () -> Void) {
        transitionWidth?.isActive = false
        minWidth.isActive = false
        let c = widthAnchor.constraint(equalToConstant: from)
        c.isActive = true
        transitionWidth = c
        transitionDone = done
        transitionToken += 1
        let token = transitionToken
        transitioning = true
        layer?.masksToBounds = true
        superview?.layoutSubtreeIfNeeded()
        Motion.views(duration, {
            c.animator().constant = to
            self.superview?.layoutSubtreeIfNeeded()
        }, completion: { [weak self] in
            MainActor.assumeIsolated { self?.finishTransition(token) }
        })
    }
    private var transitionDone: (() -> Void)?
    private var transitionToken = 0
    /// Ends the running transition (its animation finished, or a newer change needs the unit settled now).
    func finishTransition(_ token: Int? = nil) {
        guard transitioning, token == nil || token == transitionToken, let c = transitionWidth else { return }
        c.isActive = false
        transitionWidth = nil
        transitioning = false
        minWidth.isActive = !folded
        applySelection() // restores masksToBounds = false and the glow
        let done = transitionDone
        transitionDone = nil
        done?()
        var v: NSView? = superview
        while let s = v, !(s is DevicePanel) { v = s.superview }
        v?.needsLayout = true
    }
    private static func perspective(_ angle: CGFloat) -> CATransform3D {
        var t = CATransform3DIdentity
        t.m34 = -1 / 420
        return CATransform3DRotate(t, angle, 0, 1, 0)
    }

    /// Folds or unfolds. Warm Analog turns the stomp box onto its side edge (a quarter turn about its upright axis, in
    /// perspective) while the space it took closes up; Graphite slides the faceplate shut onto a slim rack blank.
    func setFolded(_ f: Bool, animated: Bool) {
        guard f != folded else { return }
        folded = f
        foldButton.setAccessibilityLabel(f ? "Unfold" : "Fold")
        let animate = animated && !Motion.reduced && window != nil
        let from = bounds.width
        let outgoing = animate ? snapshot(f ? bodyStack : strip) : nil
        if f {
            bodyStack.removeFromSuperview()
            bodyConstraints = []
            minWidth.isActive = false
            attachStrip()
        } else {
            strip.removeFromSuperview()
            stripConstraints = []
            attachBody()
            minWidth.isActive = true
        }
        guard animate, let layer else { return }
        let to = naturalWidth
        if !f { attachBody(width: to) } // full width inside the narrow unit while it opens
        let incoming: NSView = f ? strip : bodyStack
        incoming.wantsLayer = true
        if let outgoing {
            layer.addSublayer(outgoing)
            Motion.centerAnchor(outgoing)
            let away = CABasicAnimation(keyPath: Analog.on ? "transform" : "opacity")
            if Analog.on {
                away.fromValue = CATransform3DIdentity
                away.toValue = Self.perspective(f ? .pi / 2 : -.pi / 2)
            } else { away.fromValue = 1; away.toValue = 0 }
            away.duration = 0.2
            away.timingFunction = CAMediaTimingFunction(name: .easeIn)
            away.fillMode = .forwards
            away.isRemovedOnCompletion = false
            outgoing.add(away, forKey: "fold")
        }
        if let l = incoming.layer {
            Motion.centerAnchor(l)
            let arrive = CABasicAnimation(keyPath: Analog.on ? "transform" : "opacity")
            if Analog.on {
                arrive.fromValue = Self.perspective(f ? -.pi / 2 : .pi / 2)
                arrive.toValue = CATransform3DIdentity
            } else { arrive.fromValue = 0; arrive.toValue = 1 }
            arrive.beginTime = CACurrentMediaTime() + 0.14
            arrive.duration = 0.22
            arrive.timingFunction = CAMediaTimingFunction(name: .easeOut)
            arrive.fillMode = .backwards
            l.add(arrive, forKey: "fold")
        }
        transition(from: from, to: to) { [weak self] in
            outgoing?.removeFromSuperlayer()
            if let self, !self.folded { self.attachBody() }
        }
    }

    /// A unit just added to the chain: it opens up its place (the neighbours make room) and settles in. Warm Analog:
    /// the pedal is set down on the board with a small bounce; Graphite: the faceplate slides in and fades up.
    func animateArrival() {
        guard !Motion.reduced, window != nil, let layer else { return }
        let to = naturalWidth
        if !folded { attachBody(width: to) }
        let drop = CAKeyframeAnimation(keyPath: Analog.on ? "transform.translation.y" : "transform.translation.x")
        drop.values = Analog.on ? [36, 0, 5, 0] : [-18, 0]
        drop.keyTimes = Analog.on ? [0, 0.62, 0.82, 1] : [0, 1]
        drop.duration = Analog.on ? 0.42 : 0.3
        drop.timingFunctions = Analog.on ? [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
                                         : [CAMediaTimingFunction(name: .easeOut)]
        layer.add(drop, forKey: "arrive")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.25
        layer.add(fade, forKey: "arriveFade")
        transition(from: 0, to: to, duration: 0.3) { [weak self] in
            if let self, !self.folded { self.attachBody() }
        }
    }

    /// A unit removed from the chain: it lifts off (Warm Analog) or fades back (Graphite) while its neighbours close the
    /// gap, then leaves the panel. `done` runs once it has gone (at once with Reduce Motion).
    func animateDeparture(_ done: @escaping () -> Void) {
        guard !Motion.reduced, window != nil, let layer else { done(); return }
        let from = bounds.width
        if !folded { attachBody(width: from) }
        let lift = CABasicAnimation(keyPath: Analog.on ? "transform.translation.y" : "transform.scale")
        lift.fromValue = Analog.on ? 0 : 1
        lift.toValue = Analog.on ? 40 : 0.9
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        for a in [lift, fade] {
            a.duration = 0.26
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: a.keyPath)
        }
        transition(from: from, to: 0, duration: 0.3) { done() }
    }

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
        etchedTitle.dimmed = !loaded // lettering is cut into the metal: bypass doesn't change it
        pedal?.engaged = loaded && !off
        if folded { refreshStrip() }
        if pedal == nil {
            // Graphite: bypass turns the unit's lights off (LEDs, screens, meter lamps) and sets it back slightly.
            for k in knobs { (k.knob as? FaceplateControl)?.dimmed = off }
            inMeter.poweredOff = off; outMeter.poweredOff = off
            (display as? FaceplateScreen)?.poweredOff = off
            // New controls (a rebuilt faceplate) start at the current level, then fade toward the new state.
            if let level = lightLevel { setLights(level) }
            fadeLights(to: off ? 0 : 1)
            setRecessed(off)
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
            c.onChange = { [weak self, weak pedal] v in
                self?.set(id, v)
                guard let self, let now = self.current(id) else { return }
                c.toolTip = "\(fixedString(now.title)): \(self.display(now))"
                pedal?.screen.showValue(fixedString(now.title), self.display(now))
            }
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
        m.addItem(item("Show Controls", { [weak self] in self?.onShowControls?() }, enabled: loaded))
        m.addItem(item("Edit Controls…", { [weak self] in self?.editTapped(self?.openButton) }, enabled: loaded))
        m.addItem(item(folded ? "Unfold" : "Fold", { [weak self] in
            guard let self else { return }; self.session.setPluginFolded(self.trackId, self.slot, !self.folded)
        }))
        m.addItem(.separator())
        m.addItem(item("Move Left (Earlier in Chain)", { [weak self] in self?.onMove?(-1) }, enabled: i > 0))
        m.addItem(item("Move Right (Later in Chain)", { [weak self] in self?.onMove?(1) }, enabled: i < chain.count - 1))
        m.addItem(item("Remove Plug-in", { [weak self] in guard let self else { return }; self.session.removePlugin(self.trackId, self.slot) }))
        if pedal != nil { m.addItem(.separator()); pedalLookItems(m) }
        if display != nil {
            m.addItem(.separator())
            let sub = NSMenu(), chosen = FaceplateDisplay.override(title.stringValue)
            sub.addItem(item("Automatic", { [weak self] in self?.chooseDisplay(nil) }, on: chosen == nil))
            sub.addItem(.separator())
            for k in FaceplateDisplay.Kind.allCases { sub.addItem(item(k.title, { [weak self] in self?.chooseDisplay(k) }, on: chosen == k)) }
            let parent = NSMenuItem(title: "Display", action: nil, keyEquivalent: ""); parent.submenu = sub; m.addItem(parent)
        }
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
        var point = point
        if recessed { // the layer is drawn scaled about the centre: map the click back onto the unscaled layout
            let c = CGPoint(x: frame.midX, y: frame.midY), s = Self.recessedScale
            guard frame.insetBy(dx: frame.width * (1 - s) / 2, dy: frame.height * (1 - s) / 2).contains(point) else { return nil }
            point = CGPoint(x: c.x + (point.x - c.x) / s, y: c.y + (point.y - c.y) / s)
        }
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
