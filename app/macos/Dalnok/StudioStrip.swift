// Guitar Studio's slot strip, above its controls in every look: the rig in signal order (1 → 8), each module with its
// on/off light. Click a module for its menu (switch, move, replace, remove), click its light to switch it, drag it
// along the strip to reorder, click + to add one. The loaded factory rig is named at the end, with a dot once edited.
// VoiceOver: each module is a button with Turn Off/On, Move Earlier/Later and Remove actions.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class StudioStrip: NSView {
    static let height: CGFloat = 22
    weak var device: DeviceView?
    private(set) var chain: [StudioModule] = []
    /// The factory rig last applied, and whether the rig has changed since.
    private(set) var preset: (name: String, edited: Bool)?
    private var drag: (index: Int, start: CGFloat, now: CGFloat)?
    private var elements: [StripElement] = []
    private var loadedOnce = false

    init(device: DeviceView) {
        self.device = device
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Guitar Studio modules, in signal order")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reload() {
        guard let device else { return }
        let next = device.studioChain(), status = device.studioPresetStatus()
        if loadedOnce, next == chain, status?.name == preset?.name, status?.edited == preset?.edited { return }
        loadedOnce = true
        chain = next
        preset = status
        rebuildAccessibility()
        needsDisplay = true
    }

    // MARK: Geometry

    private var presetWidth: CGFloat {
        guard let preset else { return 0 }
        return min(150, (preset.name + " •").size(withAttributes: [.font: Theme.ui(9, .semibold)]).width + 14)
    }
    private var canAdd: Bool { chain.count < StudioLayout.slots }
    /// Module cells and the + cell, left to right, with a chevron gap between them.
    var cells: [CGRect] {
        let gap: CGFloat = 9, n = chain.count + (canAdd ? 1 : 0)
        guard n > 0 else { return [] }
        let plus: CGFloat = canAdd ? 22 : 0
        let avail = bounds.width - presetWidth - plus - CGFloat(max(0, n - 1)) * gap
        let w = max(34, min(112, avail / CGFloat(max(1, chain.count))))
        var x: CGFloat = 0, out: [CGRect] = []
        for _ in chain { out.append(CGRect(x: x, y: 1, width: w, height: bounds.height - 2)); x += w + gap }
        if canAdd { out.append(CGRect(x: x, y: 1, width: plus, height: bounds.height - 2)) }
        return out
    }
    func light(_ cell: CGRect) -> CGRect { CGRect(x: cell.minX + 5, y: cell.midY - 3.5, width: 7, height: 7) }
    private func index(at p: CGPoint) -> Int? { cells.firstIndex { $0.insetBy(dx: -4, dy: 0).contains(p) } }
    /// Where a dragged module would land: the slot whose centre is nearest.
    private func dropIndex(_ x: CGFloat) -> Int {
        let centres = cells.prefix(chain.count).map(\.midX)
        return centres.indices.min { abs(centres[$0] - x) < abs(centres[$1] - x) } ?? 0
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cs = cells
        let font = Theme.ui(9, .semibold)
        for (i, m) in chain.enumerated() {
            var r = cs[i]
            if let d = drag, d.index == i { r.origin.x += d.now - d.start }
            let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.setFillColor(Theme.ink(drag?.index == i ? 0.16 : 0.08).cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(Theme.ink(0.22).cgColor); ctx.setLineWidth(1)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.strokePath()
            ctx.setFillColor((m.on ? Theme.accentText : Theme.textFaint).cgColor)
            ctx.fillEllipse(in: light(r))
            let label = "\(i + 1) \(m.name)"
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: m.on ? Theme.text : Theme.textDim]
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            var a = attrs; a[.paragraphStyle] = para
            (label as NSString).draw(in: CGRect(x: r.minX + 15, y: r.midY - 6.5, width: r.width - 18, height: 13), withAttributes: a)
            if i + 1 < cs.count { // the signal flows on
                let x = cs[i].maxX + 2.5
                ctx.setStrokeColor(Theme.textDim.cgColor); ctx.setLineWidth(1.2)
                ctx.move(to: CGPoint(x: x, y: r.midY - 3.5)); ctx.addLine(to: CGPoint(x: x + 3.5, y: r.midY)); ctx.addLine(to: CGPoint(x: x, y: r.midY + 3.5))
                ctx.strokePath()
            }
        }
        if let d = drag { // where it will land
            let to = dropIndex(cs[d.index].midX + d.now - d.start)
            if to != d.index {
                let x = to > d.index ? cs[to].maxX + 4 : cs[to].minX - 5
                ctx.setFillColor(Theme.accentText.cgColor)
                ctx.fill(CGRect(x: x, y: 1, width: 2, height: bounds.height - 2))
            }
        }
        if canAdd, let r = cs.last {
            ctx.setStrokeColor(Theme.textDim.cgColor); ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [2, 2])
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.move(to: CGPoint(x: r.midX - 4, y: r.midY)); ctx.addLine(to: CGPoint(x: r.midX + 4, y: r.midY))
            ctx.move(to: CGPoint(x: r.midX, y: r.midY - 4)); ctx.addLine(to: CGPoint(x: r.midX, y: r.midY + 4)); ctx.strokePath()
        }
        if let preset {
            let text = preset.name + (preset.edited ? " •" : "")
            let para = NSMutableParagraphStyle(); para.alignment = .right; para.lineBreakMode = .byTruncatingTail
            (text as NSString).draw(in: CGRect(x: bounds.width - presetWidth, y: bounds.midY - 6.5, width: presetWidth, height: 13),
                                    withAttributes: [.font: Theme.ui(9, .semibold), .foregroundColor: Theme.textDim, .paragraphStyle: para])
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else { return }
        if i >= chain.count { return showAddMenu() }
        if light(cells[i]).insetBy(dx: -3, dy: -3).contains(p) { return device?.toggleStudioModule(i) ?? () }
        drag = (i, p.x, p.x)
    }
    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        d.now = convert(event.locationInWindow, from: nil).x
        drag = d
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        needsDisplay = true
        if abs(d.now - d.start) < 4 { return showModuleMenu(d.index) }
        let to = dropIndex(cells[d.index].midX + d.now - d.start)
        if to != d.index { device?.moveStudioModule(from: d.index, to: to) }
    }
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = index(at: p), i < chain.count { showModuleMenu(i) } else { showAddMenu() }
    }
    func showModuleMenu(_ i: Int) {
        guard let menu = device?.studioModuleMenu(i), i < cells.count else { return }
        menu.popUp(positioning: nil, at: CGPoint(x: cells[i].minX, y: cells[i].maxY + 2), in: self)
    }
    func showAddMenu() {
        guard let menu = device?.studioAddMenu() else { return }
        menu.popUp(positioning: nil, at: CGPoint(x: (cells.last?.minX ?? 0), y: bounds.maxY + 2), in: self)
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        elements = chain.enumerated().map { i, m in
            let e = StripElement(parent: self)
            e.setAccessibilityRole(.button)
            e.setAccessibilityLabel("Slot \(i + 1) of \(StudioLayout.slots): \(m.name), \(m.on ? "on" : "off")")
            e.setAccessibilityHelp("Opens the module's menu")
            e.press = { [weak self] in self?.showModuleMenu(i) }
            var actions = [NSAccessibilityCustomAction(name: m.on ? "Turn Off" : "Turn On") { [weak self] in self?.device?.toggleStudioModule(i); return true }]
            if i > 0 { actions.append(NSAccessibilityCustomAction(name: "Move Earlier") { [weak self] in self?.device?.moveStudioModule(from: i, to: i - 1); return true }) }
            if i < chain.count - 1 { actions.append(NSAccessibilityCustomAction(name: "Move Later") { [weak self] in self?.device?.moveStudioModule(from: i, to: i + 1); return true }) }
            actions.append(NSAccessibilityCustomAction(name: "Remove") { [weak self] in self?.device?.removeStudioModule(i); return true })
            e.setAccessibilityCustomActions(actions)
            return e
        }
        if canAdd {
            let e = StripElement(parent: self)
            e.setAccessibilityRole(.button)
            e.setAccessibilityLabel("Add Module")
            e.press = { [weak self] in self?.showAddMenu() }
            elements.append(e)
        }
        setAccessibilityChildren(elements)
        layoutAccessibility()
    }
    private func layoutAccessibility() {
        for (e, r) in zip(elements, cells) { e.setAccessibilityFrameInParentSpace(r) }
    }
    override func layout() {
        super.layout()
        layoutAccessibility()
    }
}

/// One module (or +) on the strip, for VoiceOver.
private final class StripElement: NSAccessibilityElement {
    var press: (() -> Void)?
    init(parent: NSView) {
        super.init()
        setAccessibilityParent(parent)
    }
    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
}
