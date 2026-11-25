// Guitar Studio's own editor (the plug-in window's Plug-in view): the rig as white modules snapped together in signal
// order on a quiet field. Each module has a main screen showing what it does and round screens for its controls, all
// lit by its measured level. Drag a module along the row to reorder it (the others close up); + adds one at the end;
// right-click for Turn Off / Move / Replace With / Remove. A long rig continues on further rows.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The editors Dalnok draws for its own plug-ins (nil: the plug-in has none).
@MainActor
enum BuiltinEditors {
    static func plugin(_ path: String) -> String { path.hasPrefix("dalnok:") ? String(path.dropFirst(7)) : path }
    static func has(_ path: String) -> Bool { ["guitar-studio", "guitar-tune"].contains(plugin(path)) }
    static func make(_ path: String, engine: Engine, slot: Int32) -> NSView? {
        switch plugin(path) {
        case "guitar-studio": GuitarStudioEditor(engine: engine, slot: slot)
        case "guitar-tune": GuitarTuneEditor(engine: engine, slot: slot)
        default: nil
        }
    }
}

@MainActor
final class GuitarStudioEditor: NSView {
    static let preferredSize = CGSize(width: 1320, height: 700)
    let rig: StudioRig
    let stage: SpaceStage
    let header = SpaceHeader()
    private var timer: Timer?
    private var shape: [Int] = []
    private let start = Date()
    /// Meter readings: the last raw value per meter and how many polls it has stayed the same (a stopped engine
    /// stops updating them, so a level that never changes is treated as silence).
    private var raw: [UInt32: (value: Double, same: Int)] = [:]

    init(engine: Engine, slot: Int32) {
        rig = StudioRig(engine: engine, slot: slot)
        stage = SpaceStage(rig: rig)
        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize))
        identifier = NSUserInterfaceItemIdentifier("guitar-studio-editor")
        appearance = NSAppearance(named: .aqua)
        header.rig = rig
        header.build()
        for v in [header, stage] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: SpaceHeader.height),
            stage.topAnchor.constraint(equalTo: header.bottomAnchor), stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor), stage.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rig.onMessage = { [weak self] in self?.header.status = $0 }
        NotificationCenter.default.addObserver(self, selector: #selector(rigChanged(_:)), name: StudioRig.changed, object: nil)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Space.field(ctx, bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { timer = nil; return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }
    @objc private func rigChanged(_ n: Notification) {
        guard (n.object as? NSNumber)?.int32Value == rig.slot else { return }
        tick()
    }

    /// A meter's level (0-1), or 0 once it has stopped moving.
    func level(_ id: UInt32) -> CGFloat {
        let v = rig.value(id)
        var r = raw[id] ?? (v, 0)
        r.same = r.value == v ? r.same + 1 : 0
        r.value = v
        raw[id] = r
        return r.same > 6 ? 0 : CGFloat(rig.level(id))
    }

    /// Follows the engine: rebuilds when modules change (here, in the device panel, by undo or a preset), otherwise
    /// moves the controls and lights.
    func tick() {
        let next = (0..<StudioLayout.slots).map { StudioLayout.type(rig.value(StudioLayout.typeId($0))) }
        if next != shape { reload() }
        let time = Motion.reduced ? 0 : Date().timeIntervalSince(start)
        let input = level(StudioLayout.inputLevel)
        for m in stage.modules { m.update(time: time, level: level(StudioLayout.levelId(m.slot)), input: input) }
        header.update(input: input, output: stage.modules.last.map { level(StudioLayout.levelId($0.slot)) } ?? input)
    }
    func reload() {
        shape = (0..<StudioLayout.slots).map { StudioLayout.type(rig.value(StudioLayout.typeId($0))) }
        stage.load(rig.slots().enumerated().map { SpaceModule(rig: rig, slot: $1, index: $0) })
        header.update(input: 0, output: 0)
    }
}

/// The title, the factory rigs and the input and output levels, across the top.
@MainActor
final class SpaceHeader: NSView {
    static let height: CGFloat = 84
    weak var rig: StudioRig?
    var status = "" { didSet { needsDisplay = true } }
    private(set) var dials: [SpaceDial] = []
    let presets = NSButton(title: "", target: nil, action: nil)
    private var levels: (CGFloat, CGFloat) = (0, 0)

    override var isFlipped: Bool { true }
    func build() {
        guard let rig else { return }
        presets.isBordered = false
        presets.target = self
        presets.action = #selector(showPresets)
        presets.toolTip = "Load a factory rig (replaces every module)"
        presets.setAccessibilityLabel("Factory rigs")
        addSubview(presets)
        for (id, name) in [(StudioLayout.input, "Input"), (StudioLayout.output, "Output")] {
            let d = SpaceDial(name: name, picture: .arc)
            d.accent = id == StudioLayout.input ? Space.blue : Space.orange
            d.defaultValue = rig.parameter(id)?.default_value ?? 0.5
            d.valueText = { [weak rig] in rig?.parameter(id).map { fixedString($0.display) } ?? "" }
            d.onChange = { [weak rig] v in rig?.set(id, v) }
            d.identifier = NSUserInterfaceItemIdentifier("space-level-\(id)")
            d.setAccessibilityLabel("Guitar Studio \(name)")
            addSubview(d)
            dials.append(d)
        }
    }
    override func layout() {
        super.layout()
        let s: CGFloat = 0.72, size = SpaceDial.size
        for (i, d) in dials.enumerated() {
            d.frame = CGRect(x: bounds.width - 24 - CGFloat(2 - i) * (size.width * s + 10), y: 8, width: size.width * s, height: size.height * s)
            d.bounds = CGRect(origin: .zero, size: size)
        }
        presets.frame = CGRect(x: 230, y: 26, width: 260, height: 28)
    }
    func update(input: CGFloat, output: CGFloat) {
        guard let rig else { return }
        for (d, id) in zip(dials, [StudioLayout.input, StudioLayout.output]) where !d.dragging { d.value = rig.value(id) }
        if dials.count == 2 { dials[0].light = input; dials[1].light = output }
        let name = rig.presetStatus().map { $0.name + ($0.edited ? " •" : "") } ?? "Choose a rig"
        let title = NSAttributedString(string: name + "  ▾", attributes: [.font: Space.font(14, .semibold), .foregroundColor: Space.ink])
        if presets.attributedTitle != title { presets.attributedTitle = title; presets.alignment = .left }
        if levels != (input, output) { levels = (input, output); needsDisplay = true }
    }
    @objc private func showPresets() {
        rig?.presetMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: presets.bounds.maxY + 4), in: presets)
    }
    override func draw(_ dirtyRect: NSRect) {
        Space.text("GUITAR STUDIO", CGRect(x: 52, y: 26, width: 170, height: 28), font: Space.font(14, .bold), color: Space.ink, align: .left, kern: 3.5)
        if let ctx = NSGraphicsContext.current?.cgContext {
            Space.lamp(ctx, CGPoint(x: 36, y: 40), Space.orange, lit: true, intensity: 0.5 + 0.5 * max(levels.0, levels.1))
        }
        Space.text(status, CGRect(x: 520, y: 26, width: max(0, bounds.width - 760), height: 28), font: Space.font(11, .medium), color: Space.inkDim, align: .left)
    }
}

/// One module: white plastic with a main screen and a row of round screens (its controls).
@MainActor
final class SpaceModule: NSView {
    static let height: CGFloat = 524
    let rig: StudioRig
    let slot: Int, index: Int, type: Int
    let name: String
    private(set) var dials: [SpaceDial] = []
    let power = SpacePower()
    /// Round at the outer ends of a row; snapped edges are nearly square.
    var roundLeft = true { didSet { if roundLeft != oldValue { needsDisplay = true } } }
    var roundRight = true { didSet { if roundRight != oldValue { needsDisplay = true } } }
    var lifted = false { didSet { needsDisplay = true } }
    var onDrag: ((SpaceModule, NSEvent, NSEvent.EventType) -> Void)?
    private(set) var state: SpaceScreen.State
    private var isOn = true

    /// Pedal-shaped: two or three controls across, rows below the screen, the footswitch at the foot.
    static func columns(_ n: Int) -> Int { n <= 2 ? max(1, n) : n == 4 ? 2 : 3 }
    static func width(dials n: Int) -> CGFloat { max(236, CGFloat(columns(n)) * 76 + 36) }

    init(rig: StudioRig, slot: Int, index: Int) {
        self.rig = rig
        self.slot = slot
        self.index = index
        type = StudioLayout.type(rig.value(StudioLayout.typeId(slot)))
        name = StudioLayout.catalog[type].name
        let knobs = rig.knobs(slot: slot)
        state = .init(module: name, knobs: knobs.map(\.value), level: 0, input: 0, on: true, time: 0)
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width(dials: knobs.count), height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Slot \(index + 1): \(name)")
        identifier = NSUserInterfaceItemIdentifier("space-module-\(slot)")
        for k in knobs {
            let d = SpaceDial(name: RigNames.short[k.name] ?? k.name, picture: DialPicture.of(name: k.name, steps: k.steps))
            d.steps = k.steps
            d.defaultValue = k.defaultValue
            d.value = k.value
            d.identifier = NSUserInterfaceItemIdentifier("space-dial-\(k.id)")
            d.setAccessibilityLabel("\(name) \(k.name)")
            d.toolTip = "\(k.name): drag up or down (⇧ for fine), double-click for the default"
            let id = k.id
            d.valueText = { [weak rig] in rig?.parameter(id).map { fixedString($0.display) } ?? "" }
            d.onChange = { [weak self] v in self?.rig.set(id, v); self?.needsDisplay = true }
            addSubview(d)
            dials.append(d)
        }
        power.onPress = { [weak self] in self.map { $0.rig.toggle($0.index) } }
        power.setAccessibilityLabel("\(name) on/off")
        addSubview(power)
        layoutControls()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { rig.moduleMenu(index) }

    var screenRect: CGRect { CGRect(x: 18, y: 54, width: bounds.width - 36, height: 136) }
    private func layoutControls() {
        let size = SpaceDial.size, cols = Self.columns(dials.count)
        let rows = (dials.count + cols - 1) / cols
        let rowH: CGFloat = 100, top = 206 + (2 - CGFloat(rows)) * rowH / 2
        for (i, d) in dials.enumerated() {
            let row = i / cols, inRow = min(cols, dials.count - row * cols)
            let step = (bounds.width - 24) / CGFloat(cols)
            let x0 = (bounds.width - step * CGFloat(inRow)) / 2
            d.frame = CGRect(x: x0 + step * (CGFloat(i - row * cols) + 0.5) - size.width / 2, y: top + CGFloat(row) * rowH, width: size.width, height: size.height)
        }
        power.frame.origin = CGPoint(x: bounds.midX - power.frame.width / 2, y: bounds.height - 100)
    }

    func update(time: Double, level: CGFloat, input: CGFloat) {
        let on = rig.value(StudioLayout.onId(slot)) >= 0.5
        var knobs = state.knobs
        for (i, d) in dials.enumerated() {
            let v = rig.value(StudioLayout.knobId(slot, i))
            if !d.dragging { d.value = v }
            if i < knobs.count { knobs[i] = d.value }
            d.time = time
            d.light = on ? level : 0
        }
        power.isOn = on
        power.light = level
        let moving = !Motion.reduced && on && (level > 0.01 || animatesIdle)
        if knobs != state.knobs || on != isOn || abs(level - state.level) > 0.01 || moving {
            state = .init(module: name, knobs: knobs, level: level, input: input, on: on, time: time)
            isOn = on
            needsDisplay = true
        }
    }
    /// Pictures that move with their own settings even in silence (rates, sweeps, echoes).
    private var animatesIdle: Bool { ["Chorus", "Flanger", "Phaser", "Vibrato", "Tremolo", "Delay", "Wah", "Reverb"].contains(name) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let body = Space.capsule(bounds.insetBy(dx: 0.5, dy: 0.5), left: roundLeft ? 22 : 14, right: roundRight ? 22 : 14)
        Space.plastic(ctx, body, lift: lifted ? 1.8 : 1)
        if !roundLeft { // the seam where this module snaps to the one before
            ctx.setFillColor(Space.hex(0x9a9ca3, 0.45).cgColor); ctx.fill(CGRect(x: 0, y: 10, width: 1, height: bounds.height - 20))
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 1, y: 10, width: 1, height: bounds.height - 20))
        }
        Space.text(String(format: "%02d", index + 1), CGRect(x: 22, y: 18, width: 26, height: 20), font: Space.mono(10), color: Space.inkDim, align: .left)
        Space.text(name.uppercased(), CGRect(x: 48, y: 18, width: bounds.width - 66, height: 20), font: Space.font(13, .regular), color: Space.ink,
                   align: .left, kern: 3.2)
        Space.plinth(ctx, Space.rounded(screenRect.insetBy(dx: -7, dy: -7), 16))
        let screen = Space.rounded(screenRect, 11)
        Space.glass(ctx, screen, glow: Space.orange, glowLevel: state.on ? state.level : 0)
        ctx.saveGState(); ctx.addPath(screen); ctx.clip()
        SpaceScreen.draw(ctx, screenRect.insetBy(dx: 6, dy: 6), state)
        ctx.restoreGState()
        // Seams: under the screen, and above the footswitch.
        for y in [CGFloat(200), bounds.height - 112] {
            ctx.setFillColor(Space.hex(0x9a9ca3, 0.28).cgColor); ctx.fill(CGRect(x: 26, y: y, width: bounds.width - 52, height: 1))
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 26, y: y + 1, width: bounds.width - 52, height: 1))
        }
        Space.text("DALNOK", CGRect(x: 0, y: bounds.height - 22, width: bounds.width, height: 12), font: Space.font(7.5, .bold),
                   color: Space.inkDim, kern: 3)
    }

    // Dragging the body (not a control) moves the module along the rig.
    override func mouseDown(with event: NSEvent) { onDrag?(self, event, .leftMouseDown) }
    override func mouseDragged(with event: NSEvent) { onDrag?(self, event, .leftMouseDragged) }
    override func mouseUp(with event: NSEvent) { onDrag?(self, event, .leftMouseUp) }
}

/// The empty socket after the last module: click to add one.
@MainActor
final class SpaceAddSlot: NSView {
    static let width: CGFloat = 150
    var onPress: (() -> Void)?
    private var hovering = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add Module")
        toolTip = "Add a module at the end of the rig"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 16, dy: 8)
        let p = Space.rounded(r, 24)
        ctx.addPath(p); ctx.setFillColor(NSColor.white.withAlphaComponent(hovering ? 0.75 : 0.35).cgColor); ctx.fillPath()
        ctx.saveGState(); ctx.setLineDash(phase: 0, lengths: [5, 5]); ctx.addPath(p)
        ctx.setStrokeColor(Space.hex(0x9a9ca3, hovering ? 0.9 : 0.55).cgColor); ctx.setLineWidth(1.4); ctx.strokePath(); ctx.restoreGState()
        let c = CGPoint(x: r.midX, y: r.midY - 10)
        let well = CGPath(ellipseIn: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44), transform: nil)
        Space.glass(ctx, well)
        let plus = CGMutablePath()
        plus.move(to: CGPoint(x: c.x - 8, y: c.y)); plus.addLine(to: CGPoint(x: c.x + 8, y: c.y))
        plus.move(to: CGPoint(x: c.x, y: c.y - 8)); plus.addLine(to: CGPoint(x: c.x, y: c.y + 8))
        Space.glowStroke(ctx, plus, Space.orange, width: 1.8)
        Space.glassShine(ctx, well)
        Space.text("ADD MODULE", CGRect(x: r.minX, y: c.y + 34, width: r.width, height: 16), font: Space.font(9, .bold), color: Space.ink, kern: 1.5)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() } }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// The modules in rows, scaled to fit; reordering by drag.
@MainActor
final class SpaceStage: NSView {
    let rig: StudioRig
    private(set) var modules: [SpaceModule] = []
    let add = SpaceAddSlot()
    private(set) var scale: CGFloat = 1
    private var drag: (module: SpaceModule, start: CGPoint, origin: CGPoint, moved: Bool)?
    /// Where a dragged module would land.
    private(set) var dropIndex: Int?
    static let gap: CGFloat = 46, margin: CGFloat = 48, joint: CGFloat = 7
    /// The black chassis under each row of modules (stage coordinates).
    private var chassis: [CGRect] = []
    private typealias Item = (view: NSView, width: CGFloat)

    init(rig: StudioRig) {
        self.rig = rig
        super.init(frame: .zero)
        add.onPress = { [weak self] in
            guard let self, let menu = self.rig.addMenu() else { return }
            menu.popUp(positioning: nil, at: CGPoint(x: 20, y: self.add.bounds.midY), in: self.add)
        }
        addSubview(add)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Guitar Studio rig, in signal order")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func load(_ next: [SpaceModule]) {
        modules.forEach { $0.removeFromSuperview() }
        modules = next
        for m in modules {
            m.onDrag = { [weak self] m, e, t in self?.dragged(m, e, t) }
            addSubview(m, positioned: .below, relativeTo: add)
        }
        add.isHidden = modules.count >= StudioLayout.slots
        arrange(modules)
    }
    override func layout() {
        super.layout()
        if drag == nil { arrange(modules) }
    }

    /// Lays out `order` (and the add socket) in as many rows (1-3) as shows them largest, snapping neighbours.
    private func arrange(_ order: [SpaceModule]) {
        for (view, frame, left, right) in frames(order) {
            if let m = view as? SpaceModule {
                m.roundLeft = left; m.roundRight = right
                if drag?.module !== m { m.frame = frame }
            } else { view.frame = frame }
            view.bounds = CGRect(origin: .zero, size: CGSize(width: frame.width / scale, height: SpaceModule.height))
        }
    }
    /// Where each item of `order` (then the add socket) goes, and whether it ends its row on each side.
    private func frames(_ order: [SpaceModule]) -> [(NSView, CGRect, Bool, Bool)] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        var items: [Item] = order.map { ($0, SpaceModule.width(dials: $0.dials.count)) }
        if !add.isHidden { items.append((add, SpaceAddSlot.width)) }
        func width(_ row: ArraySlice<Item>) -> CGFloat { row.reduce(2 * Self.margin - Self.joint) { $0 + $1.width + Self.joint } }
        func split(_ n: Int) -> [ArraySlice<Item>] {
            let target = width(items[...]) / CGFloat(n)
            var rows: [ArraySlice<Item>] = []
            var start = 0
            for i in items.indices where rows.count < n - 1 && i > start && width(items[start...i]) > target * 1.06 {
                rows.append(items[start..<i]); start = i
            }
            rows.append(items[start...])
            return rows
        }
        let rowH = SpaceModule.height + Self.gap
        var best: (scale: CGFloat, rows: [ArraySlice<Item>]) = (0, [items[...]])
        for n in 1...3 {
            let rows = split(n)
            let s = min(min(1.15, (bounds.height - 20) / (CGFloat(rows.count) * rowH)), bounds.width / (rows.map { width($0) }.max() ?? 1))
            if s > best.scale * 1.02 { best = (s, rows) }
        }
        scale = best.scale
        var out: [(NSView, CGRect, Bool, Bool)] = []
        var frames: [CGRect] = []
        let top = (bounds.height / scale - CGFloat(best.rows.count) * rowH) / 2 + Self.gap / 2
        for (r, row) in best.rows.enumerated() {
            var x = (bounds.width / scale - width(row)) / 2 + Self.margin
            let y = top + CGFloat(r) * rowH
            let inRow = row.compactMap { $0.view as? SpaceModule }
            let x0 = x
            for item in row {
                out.append((item.view, CGRect(x: x * scale, y: y * scale, width: item.width * scale, height: SpaceModule.height * scale),
                            item.view === inRow.first, item.view === inRow.last))
                x += item.width + Self.joint
            }
            let modulesWidth = row.filter { $0.view is SpaceModule }.reduce(-Self.joint) { $0 + $1.width + Self.joint }
            if modulesWidth > 0 {
                frames.append(CGRect(x: x0 - Self.joint, y: y - Self.joint, width: modulesWidth + 2 * Self.joint, height: SpaceModule.height + 2 * Self.joint))
            }
        }
        chassis = frames
        needsDisplay = true
        return out
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for r in chassis {
            let rect = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
            let p = Space.rounded(rect, 28 * scale)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 8 * scale, height: -16 * scale), blur: 34 * scale, color: Space.hex(0x000000, 0.35).cgColor)
            ctx.addPath(p); ctx.setFillColor(Space.hex(0x0d0d0e).cgColor); ctx.fillPath()
            ctx.restoreGState()
            Space.innerShadow(ctx, p, alpha: 0.35, blur: 1.5, offset: CGSize(width: 1, height: -1), color: .white)
        }
    }

    /// The others' places with the dragged module taken out (fixed for the drag, so the landing can't oscillate).
    private var homes: [CGRect] = []
    private func dragged(_ m: SpaceModule, _ e: NSEvent, _ t: NSEvent.EventType) {
        let p = convert(e.locationInWindow, from: nil)
        switch t {
        case .leftMouseDown:
            drag = (m, p, m.frame.origin, false)
        case .leftMouseDragged:
            guard var d = drag else { return }
            if !d.moved, hypot(p.x - d.start.x, p.y - d.start.y) < 5 { return }
            if !d.moved {
                d.moved = true
                m.lifted = true
                addSubview(m, positioned: .above, relativeTo: nil)
                homes = frames(modules.filter { $0 !== m }).filter { $0.0 is SpaceModule }.map(\.1)
            }
            drag = d
            m.frame.origin = CGPoint(x: d.origin.x + p.x - d.start.x, y: d.origin.y + p.y - d.start.y)
            let to = landing(for: m)
            if to != dropIndex { // the others close up around where it would land
                dropIndex = to
                var order = modules.filter { $0 !== m }
                order.insert(m, at: to)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.reduced ? 0 : 0.16
                    ctx.allowsImplicitAnimation = true
                    arrange(order)
                }
            }
            m.roundLeft = true; m.roundRight = true
        case .leftMouseUp:
            guard let d = drag else { return }
            drag = nil
            m.lifted = false
            let to = dropIndex ?? m.index
            dropIndex = nil
            if d.moved, to != m.index { rig.move(from: m.index, to: to) } else { arrange(modules) }
        default: break
        }
    }
    /// How many of the others come before the dragged module's centre, reading the rows left to right, top to bottom.
    private func landing(for m: SpaceModule) -> Int {
        let c = CGPoint(x: m.frame.midX, y: m.frame.midY), half = SpaceModule.height * scale / 2
        return homes.filter { h in h.midY < c.y - half || (abs(h.midY - c.y) <= half && h.midX < c.x) }.count
    }
}

/// Short names for controls whose full names crowd a round screen's label.
enum RigNames {
    static let short: [String: String] = ["Frequency": "Freq", "Resonance": "Reso", "Modulation": "Mod", "Threshold": "Thresh"]
}
