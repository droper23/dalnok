// Warm Analog: every plug-in on a track is a stomp box on a pedalboard.
// A pedal's look (enclosure finish and colour, knob style, artwork, lettering, LED, footswitch) is drawn from a
// seeded random generator keyed by the plug-in's name, so the same plug-in always looks the same and two
// different plug-ins rarely match. The owner can re-roll the look or override any part of it, and choose how each
// parameter is presented (knob, small knob, selector, switch, slider). Its size follows the number of controls.
// The footswitch is the plug-in's real bypass (an undoable engine edit); the LED shows that state.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

// MARK: Seeded randomness

/// SplitMix64 seeded with FNV-1a of a string: stable across launches and machines (unlike `Hasher`).
struct PedalRandom {
    private var state: UInt64
    init(_ key: String) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        state = h
    }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
    mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
}

// MARK: Look

struct PedalLook: Equatable {
    enum Finish: String, CaseIterable { case powder, hammertone, sparkle, brushed, anodized
        var title: String { ["powder": "Powder Coat", "hammertone": "Hammertone", "sparkle": "Metal Flake", "brushed": "Brushed Aluminium", "anodized": "Anodized"][rawValue]! }
    }
    enum Knob: String, CaseIterable { case ribbed, chickenhead, chrome, skirted, jellybean
        var title: String { ["ribbed": "Ribbed Black", "chickenhead": "Chicken Head", "chrome": "Knurled Chrome", "skirted": "Skirted Cream", "jellybean": "Jelly Bean"][rawValue]! }
    }
    enum Artwork: String, CaseIterable { case plain, stripe, border, pinstripe, circle, chevron
        var title: String { ["plain": "None", "stripe": "Stripe", "border": "Border", "pinstripe": "Pinstripes", "circle": "Circle", "chevron": "Chevron"][rawValue]! }
    }
    enum Switch: String, CaseIterable { case chrome, rubber
        var title: String { self == .chrome ? "Chrome Stomp" : "Rubber Pad" }
    }
    static let enclosures: [(String, UInt32)] = [
        ("Signal Red", 0xB8322A), ("Burnt Orange", 0xC8642A), ("Mustard", 0xD2A23A), ("Sea Foam", 0x7FB8A4),
        ("Racing Green", 0x2F5B45), ("Teal", 0x2A6F75), ("Cobalt", 0x2C4F95), ("Powder Blue", 0x8DB1CF),
        ("Purple", 0x5C3F86), ("Pink", 0xD77FA1), ("Cream", 0xE6DCC2), ("Silver", 0xB9BCC0), ("Gunmetal", 0x4A4E54),
        ("Black", 0x1C1C1E), ("Olive", 0x6E7243), ("Oxblood", 0x6A2026), ("Brass", 0xB79A55), ("Copper", 0xA86A45),
    ]
    static let leds: [(String, UInt32)] = [("Red", 0xFF3B30), ("Green", 0x4CD964), ("Blue", 0x3D8BFF), ("Amber", 0xFFB020), ("White", 0xF4F4F0), ("Violet", 0xB15CFF)]
    static let fonts = ["Futura-CondensedExtraBold", "AvenirNextCondensed-Heavy", "Didot-Bold", "AmericanTypewriter-Bold",
                        "Copperplate-Bold", "Optima-ExtraBlack", "GillSans-Bold", "Menlo-Bold", "Rockwell-ExtraBold", "BodoniSvtyTwoITCTT-Bold"]

    var enclosure: Int, finish: Finish, knob: Knob, knobColor: UInt32, artwork: Artwork, accent: UInt32
    var led: Int, footswitch: Switch, font: String, corner: CGFloat, topScrews: Bool, numbered: Bool

    var color: NSColor { Theme.hex(Self.enclosures[enclosure].1) }
    var ledColor: NSColor { Theme.hex(Self.leds[led].1) }
    /// Silkscreen ink: dark on light enclosures, cream on dark ones.
    var ink: NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.55 ? Theme.hex(0x1A1714) : Theme.hex(0xF3EBD8)
    }
    func letterFont(_ size: CGFloat) -> NSFont { NSFont(name: font, size: size) ?? .systemFont(ofSize: size, weight: .heavy) }

    static func random(_ key: String) -> PedalLook {
        var r = PedalRandom(key)
        let enclosure = Int(r.next() % UInt64(enclosures.count))
        let knob = r.pick(Knob.allCases)
        let knobColors: [UInt32] = knob == .jellybean ? [0xE8E2D0, 0x1E1E1E, 0xC8322A, 0x2C5FA0, 0xE0B040] : [0x1A1A1A, 0xEDE6D2]
        return PedalLook(enclosure: enclosure, finish: r.pick(Finish.allCases), knob: knob, knobColor: r.pick(knobColors),
                         artwork: r.pick(Artwork.allCases), accent: r.pick(enclosures.map(\.1)), led: Int(r.next() % UInt64(leds.count)),
                         footswitch: r.unit() < 0.8 ? .chrome : .rubber, font: r.pick(fonts), corner: r.range(4, 11),
                         topScrews: r.unit() < 0.35, numbered: r.unit() < 0.5)
    }
}

/// Per-plug-in pedal preferences (the look is presentation, not project data: kept in user defaults by name).
enum PedalStore {
    private static func key(_ name: String) -> String { "pedal." + name }
    static func overrides(_ name: String) -> [String: String] { UserDefaults.standard.dictionary(forKey: key(name)) as? [String: String] ?? [:] }
    static func set(_ name: String, _ field: String, _ value: String?) {
        var d = overrides(name)
        d[field] = value
        if d.isEmpty { UserDefaults.standard.removeObject(forKey: key(name)) } else { UserDefaults.standard.set(d, forKey: key(name)) }
    }
    static func reset(_ name: String) {
        let kinds = overrides(name).filter { $0.key.hasPrefix("control.") }
        if kinds.isEmpty { UserDefaults.standard.removeObject(forKey: key(name)) } else { UserDefaults.standard.set(kinds, forKey: key(name)) }
    }

    static func look(_ name: String) -> PedalLook {
        let o = overrides(name)
        var l = PedalLook.random(name + "#" + (o["variant"] ?? "0"))
        if let v = o["enclosure"].flatMap(Int.init), PedalLook.enclosures.indices.contains(v) { l.enclosure = v }
        if let v = o["finish"].flatMap(PedalLook.Finish.init) { l.finish = v }
        if let v = o["knob"].flatMap(PedalLook.Knob.init) {
            if v != l.knob { l.knobColor = v == .jellybean ? 0xC8322A : 0x1A1A1A }
            l.knob = v
        }
        if let v = o["artwork"].flatMap(PedalLook.Artwork.init) { l.artwork = v }
        if let v = o["led"].flatMap(Int.init), PedalLook.leds.indices.contains(v) { l.led = v }
        if let v = o["footswitch"].flatMap(PedalLook.Switch.init) { l.footswitch = v }
        return l
    }
    /// A new random look (keeps explicit overrides of individual parts out of the way).
    static func reroll(_ name: String) {
        let next = (Int(overrides(name)["variant"] ?? "0") ?? 0) + 1
        for f in ["enclosure", "finish", "knob", "artwork", "led", "footswitch"] { set(name, f, nil) }
        set(name, "variant", String(next))
    }

    static func kind(_ name: String, _ param: UInt32) -> PedalControl.Kind? { overrides(name)["control.\(param)"].flatMap(PedalControl.Kind.init) }
    static func setKind(_ name: String, _ param: UInt32, _ k: PedalControl.Kind?) { set(name, "control.\(param)", k?.rawValue) }
}

// MARK: Geometry

enum PedalGeometry {
    /// Controls per row: up to four in one row, more fill two rows (big-box pedals grow wider).
    static func columns(_ n: Int) -> Int { n <= 4 ? max(1, n) : (n + 1) / 2 }
    static func rows(_ n: Int) -> Int { n <= 4 ? 1 : 2 }
    static func cell(_ n: Int) -> CGFloat { n <= 4 ? 54 : 48 }
    /// Enclosure width for `n` controls: a 1-knob mini, a 3-knob standard box, a wide multi-knob unit.
    static func width(_ n: Int) -> CGFloat { max(n <= 1 ? 92 : 128, CGFloat(columns(n)) * cell(n) + 26) }
}

// MARK: Parameter controls

/// What the device panel needs from a control, whichever theme draws it.
@MainActor
protocol ParameterControl: NSView {
    var value: Double { get set }
    var tracking: Bool { get }
    func glide(to target: Double)
}
extension RotaryKnob: ParameterControl {}

/// One parameter on a pedal, drawn as the chosen kind in the pedal's style. Drag vertically (⇧ for fine),
/// scroll, use the arrow keys, double-click for the default; right-click to change its kind.
@MainActor
final class PedalControl: NSControl, ParameterControl {
    enum Kind: String, CaseIterable {
        case knob, smallKnob, selector, toggle, slider
        var title: String { ["knob": "Knob", "smallKnob": "Small Knob", "selector": "Rotary Selector", "toggle": "Toggle Switch", "slider": "Slider"][rawValue]! }
    }
    var kind: Kind { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var look: PedalLook { didSet { needsDisplay = true } }
    var value: Double = 0 { didSet { needsDisplay = true; setAccessibilityValue(format(value)) } }
    var defaultValue: Double = 0
    /// 0 continuous, 1 toggle, n = n + 1 positions.
    var steps: Int32 = 0
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var onChange: ((Double) -> Void)?
    var onKindChange: ((Kind?) -> Void)?
    private(set) var tracking = false
    private var dragStart: (y: CGFloat, value: Double)?

    init(kind: Kind, look: PedalLook) {
        self.kind = kind
        self.look = look
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(kind == .toggle ? .checkBox : .slider)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func defaultKind(steps: Int32) -> Kind { steps == 1 ? .toggle : (steps >= 2 && steps <= 11) ? .selector : .knob }
    /// Kinds that make sense for this parameter (a switch only for on/off parameters).
    var availableKinds: [Kind] { steps == 1 ? [.toggle, .knob, .smallKnob] : Kind.allCases.filter { $0 != .toggle } }

    private func quantized(_ v: Double) -> Double {
        let v = max(0, min(1, v))
        return steps > 0 ? (v * Double(steps)).rounded() / Double(steps) : v
    }
    func set(_ v: Double) {
        let q = quantized(v)
        guard q != value else { return }
        value = q
        onChange?(q)
    }
    func glide(to target: Double) { value = quantized(target) } // pedals jump like the real thing

    // Input
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { set(defaultValue); return }
        if kind == .toggle { set(value >= 0.5 ? 0 : 1); return }
        tracking = true
        dragStart = (convert(event.locationInWindow, from: nil).y, value)
        ValueBubble.show(format(value), above: self, at: bounds.midX)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let fine = event.modifierFlags.contains(.shift) ? 0.2 : 1.0
        let dy = s.y - convert(event.locationInWindow, from: nil).y // up = more
        set(s.value + Double(dy) / 140 * fine)
        ValueBubble.show(format(value), above: self, at: bounds.midX)
    }
    override func mouseUp(with event: NSEvent) {
        if kind == .selector, dragStart.map({ abs($0.value - value) < 1e-9 }) == true, steps > 0 {
            set(value >= 1 - 1e-9 ? 0 : value + 1 / Double(steps)) // a click steps the selector round
        }
        tracking = false
        dragStart = nil
        ValueBubble.hide()
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        for k in availableKinds {
            let item = NSMenuItem(title: k.title, action: #selector(kindChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = k.rawValue
            item.state = k == kind ? .on : .off
            m.addItem(item)
        }
        m.addItem(.separator())
        let reset = NSMenuItem(title: "Reset to Default Value", action: #selector(resetValue), keyEquivalent: "")
        reset.target = self
        m.addItem(reset)
        return m
    }
    @objc private func kindChosen(_ sender: NSMenuItem) {
        guard let k = (sender.representedObject as? String).flatMap(Kind.init) else { return }
        kind = k
        onKindChange?(k)
    }
    @objc private func resetValue() { set(defaultValue) }

    // Drawing
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        switch kind {
        case .knob, .smallKnob, .selector:
            let r = min(bounds.width, bounds.height) / 2 - (kind == .smallKnob ? 7 : 4)
            PedalDraw.scale(ctx, center: c, radius: r + 3, look: look, steps: kind == .selector ? Int(max(steps, 1)) : (look.numbered ? 10 : 0),
                            numbered: look.numbered && kind == .knob && r >= 13)
            let angle = PedalDraw.angle(value)
            if kind == .selector { PedalDraw.chickenhead(ctx, center: c, radius: r - 1, angle: angle, color: look.knobColor) }
            else { PedalDraw.knob(ctx, center: c, radius: r - 2, angle: angle, look: look) }
        case .toggle: PedalDraw.toggle(ctx, center: c, up: value >= 0.5)
        case .slider: PedalDraw.slider(ctx, in: bounds.insetBy(dx: bounds.width / 2 - 5, dy: 3), value: value, look: look)
        }
        if window?.firstResponder === self {
            ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: bounds.insetBy(dx: 1, dy: 1))
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}

/// The footswitch: a real bypass toggle. Click (or Space with focus) to stomp.
@MainActor
final class PedalFootswitch: NSControl {
    var look: PedalLook { didSet { needsDisplay = true } }
    var engaged = true { didSet { needsDisplay = true; setAccessibilityValue(engaged ? "on" : "bypassed") } }
    var onStomp: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    init(look: PedalLook) {
        self.look = look
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onStomp?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { onStomp?() } else if !forwardShortcut(event) { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onStomp?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        PedalDraw.footswitch(ctx, center: CGPoint(x: bounds.midX, y: bounds.midY), radius: min(bounds.width, bounds.height) / 2 - 2,
                             style: look.footswitch, pressed: pressed)
    }
}

// MARK: The pedal body

/// The enclosure and everything on it. DeviceView hosts it in Warm Analog in place of the knob grid.
@MainActor
final class PedalBody: NSView {
    let name: String
    var look: PedalLook { didSet { controls.forEach { $0.look = look }; footswitch.look = look; screen.glow = look.ledColor; textureCache = nil; needsDisplay = true } }
    var engaged = true { didSet { footswitch.engaged = engaged; screen.lit = engaged && message == nil; needsDisplay = true } }
    /// The readout window under the controls (shown when the pedal has controls).
    let screen = PedalScreen()
    /// Signal LEDs by the jacks: input and output level 0…1 (green for signal, red near full scale).
    var inLevel: CGFloat = 0 { didSet { if abs(inLevel - oldValue) > 0.02 { setNeedsDisplay(signalRect(left: true)) } } }
    var outLevel: CGFloat = 0 { didSet { if abs(outLevel - oldValue) > 0.02 { setNeedsDisplay(signalRect(left: false)) } } }
    private func signalRect(left: Bool) -> CGRect {
        let box = enclosure
        return CGRect(x: left ? box.minX + 4 : box.maxX - 14, y: box.minY + 3, width: 10, height: 10)
    }
    var vendor = ""
    private(set) var controls: [PedalControl] = []
    private(set) var labels: [NSTextField] = []
    let footswitch: PedalFootswitch
    private var widthConstraint: NSLayoutConstraint!
    private var textureCache: (CGSize, CGImage)?
    private var hover: Int?
    var message: String? { didSet { needsDisplay = true } }
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    init(name: String) {
        self.name = name
        look = PedalStore.look(name)
        footswitch = PedalFootswitch(look: look)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: PedalGeometry.width(0))
        widthConstraint.isActive = true
        footswitch.setAccessibilityLabel("Bypass \(name)")
        footswitch.toolTip = "Footswitch: turns \(name) on or off (bypass). Undoable."
        addSubview(footswitch)
        screen.glow = look.ledColor
        screen.isHidden = true
        addSubview(screen)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Lays out one control (and its printed label) per parameter; the enclosure grows with the count.
    func setControls(_ cs: [PedalControl], labels ls: [NSTextField]) {
        controls.forEach { $0.removeFromSuperview() }
        labels.forEach { $0.removeFromSuperview() }
        controls = cs
        labels = ls
        cs.forEach { addSubview($0) }
        ls.forEach { $0.textColor = look.ink; addSubview($0) }
        screen.isHidden = cs.isEmpty
        screen.lit = engaged && message == nil
        widthConstraint.constant = PedalGeometry.width(cs.count)
        needsLayout = true
        needsDisplay = true
    }

    var enclosure: CGRect { bounds.insetBy(dx: 1, dy: 1).offsetBy(dx: 0, dy: -1) }

    override func layout() {
        super.layout()
        let n = controls.count, cols = PedalGeometry.columns(n), cell = PedalGeometry.cell(n)
        let gridW = CGFloat(cols) * cell, x0 = (bounds.width - gridW) / 2
        let rowH: CGFloat = n <= 4 ? 58 : 48
        for (i, c) in controls.enumerated() {
            let col = i % cols, row = i / cols
            let size: CGFloat = n <= 4 ? 40 : 32
            let cx = x0 + CGFloat(col) * cell + cell / 2, top = 12 + CGFloat(row) * rowH
            c.frame = CGRect(x: cx - size / 2, y: top, width: size, height: size)
            labels[i].frame = CGRect(x: cx - cell / 2 + 1, y: top + size + 1, width: cell - 2, height: 12)
        }
        let fs: CGFloat = look.footswitch == .chrome ? 30 : 36
        footswitch.frame = CGRect(x: bounds.midX - fs / 2, y: bounds.height - fs - 6, width: fs, height: fs)
        let rows = CGFloat(PedalGeometry.rows(n)), top = 12 + rows * rowH + 1
        let sw = min(bounds.width - 22, 168)
        screen.frame = CGRect(x: bounds.midX - sw / 2, y: top, width: sw, height: PedalScreen.height)
    }

    /// Where the name is lettered: between the controls and the LED.
    private var nameBand: CGRect {
        let n = controls.count, rows = CGFloat(PedalGeometry.rows(n)), rowH: CGFloat = n <= 4 ? 58 : 48
        let top = n == 0 ? 18 : (screen.isHidden ? 12 + rows * rowH - 4 : screen.frame.maxY + 3)
        return CGRect(x: 8, y: top, width: bounds.width - 16, height: max(14, footswitch.frame.minY - 14 - top))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = enclosure
        PedalDraw.enclosure(ctx, box, look: look, texture: texture(for: box.size))
        if look.topScrews {
            for p in [CGPoint(x: box.minX + 7, y: box.minY + 7), CGPoint(x: box.maxX - 7, y: box.minY + 7),
                      CGPoint(x: box.minX + 7, y: box.maxY - 7), CGPoint(x: box.maxX - 7, y: box.maxY - 7)] {
                Analog.screw(ctx, at: p, radius: 2.6, angle: CGFloat(p.x.truncatingRemainder(dividingBy: 3)))
            }
        }
        PedalDraw.artwork(ctx, box, band: nameBand, look: look)
        // Lettering: the plug-in's name, sized to fit the band; the maker under it.
        let band = nameBand
        var size = min(18, band.height * 0.62)
        let text = name.uppercased()
        func attrs(_ s: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: look.letterFont(s), .foregroundColor: look.artwork == .stripe ? PedalDraw.contrast(Theme.hex(look.accent)) : look.ink, .kern: s * 0.06]
        }
        while size > 7, (text as NSString).size(withAttributes: attrs(size)).width > band.width - 8 { size -= 0.5 }
        let ts = (text as NSString).size(withAttributes: attrs(size))
        let tr = CGRect(x: band.midX - ts.width / 2, y: band.midY - ts.height / 2 - (vendor.isEmpty ? 0 : 4), width: ts.width, height: ts.height)
        (text as NSString).draw(in: tr, withAttributes: attrs(size))
        if !vendor.isEmpty, band.height > 26 {
            let v = vendor.uppercased() as NSString
            let va: [NSAttributedString.Key: Any] = [.font: Theme.ui(6.5, .semibold), .foregroundColor: look.ink.withAlphaComponent(0.7), .kern: 1.2]
            let vs = v.size(withAttributes: va)
            v.draw(at: CGPoint(x: band.midX - vs.width / 2, y: tr.maxY), withAttributes: va)
        }
        if let message {
            let m = message as NSString
            let ma: [NSAttributedString.Key: Any] = [.font: Theme.ui(8.5, .medium), .foregroundColor: look.ink.withAlphaComponent(0.8)]
            m.draw(in: CGRect(x: 10, y: 14, width: bounds.width - 20, height: 40), withAttributes: ma)
        }
        // Status LED above the footswitch, in a chrome bezel.
        let fs = footswitch.frame
        let ledRect = CGRect(x: fs.midX - 3.5, y: fs.minY - 12, width: 7, height: 7)
        ctx.setFillColor(NSColor(white: 0.75, alpha: 1).cgColor); ctx.fillEllipse(in: ledRect.insetBy(dx: -1.6, dy: -1.6))
        ctx.setFillColor(NSColor(white: 0.25, alpha: 1).cgColor); ctx.fillEllipse(in: ledRect.insetBy(dx: -0.6, dy: -0.6))
        Analog.led(ctx, in: ledRect, color: look.ledColor, lit: engaged)
        // Signal LEDs by the input (left) and output (right) jacks.
        for (left, level) in [(true, inLevel), (false, outLevel)] where !screen.isHidden {
            let r = signalRect(left: left).insetBy(dx: 2, dy: 2)
            let color: NSColor = level > 0.92 ? Theme.hex(0xFF3B30) : Theme.hex(0x4CD964)
            ctx.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor); ctx.fillEllipse(in: r.insetBy(dx: -1, dy: -1))
            Analog.led(ctx, in: r, color: color, lit: engaged && level > 0.02, glow: level > 0.3)
            let tag = (left ? "IN" : "OUT") as NSString
            let ta: [NSAttributedString.Key: Any] = [.font: Theme.ui(5.5, .bold), .foregroundColor: look.ink.withAlphaComponent(0.75)]
            let ts = tag.size(withAttributes: ta)
            tag.draw(at: CGPoint(x: left ? r.maxX + 3 : r.minX - 3 - ts.width, y: r.midY - ts.height / 2), withAttributes: ta)
        }
    }

    /// The finish is costly to draw; it is rendered once per size and look.
    private func texture(for size: CGSize) -> CGImage? {
        if let (s, img) = textureCache, s == size { return img }
        let scale: CGFloat = 2
        guard size.width > 2, size.height > 2,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        PedalDraw.finish(ctx, CGRect(origin: .zero, size: size), look: look, seed: name)
        let img = ctx.makeImage()
        textureCache = img.map { (size, $0) }
        return img
    }
}

/// A menu item that runs a closure (pedal menus are built on demand).
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: Drawing

/// Drawing for pedals. All coordinates are in flipped views (y grows downward).
@MainActor
enum PedalDraw {
    static func angle(_ v: Double) -> CGFloat { CGFloat(-0.75 * .pi * 2 * 0.5 + v * 1.5 * .pi) - .pi / 2 } // −135°…+135° from up

    static func contrast(_ c: NSColor) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent > 0.55 ? Theme.hex(0x161412) : Theme.hex(0xF6F0E2)
    }

    static func enclosure(_ ctx: CGContext, _ r: CGRect, look: PedalLook, texture: CGImage?) {
        let path = CGPath(roundedRect: r, cornerWidth: look.corner, cornerHeight: look.corner, transform: nil)
        // Cast shadow on the board.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 9, color: NSColor(white: 0, alpha: 0.75).cgColor)
        ctx.addPath(path); ctx.setFillColor(look.color.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        if let texture { ctx.draw(texture, in: r) }
        // Light from above: a soft top sheen and a darker bottom.
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(white: 1, alpha: 0.16).cgColor, NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.22).cgColor] as CFArray,
                              locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        }
        ctx.restoreGState()
        // Rolled edges: bright top lip, dark bottom lip, crisp outline.
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerWidth: look.corner - 1, cornerHeight: look.corner - 1, transform: nil))
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.22).cgColor); ctx.setLineWidth(1.2); ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(NSColor(white: 0, alpha: 0.7).cgColor); ctx.setLineWidth(1); ctx.strokePath()
    }

    /// The paint or metal finish, seeded so it never shimmers between redraws.
    static func finish(_ ctx: CGContext, _ r: CGRect, look: PedalLook, seed: String) {
        var rnd = PedalRandom(seed + "finish")
        let base = look.color
        ctx.setFillColor(base.cgColor); ctx.fill(r)
        switch look.finish {
        case .powder:
            for _ in 0..<Int(r.width * r.height / 6) {
                let a = rnd.range(0.02, 0.06)
                ctx.setFillColor(NSColor(white: rnd.unit() < 0.5 ? 0 : 1, alpha: a).cgColor)
                ctx.fill(CGRect(x: rnd.range(r.minX, r.maxX), y: rnd.range(r.minY, r.maxY), width: 0.6, height: 0.6))
            }
        case .hammertone:
            for _ in 0..<Int(r.width * r.height / 30) {
                let s = rnd.range(3, 9), light = rnd.unit() < 0.5
                ctx.setFillColor(NSColor(white: light ? 1 : 0, alpha: rnd.range(0.04, 0.1)).cgColor)
                ctx.fillEllipse(in: CGRect(x: rnd.range(r.minX - 4, r.maxX), y: rnd.range(r.minY - 4, r.maxY), width: s, height: s * rnd.range(0.7, 1)))
            }
        case .sparkle:
            for _ in 0..<Int(r.width * r.height / 9) {
                let s = rnd.range(0.4, 1.1)
                ctx.setFillColor(NSColor(white: 1, alpha: rnd.range(0.08, 0.55)).cgColor)
                ctx.fillEllipse(in: CGRect(x: rnd.range(r.minX, r.maxX), y: rnd.range(r.minY, r.maxY), width: s, height: s))
            }
        case .brushed:
            var y = r.minY
            while y < r.maxY {
                ctx.setFillColor(NSColor(white: rnd.unit() < 0.5 ? 1 : 0, alpha: rnd.range(0.02, 0.08)).cgColor)
                ctx.fill(CGRect(x: r.minX, y: y, width: r.width, height: rnd.range(0.3, 0.8)))
                y += rnd.range(0.5, 1.4)
            }
        case .anodized:
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [NSColor(white: 1, alpha: 0.14).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.25), startRadius: 0,
                                       endCenter: CGPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.25), endRadius: r.width, options: [])
            }
        }
    }

    static func artwork(_ ctx: CGContext, _ box: CGRect, band: CGRect, look: PedalLook) {
        let accent = Theme.hex(look.accent), ink = look.ink
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: look.corner, cornerHeight: look.corner, transform: nil)); ctx.clip()
        switch look.artwork {
        case .plain: break
        case .stripe:
            ctx.setFillColor(accent.cgColor)
            ctx.fill(CGRect(x: box.minX, y: band.midY - 11, width: box.width, height: 22))
            ctx.setFillColor(NSColor(white: 0, alpha: 0.25).cgColor)
            ctx.fill(CGRect(x: box.minX, y: band.midY + 11, width: box.width, height: 1))
        case .border:
            ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 5, dy: 5), cornerWidth: max(2, look.corner - 3), cornerHeight: max(2, look.corner - 3), transform: nil))
            ctx.setStrokeColor(ink.withAlphaComponent(0.75).cgColor); ctx.setLineWidth(1.4); ctx.strokePath()
        case .pinstripe:
            ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1)
            for dy in [CGFloat(-12), -9, 9, 12] {
                ctx.move(to: CGPoint(x: box.minX + 6, y: band.midY + dy)); ctx.addLine(to: CGPoint(x: box.maxX - 6, y: band.midY + dy))
            }
            ctx.strokePath()
        case .circle:
            let d = min(box.width, box.height) * 0.9
            ctx.setFillColor(accent.withAlphaComponent(0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: box.midX - d / 2, y: box.midY - d / 2 - 6, width: d, height: d))
        case .chevron:
            ctx.setFillColor(accent.withAlphaComponent(0.55).cgColor)
            for k in 0..<3 {
                let y = box.maxY - 22 - CGFloat(k) * 9
                ctx.move(to: CGPoint(x: box.minX, y: y)); ctx.addLine(to: CGPoint(x: box.midX, y: y - 14)); ctx.addLine(to: CGPoint(x: box.maxX, y: y))
                ctx.addLine(to: CGPoint(x: box.maxX, y: y + 4)); ctx.addLine(to: CGPoint(x: box.midX, y: y - 10)); ctx.addLine(to: CGPoint(x: box.minX, y: y + 4))
                ctx.closePath()
            }
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Printed scale around a knob: ticks (and 0–10 numerals on big numbered knobs).
    static func scale(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, look: PedalLook, steps: Int, numbered: Bool) {
        guard steps > 0 else { return }
        ctx.setStrokeColor(look.ink.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(0.8)
        for i in 0...steps {
            let a = angle(Double(i) / Double(steps))
            ctx.move(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * (r + 2.5), y: c.y + sin(a) * (r + 2.5)))
        }
        ctx.strokePath()
        guard numbered else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(5.5, .bold), .foregroundColor: look.ink.withAlphaComponent(0.85)]
        for i in [0, 5, 10] {
            let a = angle(Double(i) / 10), s = "\(i)" as NSString, sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: c.x + cos(a) * (r + 5.5) - sz.width / 2, y: c.y + sin(a) * (r + 5.5) - sz.height / 2), withAttributes: attrs)
        }
    }

    static func knob(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, angle a: CGFloat, look: PedalLook) {
        let cap = Theme.hex(look.knobColor)
        let dark = (cap.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) < 0.5
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2.5), blur: 3.5, color: NSColor(white: 0, alpha: 0.7).cgColor)
        ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        switch look.knob {
        case .ribbed:
            ctx.setFillColor(Theme.hex(0x161616).cgColor); ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor(white: 0.32, alpha: 1).cgColor); ctx.setLineWidth(0.8)
            for k in 0..<28 { // knurled skirt ribs
                let t = a + CGFloat(k) * 2 * .pi / 28
                ctx.move(to: CGPoint(x: c.x + cos(t) * r * 0.78, y: c.y + sin(t) * r * 0.78))
                ctx.addLine(to: CGPoint(x: c.x + cos(t) * r, y: c.y + sin(t) * r))
            }
            ctx.strokePath()
            gloss(ctx, CGRect(x: c.x - r * 0.72, y: c.y - r * 0.72, width: r * 1.44, height: r * 1.44), base: Theme.hex(0x202020))
            pointer(ctx, c, r * 0.12, r * 0.72, a, .white, width: 1.6)
        case .chrome:
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [NSColor(white: 0.97, alpha: 1).cgColor, NSColor(white: 0.55, alpha: 1).cgColor, NSColor(white: 0.85, alpha: 1).cgColor, NSColor(white: 0.4, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 0.35, 0.6, 1]) {
                ctx.saveGState(); ctx.addEllipse(in: rect); ctx.clip()
                ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
                ctx.restoreGState()
            }
            ctx.setStrokeColor(NSColor(white: 0.3, alpha: 0.5).cgColor); ctx.setLineWidth(0.5)
            for k in 0..<36 {
                let t = CGFloat(k) * 2 * .pi / 36 + a
                ctx.move(to: CGPoint(x: c.x + cos(t) * r * 0.86, y: c.y + sin(t) * r * 0.86)); ctx.addLine(to: CGPoint(x: c.x + cos(t) * r, y: c.y + sin(t) * r))
            }
            ctx.strokePath()
            ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor); ctx.fillEllipse(in: rect.insetBy(dx: r * 0.3, dy: r * 0.3))
            pointer(ctx, c, r * 0.15, r * 0.82, a, Theme.hex(0x111111), width: 1.6)
        case .skirted:
            ctx.setFillColor(Theme.hex(0x141414).cgColor); ctx.fillEllipse(in: rect) // skirt
            ctx.setStrokeColor(NSColor(white: 0.85, alpha: 0.9).cgColor); ctx.setLineWidth(0.6)
            for k in 0...10 { // the skirt's own scale turns with it
                let t = a + CGFloat(k - 5) * 0.26
                ctx.move(to: CGPoint(x: c.x + cos(t) * r * 0.8, y: c.y + sin(t) * r * 0.8)); ctx.addLine(to: CGPoint(x: c.x + cos(t) * r * 0.95, y: c.y + sin(t) * r * 0.95))
            }
            ctx.strokePath()
            gloss(ctx, rect.insetBy(dx: r * 0.3, dy: r * 0.3), base: Theme.hex(0xE9E0C8))
            pointer(ctx, c, r * 0.1, r * 0.95, a, Theme.hex(0xC0281F), width: 1.4)
        case .jellybean:
            gloss(ctx, rect, base: cap)
            pointer(ctx, c, r * 0.25, r * 0.85, a, dark ? .white : Theme.hex(0x111111), width: 1.8)
        case .chickenhead:
            ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); ctx.fillEllipse(in: rect.insetBy(dx: r * 0.15, dy: r * 0.15))
            chickenhead(ctx, center: c, radius: r, angle: a, color: look.knobColor)
        }
    }

    /// A pointed bakelite knob (the classic stepped selector).
    static func chickenhead(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, angle a: CGFloat, color: UInt32) {
        let cap = Theme.hex(color)
        let tip = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
        let back = r * 0.62, half = r * 0.42
        let b1 = CGPoint(x: c.x + cos(a + .pi) * back + cos(a + .pi / 2) * half, y: c.y + sin(a + .pi) * back + sin(a + .pi / 2) * half)
        let b2 = CGPoint(x: c.x + cos(a + .pi) * back - cos(a + .pi / 2) * half, y: c.y + sin(a + .pi) * back - sin(a + .pi / 2) * half)
        let p = CGMutablePath()
        p.move(to: tip)
        p.addQuadCurve(to: b1, control: CGPoint(x: c.x + cos(a + .pi / 2) * r * 0.55, y: c.y + sin(a + .pi / 2) * r * 0.55))
        p.addQuadCurve(to: b2, control: CGPoint(x: c.x + cos(a + .pi) * r * 0.95, y: c.y + sin(a + .pi) * r * 0.95))
        p.addQuadCurve(to: tip, control: CGPoint(x: c.x - cos(a + .pi / 2) * r * 0.55, y: c.y - sin(a + .pi / 2) * r * 0.55))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: NSColor(white: 0, alpha: 0.7).cgColor)
        ctx.addPath(p); ctx.setFillColor(cap.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(white: 1, alpha: 0.3).cgColor, NSColor(white: 0, alpha: 0.25).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: c.x, y: c.y - r), end: CGPoint(x: c.x, y: c.y + r), options: [])
        }
        ctx.restoreGState()
        let dark = (cap.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) < 0.5
        pointer(ctx, c, r * 0.1, r * 0.88, a, dark ? .white : Theme.hex(0x111111), width: 1.3)
    }

    private static func gloss(_ ctx: CGContext, _ rect: CGRect, base: NSColor) {
        ctx.saveGState(); ctx.addEllipse(in: rect); ctx.clip()
        let lighter = base.blended(withFraction: 0.35, of: .white) ?? base, darker = base.blended(withFraction: 0.35, of: .black) ?? base
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [lighter.cgColor, base.cgColor, darker.cgColor] as CFArray, locations: [0, 0.5, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: rect.midX - rect.width * 0.15, y: rect.midY - rect.height * 0.2), startRadius: 0,
                                   endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.62, options: [.drawsAfterEndLocation])
        }
        ctx.setFillColor(NSColor(white: 1, alpha: 0.28).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.12, width: rect.width * 0.36, height: rect.height * 0.2))
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.55).cgColor); ctx.setLineWidth(0.6); ctx.strokeEllipse(in: rect)
    }

    private static func pointer(_ ctx: CGContext, _ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat, _ a: CGFloat, _ color: NSColor, width: CGFloat) {
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0)); ctx.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
        ctx.strokePath()
    }

    /// A miniature bat-handle toggle on a hex nut.
    static func toggle(_ ctx: CGContext, center c: CGPoint, up: Bool) {
        let nut = CGMutablePath()
        for k in 0..<6 {
            let t = CGFloat(k) * .pi / 3 + .pi / 6
            let p = CGPoint(x: c.x + cos(t) * 8, y: c.y + sin(t) * 8)
            k == 0 ? nut.move(to: p) : nut.addLine(to: p)
        }
        nut.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 2, color: NSColor(white: 0, alpha: 0.6).cgColor)
        ctx.addPath(nut); ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.setFillColor(NSColor(white: 0.45, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
        let tip = CGPoint(x: c.x, y: up ? c.y - 15 : c.y + 15)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1.5, height: up ? 1 : 3), blur: 2, color: NSColor(white: 0, alpha: 0.6).cgColor)
        ctx.setStrokeColor(NSColor(white: 0.82, alpha: 1).cgColor); ctx.setLineWidth(3.2); ctx.setLineCap(.round)
        ctx.move(to: c); ctx.addLine(to: tip); ctx.strokePath()
        ctx.restoreGState()
        ctx.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: tip.x - 2.6, y: tip.y - 2.6, width: 5.2, height: 5.2))
    }

    static func slider(_ ctx: CGContext, in r: CGRect, value: Double, look: PedalLook) {
        ctx.setFillColor(NSColor(white: 0.05, alpha: 0.9).cgColor)
        ctx.fill(CGRect(x: r.midX - 1.5, y: r.minY + 2, width: 3, height: r.height - 4))
        let y = r.maxY - 4 - CGFloat(value) * (r.height - 8)
        let cap = CGRect(x: r.minX - 1, y: y - 3.5, width: r.width + 2, height: 7)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 2, color: NSColor(white: 0, alpha: 0.6).cgColor)
        ctx.setFillColor(Theme.hex(look.knobColor).cgColor); ctx.fill(cap)
        ctx.restoreGState()
        ctx.setFillColor(contrast(Theme.hex(look.knobColor)).cgColor); ctx.fill(CGRect(x: cap.minX, y: cap.midY - 0.5, width: cap.width, height: 1))
    }

    static func footswitch(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, style: PedalLook.Switch, pressed: Bool) {
        switch style {
        case .chrome:
            // Hex mounting nut, then the plunger cap (it sinks a little while pressed).
            let nut = CGMutablePath()
            for k in 0..<6 {
                let t = CGFloat(k) * .pi / 3
                let p = CGPoint(x: c.x + cos(t) * r, y: c.y + sin(t) * r)
                k == 0 ? nut.move(to: p) : nut.addLine(to: p)
            }
            nut.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: NSColor(white: 0, alpha: 0.65).cgColor)
            ctx.addPath(nut); ctx.setFillColor(NSColor(white: 0.66, alpha: 1).cgColor); ctx.fillPath()
            ctx.restoreGState()
            let capR = r * (pressed ? 0.56 : 0.62)
            let cap = CGRect(x: c.x - capR, y: c.y - capR + (pressed ? 0.8 : 0), width: capR * 2, height: capR * 2)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [NSColor(white: 0.98, alpha: 1).cgColor, NSColor(white: 0.6, alpha: 1).cgColor, NSColor(white: 0.9, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 0.55, 1]) {
                ctx.saveGState(); ctx.addEllipse(in: cap); ctx.clip()
                ctx.drawLinearGradient(g, start: CGPoint(x: cap.minX, y: cap.minY), end: CGPoint(x: cap.maxX, y: cap.maxY), options: [])
                ctx.restoreGState()
            }
            ctx.setStrokeColor(NSColor(white: 0.25, alpha: 0.8).cgColor); ctx.setLineWidth(0.8); ctx.strokeEllipse(in: cap)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.5).cgColor); ctx.strokeEllipse(in: cap.insetBy(dx: capR * 0.35, dy: capR * 0.35))
        case .rubber:
            let pad = CGRect(x: c.x - r, y: c.y - r * 0.8, width: r * 2, height: r * 1.6)
            let path = CGPath(roundedRect: pad, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: pressed ? 0.5 : 2.5), blur: 3, color: NSColor(white: 0, alpha: 0.7).cgColor)
            ctx.addPath(path); ctx.setFillColor(Theme.hex(pressed ? 0x141414 : 0x1C1C1C).cgColor); ctx.fillPath()
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.07).cgColor); ctx.setLineWidth(1)
            var y = pad.minY + 4
            while y < pad.maxY - 3 { ctx.move(to: CGPoint(x: pad.minX + 4, y: y)); ctx.addLine(to: CGPoint(x: pad.maxX - 4, y: y)); y += 3 }
            ctx.strokePath()
        }
    }

    /// The pedalboard: an aluminium frame with carpeted rails and dark gaps between them.
    static func board(_ ctx: CGContext, _ r: CGRect) {
        ctx.setFillColor(Theme.hex(0x0B0A09).cgColor); ctx.fill(r)
        let railH: CGFloat = 34, gap: CGFloat = 9
        var y = r.minY + 8
        var rnd = PedalRandom("board")
        while y < r.maxY - 8 {
            let rail = CGRect(x: r.minX, y: y, width: r.width, height: railH)
            ctx.setFillColor(Theme.hex(0x2E2A25).cgColor); ctx.fill(rail)
            for _ in 0..<Int(rail.width * rail.height / 14) { // loop-carpet fibres
                ctx.setFillColor(NSColor(white: rnd.unit() < 0.5 ? 0 : 1, alpha: rnd.range(0.03, 0.09)).cgColor)
                ctx.fill(CGRect(x: rnd.range(rail.minX, rail.maxX), y: rnd.range(rail.minY, rail.maxY), width: 1, height: 1))
            }
            ctx.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor); ctx.fill(CGRect(x: r.minX, y: y, width: r.width, height: 1))
            ctx.setFillColor(NSColor(white: 0, alpha: 0.5).cgColor); ctx.fill(CGRect(x: r.minX, y: rail.maxY - 1, width: r.width, height: 1))
            y += railH + gap
        }
        // Brushed frame lips along the top and bottom edges.
        for edge in [CGRect(x: r.minX, y: r.minY, width: r.width, height: 5), CGRect(x: r.minX, y: r.maxY - 5, width: r.width, height: 5)] {
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [NSColor(white: 0.62, alpha: 1).cgColor, NSColor(white: 0.32, alpha: 1).cgColor] as CFArray, locations: [0, 1]) {
                ctx.saveGState(); ctx.clip(to: edge)
                ctx.drawLinearGradient(g, start: CGPoint(x: edge.midX, y: edge.minY), end: CGPoint(x: edge.midX, y: edge.maxY), options: [])
                ctx.restoreGState()
            }
        }
    }
}
