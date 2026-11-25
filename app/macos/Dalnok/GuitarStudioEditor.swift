// Guitar Studio's own editor (the plug-in window's Plug-in view): the whole rig on a stage, in signal order, each
// module as its unit with its controls, patched together. Above it: the factory rigs, the slot strip (reorder, add,
// switch, replace) and the input and output levels.
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
    static let preferredSize = CGSize(width: 1400, height: 640)
    let rig: StudioRig
    let strip: StudioStrip
    let stage = RigStage()
    private let scroll = NSScrollView()
    private let presets = NSPopUpButton(frame: .zero, pullsDown: true)
    private let status = NSTextField(labelWithString: "")
    private var levels: [RigKnob] = []
    private var timer: Timer?
    private var shape: [Int] = []

    init(engine: Engine, slot: Int32) {
        rig = StudioRig(engine: engine, slot: slot)
        strip = StudioStrip(rig: rig)
        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize))
        identifier = NSUserInterfaceItemIdentifier("guitar-studio-editor")
        wantsLayer = true
        layer?.backgroundColor = RigPaint.hex(0x0c0c0d).cgColor
        rig.onMessage = { [weak self] in self?.status.stringValue = $0 }

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = RigPaint.hex(0x18191b).cgColor
        presets.addItem(withTitle: "Factory Rigs")
        for p in StudioPreset.factory {
            presets.addItem(withTitle: p.name)
            presets.lastItem?.representedObject = p.name
        }
        presets.target = self
        presets.action = #selector(pickPreset(_:))
        presets.controlSize = .small
        presets.toolTip = "Load a factory rig (replaces every module)"
        presets.setAccessibilityLabel("Factory rigs")
        status.font = Theme.ui(10)
        status.textColor = RigPaint.hex(0x9a9ea3)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (id, name) in [(StudioLayout.input, "Input"), (StudioLayout.output, "Output")] {
            let k = RigKnob(diameter: 22, style: .knurled(RigPaint.hex(0xd8dbde)), name: name)
            k.labelColor = RigPaint.hex(0xc9ccd0)
            k.labelFont = RigPaint.font(["Futura-Bold"], 8)
            k.valueText = { [weak self] in self?.rig.parameter(id).map { fixedString($0.display) } ?? "" }
            k.onChange = { [weak self] v in self?.rig.set(id, v) }
            k.defaultValue = rig.parameter(id)?.default_value ?? 0.5
            k.identifier = NSUserInterfaceItemIdentifier("rig-level-\(id)")
            k.setAccessibilityLabel("Guitar Studio \(name)")
            k.translatesAutoresizingMaskIntoConstraints = false
            k.widthAnchor.constraint(equalToConstant: k.frame.width).isActive = true
            k.heightAnchor.constraint(equalToConstant: k.frame.height).isActive = true
            levels.append(k)
        }
        strip.appearance = NSAppearance(named: .darkAqua)
        strip.showsPreset = false
        let row = NSStackView(views: [presets, strip, status, levels[0], levels[1]])
        row.spacing = 12
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        strip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        strip.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        status.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)

        scroll.documentView = stage
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.scrollerStyle = .overlay
        stage.editor = self
        for v in [bar, scroll] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor), bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 58),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor), row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor), row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(rigChanged(_:)), name: StudioRig.changed, object: nil)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { timer = nil; return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }
    override func layout() {
        super.layout()
        stage.fit(height: scroll.contentSize.height)
    }

    @objc private func pickPreset(_ sender: NSPopUpButton) {
        guard let name = sender.selectedItem?.representedObject as? String, let p = StudioPreset.factory.first(where: { $0.name == name }) else { return }
        rig.apply(p)
    }
    @objc private func rigChanged(_ n: Notification) {
        guard (n.object as? NSNumber)?.int32Value == rig.slot else { return }
        tick()
    }

    /// Follows the engine: rebuilds the stage when modules change (here, in the device panel, by undo or a preset), and
    /// otherwise moves the controls to the current values.
    func tick() {
        let next = (0..<StudioLayout.slots).map { StudioLayout.type(rig.value(StudioLayout.typeId($0))) }
        if next != shape { reload() } else { stage.refresh() }
        strip.reload()
        for (k, id) in zip(levels, [StudioLayout.input, StudioLayout.output]) where !k.dragging { k.value = rig.value(id) }
        presets.title = rig.presetStatus().map { $0.name + ($0.edited ? " •" : "") } ?? "Factory Rigs"
    }
    func reload() {
        shape = (0..<StudioLayout.slots).map { StudioLayout.type(rig.value(StudioLayout.typeId($0))) }
        stage.load(rig.slots().enumerated().map { RigUnits.make(rig: rig, slot: $1, index: $0) })
        stage.fit(height: scroll.contentSize.height)
        strip.reload()
        presets.title = rig.presetStatus().map { $0.name + ($0.edited ? " •" : "") } ?? "Factory Rigs"
    }
}

/// The stage the units stand on: a dark wall with a light over each unit, a board floor, and the cables between them.
@MainActor
final class RigStage: NSView {
    weak var editor: GuitarStudioEditor?
    private(set) var units: [RigUnit] = []
    private var scale: CGFloat = 1
    private var lift: CGFloat = 0
    private let empty = NSTextField(labelWithString: "No modules: add one with + above, or pick a factory rig.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        empty.textColor = RigPaint.hex(0x8a8e93)
        empty.font = Theme.ui(13)
        addSubview(empty)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Guitar Studio rig, in signal order")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func load(_ next: [RigUnit]) {
        units.forEach { $0.removeFromSuperview() }
        units = next
        units.forEach(addSubview)
        empty.isHidden = !units.isEmpty
        needsLayout = true
        needsDisplay = true
    }
    func refresh() { units.forEach { $0.refresh() } }

    /// Rows of the stage, each a band as tall as its tallest unit allows (a long rig wraps onto further rows; the cable carries on).
    private var rows: [[RigUnit]] = []
    /// Each row's top and height in design units (the height follows its tallest unit).
    private var bands: [(top: CGFloat, height: CGFloat)] = []
    private static func bandHeight(_ row: [RigUnit]) -> CGFloat { max(330, (row.map(\.look.size.height).max() ?? 0) + 120) }
    static let floorDepth: CGFloat = 140, footInset: CGFloat = 20
    static let gap: CGFloat = 54, margin: CGFloat = 60
    private static func width(_ row: [RigUnit]) -> CGFloat { row.reduce(2 * margin - gap) { $0 + $1.look.size.width + gap } }
    /// Splits `units` into `n` runs in order, keeping the widest run as narrow as possible.
    private static func split(_ units: [RigUnit], _ n: Int) -> [[RigUnit]] {
        let target = width(units) / CGFloat(n)
        var out: [[RigUnit]] = [[]]
        for u in units {
            if out.count < n, !out[out.count - 1].isEmpty, width(out[out.count - 1] + [u]) > target * 1.08 { out.append([]) }
            out[out.count - 1].append(u)
        }
        return out
    }

    /// Lays the rig out in `height`: one row, or two or three when that shows the units larger. Drawn at the design
    /// scale times the chosen factor; any height left over goes to the wall above the first row.
    func fit(height: CGFloat) {
        guard height > 0 else { return }
        let visible = enclosingScrollView?.contentSize.width ?? bounds.width
        var best: (scale: CGFloat, rows: [[RigUnit]]) = (0, [units])
        for n in 1...min(3, max(1, units.count)) {
            let r = Self.split(units, n)
            let widest = r.map(Self.width).max() ?? 1
            let s = min(height / r.map(Self.bandHeight).reduce(0, +), visible / widest)
            if s > best.scale * 1.01 { best = (s, r) }
        }
        rows = best.rows
        // Never smaller than readable: scroll sideways instead.
        let total = rows.map(Self.bandHeight).reduce(0, +)
        scale = max(best.scale, min(height / total, 0.5))
        lift = height / scale - total
        bands = []
        var y = lift
        for row in rows { bands.append((y, Self.bandHeight(row))); y += Self.bandHeight(row) }
        var widest: CGFloat = visible / scale
        for (r, row) in rows.enumerated() {
            var x = max(Self.margin, (visible / scale - Self.width(row)) / 2 + Self.margin)
            let foot = bands[r].top + bands[r].height - Self.footInset
            for u in row {
                let s = u.look.size
                u.frame = CGRect(x: x * scale, y: (foot - s.height) * scale, width: s.width * scale, height: s.height * scale)
                u.bounds = CGRect(origin: .zero, size: s)
                x += s.width + Self.gap
            }
            widest = max(widest, x - Self.gap + Self.margin)
        }
        setFrameSize(CGSize(width: widest * scale, height: height))
        empty.sizeToFit()
        empty.frame.origin = CGPoint(x: (frame.width - empty.frame.width) / 2, y: (height - Self.floorDepth * scale) - 40)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        let w = bounds.width / scale
        ctx.setFillColor(RigPaint.hex(0x141517).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: lift + 1))
        let shown = rows.isEmpty ? [([RigUnit](), (top: CGFloat(0), height: bounds.height / scale))] : Array(zip(rows, bands))
        for (r, (row, band)) in shown.enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: band.top)
            drawBand(ctx, w, row, height: band.height, extraWall: r == 0 ? band.top : 0)
            ctx.restoreGState()
        }
        // Cables, unit to unit; at the end of a row the cable runs off the right and comes in on the next row's left.
        for (a, b) in zip(units, units.dropFirst()) {
            let p = a.convert(a.outJack, to: self), q = b.convert(b.inJack, to: self)
            let pa = CGPoint(x: p.x / scale, y: p.y / scale), qb = CGPoint(x: q.x / scale, y: q.y / scale)
            let rowOf = { (u: RigUnit) in self.rows.firstIndex { $0.contains { $0 === u } } ?? 0 }
            let ra = rowOf(a), rb = rowOf(b)
            let floorA = bands[ra].top + bands[ra].height - Self.footInset + 4
            if ra == rb {
                RigPaint.cable(ctx, from: pa, to: qb, floor: floorA, color: RigPaint.hex(0x151516))
            } else {
                let floorB = bands[rb].top + bands[rb].height - Self.footInset + 4
                RigPaint.cable(ctx, from: pa, to: CGPoint(x: w + 30, y: floorA + 6), floor: floorA, color: RigPaint.hex(0x151516))
                RigPaint.cable(ctx, from: CGPoint(x: -30, y: floorB + 6), to: qb, floor: floorB, color: RigPaint.hex(0x151516))
            }
        }
        ctx.restoreGState()
    }

    /// One row's wall, light, floor and pools of light, in design units with the row's top at 0.
    private func drawBand(_ ctx: CGContext, _ w: CGFloat, _ row: [RigUnit], height: CGFloat, extraWall: CGFloat) {
        let floorY = height - Self.floorDepth, footY = height - Self.footInset
        let wall = CGRect(x: 0, y: -extraWall, width: w, height: floorY + extraWall)
        ctx.setFillColor(RigPaint.hex(0x141517).cgColor); ctx.fill(wall)
        RigPaint.grain(ctx, wall, alpha: 0.5, scale: CGSize(width: 0.7, height: 0.7), blend: .softLight)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(2)
        var px: CGFloat = 0
        while px < w { ctx.move(to: CGPoint(x: px, y: -extraWall)); ctx.addLine(to: CGPoint(x: px, y: floorY)); px += 120 }
        ctx.strokePath()
        ctx.setBlendMode(.screen)
        for u in row {
            let cx = u.frame.midX / scale
            RigPaint.radial(ctx, CGPoint(x: cx, y: footY - u.look.size.height - 40), u.look.size.width * 0.9 + 80,
                            [RigPaint.hex(0xffe2b8, 0.2), RigPaint.hex(0xffd9a0, 0.05), .clear])
        }
        ctx.setBlendMode(.normal)
        let floor = CGRect(x: 0, y: floorY, width: w, height: height - floorY)
        ctx.saveGState(); ctx.clip(to: floor)
        ctx.drawLinearGradient(RigPaint.gradient([RigPaint.hex(0x24180f), RigPaint.hex(0x4a3220), RigPaint.hex(0x3a2617)], [0, 0.7, 1]),
                               start: CGPoint(x: 0, y: floor.minY), end: CGPoint(x: 0, y: floor.maxY), options: [])
        ctx.restoreGState()
        RigPaint.grain(ctx, floor, alpha: 0.6, scale: CGSize(width: 14, height: 0.3), blend: .overlay)
        var by = floorY, gapH: CGFloat = 12
        while by < height {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor); ctx.fill(CGRect(x: 0, y: by, width: w, height: 1.2))
            by += gapH; gapH *= 1.22
        }
        ctx.saveGState()
        ctx.clip(to: floor)
        ctx.drawLinearGradient(RigPaint.gradient([NSColor.black.withAlphaComponent(0.75), .clear]), start: CGPoint(x: 0, y: floorY),
                               end: CGPoint(x: 0, y: floorY + 40), options: [])
        ctx.restoreGState()
        ctx.setBlendMode(.screen)
        for u in row {
            ctx.saveGState()
            ctx.translateBy(x: u.frame.midX / scale, y: footY - 10)
            ctx.scaleBy(x: 1, y: 0.22)
            RigPaint.radial(ctx, .zero, u.look.size.width * 0.75, [RigPaint.hex(0xffd9a0, 0.22), .clear])
            ctx.restoreGState()
        }
        ctx.setBlendMode(.normal)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor) // the edge between rows
        ctx.fill(CGRect(x: 0, y: height - 2, width: w, height: 2))
    }
}
