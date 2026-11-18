// Graphite: every plug-in in the device panel is a hardware unit on a brushed graphite faceplate.
// Parameters become the control that suits them (a scaled knob, a stepped selector, a lit push switch), related
// parameters ("Low Cut Frequency", "Low Cut Slope") share an engraved section, knob scales are printed with the
// plug-in's own values, and thin LED meters show the unit's input and output (Settings can hide them).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
enum Faceplate {
    /// Input/output meters on each unit (Settings ▸ Plug-ins).
    static var showMeters: Bool {
        get { UserDefaults.standard.object(forKey: "deviceMeters") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "deviceMeters")
            NotificationCenter.default.post(name: metersChanged, object: nil)
        }
    }
    static let metersChanged = Notification.Name("DalnokDeviceMetersChanged")

    // Palette: neutral graphite metal.
    static let plateTop = NSColor(srgbRed: 0.235, green: 0.243, blue: 0.259, alpha: 1)
    static let plateBottom = NSColor(srgbRed: 0.176, green: 0.184, blue: 0.196, alpha: 1)
    static let engraving = NSColor(srgbRed: 0.80, green: 0.82, blue: 0.84, alpha: 1)
    static let legend = NSColor(srgbRed: 0.56, green: 0.59, blue: 0.62, alpha: 1)
    static let readout = NSColor(srgbRed: 0.87, green: 0.89, blue: 0.91, alpha: 1)

    // MARK: Grouping

    struct Item { let id: UInt32; let label: String }
    struct Section { let title: String; var items: [Item] }

    /// Consecutive parameters that share all but their last word form a titled section
    /// ("Low Cut Frequency", "Low Cut Slope" → LOW CUT: Frequency, Slope); the rest share untitled sections.
    static func sections(_ params: [(id: UInt32, title: String)]) -> [Section] {
        func key(_ t: String) -> String {
            let words = t.split(separator: " ")
            return words.count >= 2 ? words.dropLast().joined(separator: " ") : ""
        }
        func short(_ t: String, _ k: String) -> String {
            let rest = String(t.dropFirst(k.count)).trimmingCharacters(in: .whitespaces)
            return rest.caseInsensitiveCompare("On/Off") == .orderedSame ? "On" : rest
        }
        var out: [Section] = []
        var i = 0
        while i < params.count {
            let k = key(params[i].title)
            var j = i + 1
            while !k.isEmpty, j < params.count, key(params[j].title) == k { j += 1 }
            if j - i >= 2 {
                out.append(Section(title: k, items: params[i..<j].map { Item(id: $0.id, label: short($0.title, k)) }))
            } else {
                let item = Item(id: params[i].id, label: params[i].title)
                if let last = out.indices.last, out[last].title.isEmpty { out[last].items.append(item) }
                else { out.append(Section(title: "", items: [item])) }
            }
            i = j
        }
        return out
    }

    /// Short legend for a printed scale: drops units, writes thousands as "k" ("20000 Hz" → "20k").
    static func legend(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if let space = t.firstIndex(of: " "), Double(t[..<space]) != nil { t = String(t[..<space]) }
        if let v = Double(t) {
            if abs(v) >= 1000 { let k = v / 1000; return (k == k.rounded() ? String(format: "%.0f", k) : String(format: "%.1f", k)) + "k" }
            if v == v.rounded() { return String(format: "%.0f", v) }
            return abs(v) >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        }
        return t.count > 6 ? String(t.prefix(5)) + "." : t
    }

    // MARK: Drawing

    /// The unit's faceplate: brushed graphite with a bevel, an accent line in the track colour, and four screws.
    static func plate(_ ctx: CGContext, _ rect: CGRect, accent: NSColor, dimmed: Bool) {
        let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let colors = [plateTop.cgColor, plateBottom.cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        }
        // Brushing: fine horizontal grain, seeded so it is stable between redraws.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        var y = rect.minY
        while y < rect.maxY {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let a = 0.018 + Double(seed >> 59) / 31 * 0.035
            ctx.setStrokeColor(NSColor(white: (seed >> 40) & 1 == 0 ? 1 : 0, alpha: a).cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y)); ctx.strokePath()
            y += 1 + CGFloat((seed >> 33) & 1)
        }
        ctx.restoreGState()
        // Bevel: light top edge, dark outline.
        ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        ctx.move(to: CGPoint(x: rect.minX + 5, y: rect.maxY - 1.5)); ctx.addLine(to: CGPoint(x: rect.maxX - 5, y: rect.maxY - 1.5)); ctx.strokePath()
        // Track-colour accent under the header.
        ctx.setFillColor((dimmed ? NSColor.gray : accent).withAlphaComponent(0.85).cgColor)
        ctx.fill(CGRect(x: rect.minX + 10, y: rect.maxY - 27, width: 18, height: 2))
        for p in [CGPoint(x: rect.minX + 6, y: rect.minY + 6), CGPoint(x: rect.maxX - 6, y: rect.minY + 6),
                  CGPoint(x: rect.minX + 6, y: rect.maxY - 6), CGPoint(x: rect.maxX - 6, y: rect.maxY - 6)] {
            screw(ctx, p)
        }
    }

    static func screw(_ ctx: CGContext, _ c: CGPoint) {
        let r: CGFloat = 3
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r - 0.5, y: c.y - r - 1, width: 2 * r + 1, height: 2 * r + 1))
        let colors = [NSColor(white: 0.62, alpha: 1).cgColor, NSColor(white: 0.30, alpha: 1).cgColor] as CFArray
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: c.x - r, y: c.y + r), end: CGPoint(x: c.x + r, y: c.y - r), options: [])
        }
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 0.12, alpha: 0.9).cgColor); ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: c.x - r * 0.6, y: c.y - r * 0.25)); ctx.addLine(to: CGPoint(x: c.x + r * 0.6, y: c.y + r * 0.25)); ctx.strokePath()
    }

    /// Text cut into the plate: a dark shadow below light lettering.
    static func engrave(_ text: String, in rect: CGRect, font: NSFont, color: NSColor = engraving, align: NSTextAlignment = .center) {
        let para = NSMutableParagraphStyle(); para.alignment = align; para.lineBreakMode = .byTruncatingTail
        let shadow: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.6), .paragraphStyle: para]
        (text as NSString).draw(with: rect.offsetBy(dx: 0, dy: 0.8), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: shadow)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    /// Angle for a normalized value: 270° of travel from lower left, measured clockwise from 12 o'clock.
    static func angle(_ v: Double) -> CGFloat { CGFloat(-0.75 * .pi + 1.5 * .pi * max(0, min(1, v))) }
    /// Point on a circle in a flipped view.
    static func point(_ c: CGPoint, _ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a)) }

    /// A machined knob: knurled skirt, brushed cap and a white pointer line.
    static func knob(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, angle a: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.setFillColor(NSColor(white: 0.09, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.restoreGState()
        // Knurling on the skirt.
        ctx.setStrokeColor(NSColor(white: 0.32, alpha: 0.9).cgColor); ctx.setLineWidth(0.8)
        for i in 0..<36 {
            let t = CGFloat(i) / 36 * 2 * .pi
            ctx.move(to: point(c, r * 0.84, t)); ctx.addLine(to: point(c, r - 0.6, t))
        }
        ctx.strokePath()
        // Cap.
        let cap = r * 0.74
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - cap, y: c.y - cap, width: 2 * cap, height: 2 * cap)); ctx.clip()
        let colors = [NSColor(white: 0.44, alpha: 1).cgColor, NSColor(white: 0.20, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x - cap * 0.35, y: c.y - cap * 0.45), startRadius: 0,
                                   endCenter: c, endRadius: cap * 1.1, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor); ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: CGRect(x: c.x - cap, y: c.y - cap, width: 2 * cap, height: 2 * cap))
        // Pointer.
        ctx.setStrokeColor(NSColor(white: 0.96, alpha: 1).cgColor); ctx.setLineWidth(max(1.6, r * 0.12)); ctx.setLineCap(.round)
        ctx.move(to: point(c, cap * 0.25, a)); ctx.addLine(to: point(c, r * 0.95, a)); ctx.strokePath()
        ctx.setLineCap(.butt)
    }

    /// Printed scale around a knob: `ticks` marks over the travel, a dark track and the value arc in `color`.
    static func scale(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, ticks: Int, value: Double, bipolar: Bool, color: NSColor) {
        let arcR = r + 3
        // Value track (the arc is drawn clockwise on screen, which is counter-clockwise in flipped coordinates).
        func arc(_ from: Double, _ to: Double, _ col: CGColor, _ w: CGFloat) {
            let a0 = angle(min(from, to)) - .pi / 2, a1 = angle(max(from, to)) - .pi / 2
            ctx.setStrokeColor(col); ctx.setLineWidth(w)
            ctx.addArc(center: c, radius: arcR, startAngle: a0, endAngle: a1, clockwise: false); ctx.strokePath()
        }
        arc(0, 1, NSColor.black.withAlphaComponent(0.45).cgColor, 2.2)
        arc(bipolar ? 0.5 : 0, value, color.cgColor, 2.2)
        ctx.setStrokeColor(legend.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(1)
        let n = max(ticks, 2)
        for i in 0..<n {
            let v = Double(i) / Double(n - 1)
            let long = i == 0 || i == n - 1 || (bipolar && abs(v - 0.5) < 1e-9)
            ctx.move(to: point(c, arcR + 2.5, angle(v))); ctx.addLine(to: point(c, arcR + (long ? 6 : 4.5), angle(v)))
        }
        ctx.strokePath()
    }

    /// A lit push switch: a raised key with an LED window.
    static func pushSwitch(_ ctx: CGContext, _ rect: CGRect, on: Bool, color: NSColor) {
        let key = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: on ? -0.5 : -1.5), blur: on ? 1.5 : 3, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(key); ctx.setFillColor(NSColor(white: 0.17, alpha: 1).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(key); ctx.clip()
        let colors = [NSColor(white: on ? 0.30 : 0.38, alpha: 1).cgColor, NSColor(white: 0.20, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(key); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
        let led = CGRect(x: rect.midX - rect.width * 0.3, y: rect.minY + 4, width: rect.width * 0.6, height: 3)
        if on {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 5, color: color.cgColor)
            ctx.setFillColor(color.cgColor); ctx.fill(led)
            ctx.restoreGState()
        } else {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor); ctx.fill(led)
        }
    }

    /// A recessed readout window with the value in it.
    static func readoutWindow(_ ctx: CGContext, _ rect: CGRect, text: String) {
        let path = CGPath(roundedRect: rect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ctx.addPath(path); ctx.setFillColor(NSColor(white: 0.07, alpha: 0.85).cgColor); ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor); ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 0.4)); ctx.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 0.4)); ctx.strokePath()
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect.insetBy(dx: 2, dy: 1).offsetBy(dx: 0, dy: 0.5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: Theme.mono(9), .foregroundColor: readout, .paragraphStyle: para])
    }
}

// MARK: A parameter on the faceplate

/// One parameter, drawn as the control that suits it, with its name above and its value in a readout below.
/// Drag vertically (⇧ for fine), scroll, use the arrow keys, double-click for the default.
@MainActor
final class FaceplateControl: NSControl, ParameterControl {
    enum Kind { case knob, selector, toggle }
    let kind: Kind
    let name: String
    var value: Double = 0 { didSet { needsDisplay = true; setAccessibilityValue(format(value)) } }
    var defaultValue: Double = 0
    var steps: Int32 = 0
    var bipolar = false
    var tint: NSColor = Theme.accent { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }
    /// Printed legends for the scale ends (and, for short selectors, every position).
    var legends: [String] = [] { didSet { needsDisplay = true } }
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var onChange: ((Double) -> Void)?
    private(set) var tracking = false
    private var dragStart: (y: CGFloat, value: Double)?
    private var glideTimer: Timer?

    static let size = NSSize(width: 64, height: 70)

    init(name: String, steps: Int32) {
        self.name = name
        self.steps = steps
        kind = steps == 1 ? .toggle : (steps >= 2 && steps <= 11) ? .selector : .knob
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(kind == .toggle ? .checkBox : .slider)
        setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    private func quantized(_ v: Double) -> Double {
        let v = max(0, min(1, v))
        return steps > 0 ? (v * Double(steps)).rounded() / Double(steps) : v
    }
    func set(_ v: Double) {
        let q = quantized(v)
        guard q != value else { return }
        glideTimer?.invalidate()
        value = q
        onChange?(q)
    }
    /// Changes made elsewhere: continuous knobs turn smoothly, switches and selectors jump.
    func glide(to target: Double) {
        glideTimer?.invalidate()
        guard kind == .knob, !Motion.reduced else { value = target; return }
        glide = (value, target, CACurrentMediaTime())
        glideTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.glideStep() }
        }
    }
    private var glide: (from: Double, to: Double, began: CFTimeInterval)?
    private func glideStep() {
        guard let g = glide else { glideTimer?.invalidate(); return }
        let p = min(1, (CACurrentMediaTime() - g.began) / 0.18)
        value = g.from + (g.to - g.from) * (1 - pow(1 - p, 3))
        if p >= 1 { glideTimer?.invalidate(); glide = nil }
    }

    // Input
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { set(defaultValue); return }
        if kind == .toggle { set(value >= 0.5 ? 0 : 1); return }
        tracking = true
        dragStart = (convert(event.locationInWindow, from: nil).y, value)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let fine = event.modifierFlags.contains(.shift) ? 0.2 : 1.0
        set(s.value + Double(s.y - convert(event.locationInWindow, from: nil).y) / 150 * fine)
    }
    override func mouseUp(with event: NSEvent) {
        if kind == .selector, dragStart.map({ abs($0.value - value) < 1e-9 }) == true, steps > 0 {
            set(value >= 1 - 1e-9 ? 0 : value + 1 / Double(steps)) // a click steps the selector round
        }
        tracking = false
        dragStart = nil
    }
    override func scrollWheel(with event: NSEvent) {
        let d = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 30)
        guard d != 0 else { return super.scrollWheel(with: event) }
        set(value + (steps > 0 ? (d > 0 ? 1 : -1) / Double(steps) : d))
    }
    private var stepSize: Double { steps > 0 ? 1 / Double(steps) : 0.02 }
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?, .rightArrow?: set(value + stepSize)
        case .downArrow?, .leftArrow?: set(value - stepSize)
        default: if !forwardShortcut(event) { super.keyDown(with: event) }
        }
    }
    override func accessibilityPerformIncrement() -> Bool { set(value + stepSize); return true }
    override func accessibilityPerformDecrement() -> Bool { set(value - stepSize); return true }
    override func accessibilityPerformPress() -> Bool { if kind == .toggle { set(value >= 0.5 ? 0 : 1) }; return true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    /// The name's font: 9.5 pt, shrinking to 7.5 pt before the name is truncated.
    static func nameFont(_ name: String, width: CGFloat) -> NSFont {
        for size in stride(from: 9.5, through: 7.5, by: -0.5) {
            let f = Theme.ui(CGFloat(size), .medium)
            if (name as NSString).size(withAttributes: [.font: f]).width <= width - 2 { return f }
        }
        return Theme.ui(7.5, .medium)
    }

    // Drawing
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if dimmed { ctx.setAlpha(0.5) }
        let w = bounds.width
        Faceplate.engrave(name, in: CGRect(x: 0, y: 0, width: w, height: 12), font: Self.nameFont(name, width: w))
        let c = CGPoint(x: w / 2, y: 34)
        let legendFont = Theme.mono(7.5)
        switch kind {
        case .toggle:
            Faceplate.pushSwitch(ctx, CGRect(x: c.x - 13, y: c.y - 9, width: 26, height: 19), on: value >= 0.5, color: tint)
        case .knob, .selector:
            let r: CGFloat = kind == .knob ? 12.5 : 10.5
            Faceplate.scale(ctx, center: c, radius: r, ticks: kind == .selector ? Int(steps) + 1 : 11, value: value,
                            bipolar: bipolar, color: tint)
            Faceplate.knob(ctx, center: c, radius: r, angle: Faceplate.angle(value))
            if legends.count >= 2 {
                // Printed at the ends of the scale, inside this control's own width.
                let y = c.y + 10.5, gap: CGFloat = 12
                Faceplate.engrave(legends[0], in: CGRect(x: 0, y: y, width: c.x - gap, height: 10), font: legendFont,
                                  color: Faceplate.legend, align: .right)
                Faceplate.engrave(legends[legends.count - 1], in: CGRect(x: c.x + gap, y: y, width: w - c.x - gap, height: 10),
                                  font: legendFont, color: Faceplate.legend, align: .left)
            }
        }
        Faceplate.readoutWindow(ctx, CGRect(x: 6, y: bounds.height - 14, width: w - 12, height: 13), text: format(value))
        if window?.firstResponder === self {
            ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44))
        }
    }
}

// MARK: Sections and meters

/// An engraved section of controls: its title across the top and a groove on its trailing edge.
@MainActor
final class FaceplateSection: NSView {
    let title: String
    var groove = true
    init(title: String, controls: [FaceplateControl], rows: Int) {
        self.title = title
        super.init(frame: .zero)
        let grid = NSGridView()
        grid.rowSpacing = 2
        grid.columnSpacing = 2
        let columns = max(1, Int((Double(controls.count) / Double(rows)).rounded(.up)))
        for row in stride(from: 0, to: controls.count, by: columns) {
            var cells: [NSView] = Array(controls[row..<min(row + columns, controls.count)])
            while cells.count < columns { cells.append(NSGridCell.emptyContentView) }
            grid.addRow(with: cells)
        }
        for c in controls {
            c.widthAnchor.constraint(equalToConstant: FaceplateControl.size.width).isActive = true
            c.heightAnchor.constraint(equalToConstant: FaceplateControl.size.height).isActive = true
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if !title.isEmpty {
            Faceplate.engrave(title.uppercased(), in: CGRect(x: 2, y: 0, width: bounds.width - 8, height: 11),
                              font: Theme.ui(8, .bold), color: Faceplate.legend)
        }
        guard groove else { return }
        let x = bounds.maxX - 1.5
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: x, y: 4)); ctx.addLine(to: CGPoint(x: x, y: bounds.height - 4)); ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.move(to: CGPoint(x: x + 1, y: 4)); ctx.addLine(to: CGPoint(x: x + 1, y: bounds.height - 4)); ctx.strokePath()
    }
}

/// A unit's input or output meter: two thin LED ladders (left, right) with peak ballistics.
@MainActor
final class FaceplateMeter: NSView {
    let caption: String
    private var levelDb: (Float, Float) = (-120, -120)
    private var last = CACurrentMediaTime()
    static let floorDb: Float = -48, segments = 16

    init(caption: String) {
        self.caption = caption
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(caption == "IN" ? "Input level" : "Output level")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Linear peaks since the last frame. Instant attack, 24 dB/s fall.
    func push(_ l: Float, _ r: Float) {
        let now = CACurrentMediaTime(), dt = Float(now - last)
        last = now
        func db(_ x: Float) -> Float { x > 0 ? 20 * log10(x) : -120 }
        let next = (max(db(l), levelDb.0 - 24 * dt), max(db(r), levelDb.1 - 24 * dt))
        if Int(next.0 * 4) != Int(levelDb.0 * 4) || Int(next.1 * 4) != Int(levelDb.1 * 4) { needsDisplay = true }
        levelDb = next
        setAccessibilityValue(String(format: "%.0f dB", max(levelDb.0, levelDb.1)))
    }
    var level: (Float, Float) { levelDb }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ladder = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 11)
        let slot = CGPath(roundedRect: ladder, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        ctx.addPath(slot); ctx.setFillColor(NSColor(white: 0.05, alpha: 0.9).cgColor); ctx.fillPath()
        let n = Self.segments, gap: CGFloat = 1
        let segH = (ladder.height - 2 - gap * CGFloat(n - 1)) / CGFloat(n)
        let colW = (ladder.width - 3) / 2
        for (ch, db) in [levelDb.0, levelDb.1].enumerated() {
            let lit = Int(((db - Self.floorDb) / -Self.floorDb * Float(n)).rounded(.down))
            for i in 0..<n {
                let segDb = Self.floorDb * (1 - Float(i + 1) / Float(n))
                let base: NSColor = segDb >= -1.5 ? Theme.hex(0xE0574F) : segDb >= -9 ? Theme.hex(0xE3A857) : Theme.hex(0x6FC08E)
                let y = ladder.maxY - 1 - CGFloat(i + 1) * segH - CGFloat(i) * gap
                ctx.setFillColor((i < lit ? base : base.withAlphaComponent(0.13)).cgColor)
                ctx.fill(CGRect(x: 1 + CGFloat(ch) * (colW + 1), y: y, width: colW, height: segH))
            }
        }
        Faceplate.engrave(caption, in: CGRect(x: -6, y: bounds.height - 10, width: bounds.width + 12, height: 10),
                          font: Theme.ui(6.5, .bold), color: Faceplate.legend)
    }
}
