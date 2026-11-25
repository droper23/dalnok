// Guitar Studio's modules as hardware: each module type is its own unit (stompbox, wah, amp head, speaker cabinet,
// rack unit, spring tank) with its controls on it. The designs and names are Dalnok's own.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// How one module type looks.
struct RigLook {
    enum Form { case stomp, wah, amp, cabinet, rack, spring }
    let form: Form
    let brand: String
    let kind: String
    let body: NSColor
    var finish: RigPaint.Finish = .gloss
    var ink: NSColor = .white
    var knob: RigKnob.Style = .skirted(cap: RigPaint.hex(0x1a1a1a), skirt: RigPaint.hex(0x2a2a2a))
    var fonts: [String] = ["Futura-Bold"]
    var led: NSColor = RigPaint.hex(0xff2a1a)
    /// Amps and racks: the faceplate colour; amps: the grille cloth (nil: steel mesh).
    var panel: NSColor = RigPaint.hex(0xc8c9cb)
    var cloth: NSColor? = nil
    var thread: NSColor = .clear

    var size: CGSize {
        switch form {
        case .stomp: CGSize(width: 176, height: 306)
        case .wah: CGSize(width: 232, height: 276)
        case .amp: CGSize(width: 600, height: 252)
        case .cabinet: CGSize(width: 410, height: 352)
        case .rack: CGSize(width: 560, height: 196)
        case .spring: CGSize(width: 430, height: 244)
        }
    }

    @MainActor static func of(_ type: Int) -> RigLook {
        func h(_ v: UInt32) -> NSColor { RigPaint.hex(v) }
        switch StudioLayout.catalog[type].name {
        case "Noise Gate":
            return RigLook(form: .stomp, brand: "HUSH", kind: "NOISE GATE", body: h(0x34414d), finish: .matte, ink: h(0xe8eef2),
                           knob: .ribbed(h(0x1b1c1e)), fonts: ["Futura-CondensedExtraBold", "Futura-Bold"], led: h(0x37d16a))
        case "Compressor":
            return RigLook(form: .stomp, brand: "SQUEEZE", kind: "COMPRESSOR", body: h(0x1f56b3), finish: .sparkle, ink: .white,
                           knob: .skirted(cap: h(0x151515), skirt: h(0xbfc3c7)), fonts: ["AvenirNext-HeavyItalic", "Futura-Bold"])
        case "Boost":
            return RigLook(form: .stomp, brand: "LIFT", kind: "CLEAN BOOST", body: h(0xe9e4d6), finish: .gloss, ink: h(0x1f2a44),
                           knob: .knurled(h(0xe6e8ea)), fonts: ["Futura-Bold"], led: h(0x2f8cff))
        case "Overdrive":
            return RigLook(form: .stomp, brand: "Honey", kind: "OVERDRIVE", body: h(0xe0a91f), finish: .gloss, ink: h(0x2a1a06),
                           knob: .skirted(cap: h(0xf0e6cf), skirt: h(0x2a2117)), fonts: ["SnellRoundhand-Black", "Didot-Bold"])
        case "Distortion":
            return RigLook(form: .stomp, brand: "IRONCLAD", kind: "DISTORTION", body: h(0x1a1a1c), finish: .matte, ink: h(0xff7a1a),
                           knob: .ribbed(h(0x232326)), fonts: ["Futura-CondensedExtraBold", "Impact"], led: h(0xff4b14))
        case "Fuzz":
            return RigLook(form: .stomp, brand: "Molten", kind: "FUZZ", body: h(0xb4532a), finish: .hammertone, ink: h(0xfff1dc),
                           knob: .chicken(h(0x171717)), fonts: ["MarkerFelt-Wide", "Chalkduster"])
        case "Wah":
            return RigLook(form: .wah, brand: "QUACK", kind: "WAH", body: h(0x1c1c1e), finish: .hammertone, ink: h(0xd9dde1),
                           knob: .ribbed(h(0x202022)), fonts: ["Futura-Bold"], led: h(0xff2a1a))
        case "Chorus":
            return RigLook(form: .stomp, brand: "SHIMMER", kind: "CHORUS", body: h(0x2aa6a3), finish: .sparkle, ink: h(0x0d2a2d),
                           knob: .skirted(cap: h(0xf4f4f2), skirt: h(0xd7dadc)), fonts: ["Optima-ExtraBlack", "Futura-Bold"], led: h(0x2f8cff))
        case "Flanger":
            return RigLook(form: .stomp, brand: "JETWASH", kind: "FLANGER", body: h(0x58288a), finish: .sparkle, ink: h(0xf1e8ff),
                           knob: .knurled(h(0xd9dcdf)), fonts: ["Futura-CondensedExtraBold", "Futura-Bold"], led: h(0xc06bff))
        case "Phaser":
            return RigLook(form: .stomp, brand: "ORBIT", kind: "PHASER", body: h(0xd8441f), finish: .gloss, ink: .white,
                           knob: .ribbed(h(0x1a1a1a)), fonts: ["AvenirNext-HeavyItalic", "Futura-Bold"])
        case "Tremolo":
            return RigLook(form: .stomp, brand: "Pulsar", kind: "TREMOLO", body: h(0x8ccaa6), finish: .gloss, ink: h(0x173327),
                           knob: .chicken(h(0xf1e9d6)), fonts: ["Copperplate-Bold", "Didot-Bold"], led: h(0xffb21a))
        case "Vibrato":
            return RigLook(form: .stomp, brand: "Warble", kind: "VIBRATO", body: h(0xa98ccf), finish: .gloss, ink: h(0x24133a),
                           knob: .skirted(cap: h(0x161616), skirt: h(0x2b2b2b)), fonts: ["SnellRoundhand-Black", "Didot-Bold"], led: h(0x37d16a))
        case "Amp Clean":
            return RigLook(form: .amp, brand: "Parlor", kind: "THIRTY-FIVE", body: h(0xe3d6b8), ink: h(0x1d1a16),
                           knob: .skirted(cap: h(0x171717), skirt: h(0x1e1e1e)), fonts: ["SnellRoundhand-Black", "Didot-Bold"], led: h(0xff3b2a),
                           panel: h(0xc9cbcd), cloth: h(0x5e241e), thread: h(0xc9a466))
        case "Amp Crunch":
            return RigLook(form: .amp, brand: "Foundry", kind: "FIFTY", body: h(0x191919), ink: h(0x15120c),
                           knob: .skirted(cap: h(0xd6b25e), skirt: h(0x161616)), fonts: ["SnellRoundhand-Black", "Didot-Bold"], led: h(0xff3b2a),
                           panel: h(0xc9a24f), cloth: h(0x2b2722), thread: h(0xb9ad97))
        case "Amp Lead":
            return RigLook(form: .amp, brand: "INFERNO", kind: "ONE HUNDRED", body: h(0x141414), ink: h(0xe9e9ea),
                           knob: .knurled(h(0xd8dbde)), fonts: ["Futura-CondensedExtraBold", "Impact"], led: h(0xff2a1a),
                           panel: h(0x1d1d1f), cloth: nil, thread: h(0x777b80))
        case "Cabinet":
            return RigLook(form: .cabinet, brand: "DALNOK", kind: "CABINET", body: h(0x1a1a1a), ink: h(0xdcdcdc),
                           knob: .chicken(h(0x181818)), fonts: ["Futura-Bold"], panel: h(0x2b2b2d))
        case "EQ":
            return RigLook(form: .rack, brand: "PARAGRAPHIC", kind: "SIX-BAND EQUALIZER", body: h(0x26282b), ink: h(0x1d2024),
                           knob: .skirted(cap: h(0x2a6bd1), skirt: h(0x1b1b1c)), fonts: ["Futura-Bold"], led: h(0x37d16a), panel: h(0xc8cacc))
        case "Delay":
            return RigLook(form: .rack, brand: "ECHO LAB", kind: "DIGITAL DELAY", body: h(0x26282b), ink: h(0xe8e8e8),
                           knob: .knurled(h(0xdfe1e3)), fonts: ["Futura-CondensedExtraBold", "Futura-Bold"], led: h(0xff2a1a), panel: h(0x1b1c1f))
        case "Reverb":
            return RigLook(form: .rack, brand: "CATHEDRAL", kind: "STEREO REVERB", body: h(0x26282b), ink: h(0xdfe6f2),
                           knob: .skirted(cap: h(0xd4d7db), skirt: h(0x18191b)), fonts: ["Optima-ExtraBlack", "Futura-Bold"], led: h(0x4aa3ff),
                           panel: h(0x1e2a3d))
        case "Spring":
            return RigLook(form: .spring, brand: "Spring Tank", kind: "REVERB", body: h(0x5a3a24), ink: h(0xf1e7d2),
                           knob: .chicken(h(0xf0e6d2)), fonts: ["SnellRoundhand-Black", "Didot-Bold"], led: h(0xffb21a),
                           panel: h(0x2a1d14), cloth: h(0xd8c9a6), thread: h(0x8a7552))
        default:
            return RigLook(form: .stomp, brand: "EMPTY", kind: "", body: .darkGray)
        }
    }

    static let shortNames: [String: String] = [
        "Frequency": "FREQ", "Resonance": "RESO", "Modulation": "MOD", "Threshold": "THRESH", "Presence": "PRESENCE",
    ]
}

/// One module on the stage. Subclasses place the controls and draw the unit; the base keeps them in step with the engine.
@MainActor
class RigUnit: NSView {
    let rig: StudioRig
    let slot: Int, index: Int, type: Int
    let look: RigLook
    private(set) var knobViews: [RigKnob] = []
    private(set) var isOn = true
    var onSwitch: RigFootswitch?

    init(rig: StudioRig, slot: Int, index: Int) {
        self.rig = rig
        self.slot = slot
        self.index = index
        type = StudioLayout.type(rig.value(StudioLayout.typeId(slot)))
        look = RigLook.of(type)
        super.init(frame: CGRect(origin: .zero, size: look.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Slot \(index + 1): \(StudioLayout.catalog[type].name)")
        build()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var name: String { StudioLayout.catalog[type].name }

    /// One knob per engine knob of this module (in order), not yet placed.
    func makeKnobs(diameter: CGFloat, scale: RigKnob.Scale = .none, style: RigKnob.Style? = nil, label: NSColor? = nil,
                   size: CGFloat = 8.5) -> [RigKnob] {
        let font = RigPaint.font(["Futura-Bold"], size)
        let made = rig.knobs(slot: slot).map { k -> RigKnob in
            let v = RigKnob(diameter: diameter, style: style ?? look.knob, name: RigLook.shortNames[k.name] ?? k.name, scale: scale)
            v.labelColor = label ?? look.ink
            v.labelFont = font
            v.defaultValue = k.defaultValue
            v.steps = k.steps
            v.value = k.value
            v.identifier = NSUserInterfaceItemIdentifier("rig-knob-\(k.id)")
            v.setAccessibilityLabel("\(name) \(k.name)")
            let id = k.id
            v.valueText = { [weak self] in self?.rig.parameter(id).map { fixedString($0.display) } ?? "" }
            v.onChange = { [weak self] value in self?.knobMoved(id, value) }
            v.toolTip = "\(k.name): drag up or down (⇧ for fine), double-click for the default"
            addSubview(v)
            return v
        }
        knobViews += made
        return made
    }
    func knobMoved(_ id: UInt32, _ value: Double) {
        rig.set(id, value)
        needsDisplay = true // displays and drawings that follow a knob
    }
    func knobId(_ k: Int) -> UInt32 { StudioLayout.knobId(slot, k) }
    func knobValue(_ k: Int) -> Double { rig.value(knobId(k)) }
    func knobText(_ k: Int) -> String { rig.parameter(knobId(k)).map { fixedString($0.display) } ?? "" }

    /// A footswitch that switches this module.
    func makeFootswitch(size: CGFloat = 46) -> RigFootswitch {
        let f = RigFootswitch()
        f.frame.size = CGSize(width: size, height: size)
        f.name = name
        f.onPress = { [weak self] in self.map { $0.rig.toggle($0.index) } }
        f.toolTip = "Switch \(name) on or off"
        addSubview(f)
        onSwitch = f
        return f
    }

    func build() {}
    /// Reads every control's value from the engine (skipping a knob being dragged).
    func refresh() {
        let on = rig.value(StudioLayout.onId(slot)) >= 0.5
        if on != isOn { isOn = on; needsDisplay = true }
        onSwitch?.isOn = on
        var changed = false
        for k in knobViews where !k.dragging {
            guard let id = k.identifier.flatMap({ UInt32($0.rawValue.dropFirst(9)) }) else { continue }
            let v = rig.value(id)
            if v != k.value { k.value = v; changed = true }
        }
        if changed { needsDisplay = true }
    }
    /// Where the cables plug in (this unit's coordinates).
    var inJack: CGPoint { CGPoint(x: 0, y: bounds.height * 0.42) }
    var outJack: CGPoint { CGPoint(x: bounds.width, y: bounds.height * 0.42) }
    override func menu(for event: NSEvent) -> NSMenu? { rig.moduleMenu(index) }

    /// Lays `views` out in a row centred on `y`, spread across `x0...x1`.
    func row(_ views: [NSView], y: CGFloat, from x0: CGFloat, to x1: CGFloat) {
        guard !views.isEmpty else { return }
        let step = (x1 - x0) / CGFloat(views.count)
        for (i, v) in views.enumerated() {
            let c = CGPoint(x: x0 + step * (CGFloat(i) + 0.5), y: y)
            if let k = v as? RigKnob { k.place(c) } else { v.frame.origin = CGPoint(x: c.x - v.frame.width / 2, y: c.y - v.frame.height / 2) }
        }
    }
    func brandFont(_ size: CGFloat) -> NSFont { RigPaint.font(look.fonts, size) }
    /// The largest size up to `max` at which `text` fits `width`.
    func fitted(_ text: String, _ width: CGFloat, max: CGFloat) -> NSFont {
        var s = max
        while s > 8, (text as NSString).size(withAttributes: [.font: brandFont(s)]).width > width { s -= 1 }
        return brandFont(s)
    }
}

// MARK: - Stompbox

final class StompUnit: RigUnit {
    private var knobBottom: CGFloat = 0
    override func build() {
        let n = rig.knobs(slot: slot).count
        let d: CGFloat = n <= 2 ? 40 : n <= 4 ? 34 : 30
        let ks = makeKnobs(diameter: d, scale: .dots)
        let w = bounds.width
        if n <= 3 {
            row(ks, y: 52, from: 8, to: w - 8)
            knobBottom = 100
        } else {
            let top = Array(ks.prefix(n == 4 ? 2 : 3)), bottom = Array(ks.dropFirst(top.count))
            row(top, y: 44, from: 8, to: w - 8)
            row(bottom, y: 108, from: n == 5 ? 30 : 8, to: n == 5 ? w - 30 : w - 8)
            knobBottom = 150
        }
        let f = makeFootswitch()
        f.frame.origin = CGPoint(x: w / 2 - 23, y: bounds.height - 66)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = bounds.insetBy(dx: 6, dy: 4)
        RigPaint.floorShadow(ctx, box)
        for x in [box.minX - 5, box.maxX - 1] { // side jacks
            RigPaint.vertical(ctx, RigPaint.rounded(CGRect(x: x, y: box.minY + 57, width: 6, height: 18), 2), [RigPaint.hex(0xd8dbde), RigPaint.hex(0x6b6f74)])
        }
        let body = RigPaint.rounded(box, 12)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(body); ctx.setFillColor(look.body.cgColor); ctx.fillPath()
        ctx.restoreGState()
        RigPaint.paint(ctx, body, look.body, look.finish)
        RigPaint.bevel(ctx, body, width: 2)
        // A recessed panel line under the controls, and the footswitch plate.
        let plate = RigPaint.rounded(CGRect(x: box.minX + 10, y: box.maxY - 84, width: box.width - 20, height: 76), 8)
        ctx.saveGState(); ctx.addPath(plate); ctx.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor); ctx.fillPath(); ctx.restoreGState()
        RigPaint.innerEdge(ctx, plate, dark: 0.35, blur: 4)
        for (x, y) in [(box.minX + 9, box.minY + 9), (box.maxX - 9, box.minY + 9), (box.minX + 9, box.maxY - 9), (box.maxX - 9, box.maxY - 9)] {
            RigPaint.screw(ctx, CGPoint(x: x, y: y), 3.2, angle: CGFloat(x + y).truncatingRemainder(dividingBy: 3))
        }
        // LED, name and the module's kind.
        let ledY = knobBottom + 8
        RigPaint.led(ctx, CGPoint(x: bounds.midX, y: ledY), 4, look.led, lit: isOn)
        let nameRect = CGRect(x: box.minX + 10, y: ledY + 10, width: box.width - 20, height: box.maxY - 84 - ledY - 14)
        let script = look.fonts.first?.contains("Snell") == true || look.fonts.first?.contains("Marker") == true
        RigPaint.text(look.brand, nameRect.offsetBy(dx: 0, dy: -5), font: fitted(look.brand, nameRect.width, max: script ? 32 : 26), color: look.ink,
                      kern: script ? 0 : 1.2, emboss: 0.18)
        RigPaint.text(look.kind, CGRect(x: nameRect.minX, y: nameRect.maxY - 9, width: nameRect.width, height: 10),
                      font: RigPaint.font(["Futura-Medium"], 7.5), color: look.ink.withAlphaComponent(0.85), kern: 2.2)
        RigPaint.text("DALNOK", CGRect(x: box.minX, y: box.maxY - 17, width: box.width, height: 10), font: RigPaint.font(["Futura-Bold"], 6.5),
                      color: look.ink.withAlphaComponent(0.55), kern: 2.5)
    }
    override var inJack: CGPoint { CGPoint(x: 1, y: 70) }
    override var outJack: CGPoint { CGPoint(x: bounds.width - 1, y: 70) }
}

// MARK: - Wah

/// The rocker: drag it toe-down (up) or heel-down (down). It drives the module's Pedal knob.
final class RigTreadle: NSView {
    var value: Double = 0.5 { didSet { if value != oldValue { needsDisplay = true } } }
    var onChange: ((Double) -> Void)?
    var valueText: () -> String = { "" }
    var ink = NSColor.white
    private var precise = 0.0
    private(set) var dragging = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Wah pedal position")
        toolTip = "Drag up to rock the pedal toe-down, down for heel-down"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let v = CGFloat(value), b = bounds
        // Toe-down shortens the visible top; the rocker's side shows more as it tilts back.
        let top = b.minY + 6 + v * 34, bottom = b.maxY - 6
        let inset = 8 + (1 - v) * 4
        let p = CGMutablePath()
        p.move(to: CGPoint(x: b.minX + inset + 6, y: top)); p.addLine(to: CGPoint(x: b.maxX - inset - 6, y: top))
        p.addLine(to: CGPoint(x: b.maxX - 2, y: bottom)); p.addLine(to: CGPoint(x: b.minX + 2, y: bottom)); p.closeSubpath()
        let side = CGRect(x: b.minX + 4, y: bottom - 2, width: b.width - 8, height: 6 + (1 - v) * 6)
        RigPaint.vertical(ctx, RigPaint.rounded(side, 2), [RigPaint.hex(0x2b2b2d), RigPaint.hex(0x0b0b0c)])
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 9, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(p); ctx.setFillColor(RigPaint.hex(0x202022).cgColor); ctx.fillPath()
        ctx.restoreGState()
        RigPaint.paint(ctx, p, RigPaint.hex(0x232325), .hammertone)
        let light = 0.1 + v * 0.18
        RigPaint.vertical(ctx, p, [NSColor.white.withAlphaComponent(light), .clear, NSColor.black.withAlphaComponent(0.3)])
        // The rubber grip and its ribs, under a chrome name plate.
        let grip = CGRect(x: b.minX + 14, y: top + 34, width: b.width - 28, height: bottom - top - 50)
        let gp = RigPaint.rounded(grip, 6)
        ctx.saveGState(); ctx.addPath(gp); ctx.setFillColor(RigPaint.hex(0x0f0f10).cgColor); ctx.fillPath(); ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(gp); ctx.clip()
        var y = grip.minY + 5
        while y < grip.maxY {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor); ctx.fill(CGRect(x: grip.minX, y: y, width: grip.width, height: 1.5))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.fill(CGRect(x: grip.minX, y: y + 1.5, width: grip.width, height: 1.5))
            y += 7
        }
        ctx.restoreGState()
        RigPaint.innerEdge(ctx, gp, dark: 0.7, blur: 4)
        let badge = RigPaint.rounded(CGRect(x: b.midX - 46, y: top + 9, width: 92, height: 19), 4)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(badge); ctx.setFillColor(RigPaint.hex(0xa9adb2).cgColor); ctx.fillPath()
        ctx.restoreGState()
        RigPaint.brushed(ctx, badge, RigPaint.hex(0xd9dcdf), streak: 0.5)
        RigPaint.text("QUACK", badge.boundingBox, font: RigPaint.font(["Futura-CondensedExtraBold", "Futura-Bold"], 14), color: RigPaint.hex(0x141414), kern: 3)
        RigPaint.text(dragging ? valueText() : "TOE ▲   ▼ HEEL", CGRect(x: grip.minX, y: grip.maxY - 18, width: grip.width, height: 10),
                      font: RigPaint.font(["Futura-Medium"], 7.5), color: ink.withAlphaComponent(0.7), kern: 1)
        for x in [b.minX + 12, b.maxX - 12] { RigPaint.screw(ctx, CGPoint(x: x, y: bottom - 10), 3) }
    }
    private func commit(_ v: Double) {
        let v = max(0, min(1, v))
        guard v != value else { return }
        value = v
        onChange?(v)
    }
    private var lastY: CGFloat = 0
    override func mouseDown(with event: NSEvent) { precise = value; lastY = event.locationInWindow.y; dragging = true; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        let y = event.locationInWindow.y
        precise = max(0, min(1, precise + Double(y - lastY) / (event.modifierFlags.contains(.shift) ? 700 : 160)))
        lastY = y
        commit(precise)
    }
    override func mouseUp(with event: NSEvent) { dragging = false; needsDisplay = true }
    override func scrollWheel(with event: NSEvent) { commit(value + Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)) }
    override func accessibilityValue() -> Any? { valueText() }
    override func accessibilityPerformIncrement() -> Bool { commit(value + 0.05); return true }
    override func accessibilityPerformDecrement() -> Bool { commit(value - 0.05); return true }
}

final class WahUnit: RigUnit {
    private let treadle = RigTreadle()
    override func build() {
        let ks = makeKnobs(diameter: 22, scale: .dots)
        // The Pedal knob is the treadle itself.
        let pedal = ks.first
        pedal?.isHidden = true
        let rest = Array(ks.dropFirst())
        row(rest, y: bounds.height - 42, from: 8, to: bounds.width - 46)
        treadle.frame = CGRect(x: 26, y: 8, width: bounds.width - 52, height: 186)
        treadle.ink = look.ink
        let id = knobId(0)
        treadle.valueText = { [weak self] in "PEDAL " + (self?.knobText(0) ?? "") }
        treadle.onChange = { [weak self] v in self?.knobMoved(id, v) }
        addSubview(treadle)
        let f = makeFootswitch(size: 30)
        f.frame.origin = CGPoint(x: bounds.width - 44, y: bounds.height - 50)
    }
    override func refresh() {
        super.refresh()
        if !treadle.dragging { treadle.value = knobValue(0) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = CGRect(x: 6, y: 30, width: bounds.width - 12, height: bounds.height - 34)
        RigPaint.floorShadow(ctx, box)
        let body = RigPaint.rounded(box, 14)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(body); ctx.setFillColor(look.body.cgColor); ctx.fillPath()
        ctx.restoreGState()
        RigPaint.paint(ctx, body, look.body, .hammertone)
        RigPaint.bevel(ctx, body, width: 2)
        let plate = RigPaint.rounded(CGRect(x: box.minX + 8, y: box.maxY - 72, width: box.width - 16, height: 64), 6)
        RigPaint.brushed(ctx, plate, RigPaint.hex(0x3a3c40), streak: 0.35)
        RigPaint.innerEdge(ctx, plate, dark: 0.5, blur: 4)
        RigPaint.led(ctx, CGPoint(x: bounds.width - 29, y: bounds.height - 60), 3.2, look.led, lit: isOn)
    }
    override var inJack: CGPoint { CGPoint(x: 6, y: 150) }
    override var outJack: CGPoint { CGPoint(x: bounds.width - 6, y: 150) }
}

// MARK: - Amp head

final class AmpUnit: RigUnit {
    private var toggle = RigToggle()
    override func build() {
        let panelInk = look.ink
        let ks = makeKnobs(diameter: 32, scale: .numbers, label: panelInk, size: 8.5)
        row(ks, y: 182, from: 64, to: bounds.width - 104)
        toggle.frame = CGRect(x: bounds.width - 86, y: 160, width: 26, height: 44)
        toggle.onPress = { [weak self] in self.map { $0.rig.toggle($0.index) } }
        toggle.ink = panelInk
        toggle.setAccessibilityLabel("\(name) on/off")
        addSubview(toggle)
    }
    override func refresh() { super.refresh(); toggle.isOn = isOn }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = CGRect(x: 4, y: 20, width: bounds.width - 8, height: bounds.height - 24)
        RigPaint.floorShadow(ctx, box)
        // The leather handle.
        let handle = RigPaint.rounded(CGRect(x: box.midX - 60, y: 6, width: 120, height: 20), 9)
        RigPaint.vertical(ctx, handle, [RigPaint.hex(0x3b3b3b), RigPaint.hex(0x0d0d0d)])
        for x in [box.midX - 66, box.midX + 54] {
            RigPaint.vertical(ctx, RigPaint.rounded(CGRect(x: x, y: 14, width: 12, height: 10), 2), [RigPaint.hex(0xe6e8ea), RigPaint.hex(0x63676c)])
        }
        let body = RigPaint.rounded(box, 10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(body); ctx.setFillColor(look.body.cgColor); ctx.fillPath()
        ctx.restoreGState()
        RigPaint.tolex(ctx, body, look.body)
        // Piping around the front.
        let front = box.insetBy(dx: 12, dy: 12)
        ctx.setStrokeColor((look.body.brightnessComponentOr(0.5) > 0.5 ? RigPaint.hex(0x6b5a40) : RigPaint.hex(0xd8d3c6)).cgColor)
        ctx.setLineWidth(2); ctx.addPath(RigPaint.rounded(front.insetBy(dx: -2, dy: -2), 6)); ctx.strokePath()
        // Grille and logo.
        let grilleRect = CGRect(x: front.minX, y: front.minY, width: front.width, height: 104)
        let g = RigPaint.rounded(grilleRect, 4)
        if let cloth = look.cloth { RigPaint.grille(ctx, g, base: cloth, thread: look.thread) } else { RigPaint.mesh(ctx, g, base: look.thread) }
        let logoFont = brandFont(look.fonts.first?.contains("Snell") == true ? 50 : 40)
        let logoColor: NSColor = look.cloth == nil ? RigPaint.hex(0xe0e2e5) : RigPaint.hex(0xf3ead2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1, height: -3), blur: 4, color: NSColor.black.withAlphaComponent(0.8).cgColor)
        RigPaint.text(look.brand, grilleRect.insetBy(dx: 0, dy: 10), font: logoFont, color: logoColor, kern: look.cloth == nil ? 6 : 0)
        ctx.restoreGState()
        if look.cloth == nil { // the lead amp's red glow behind the mesh
            ctx.saveGState(); ctx.addPath(g); ctx.clip(); ctx.setBlendMode(.screen)
            RigPaint.radial(ctx, CGPoint(x: grilleRect.midX, y: grilleRect.maxY + 10), grilleRect.width * 0.5,
                            [RigPaint.hex(0xff3b1a, isOn ? 0.35 : 0.06), .clear])
            ctx.restoreGState()
        }
        // The control panel.
        let panelRect = CGRect(x: front.minX, y: grilleRect.maxY + 8, width: front.width, height: front.maxY - grilleRect.maxY - 8)
        let panel = RigPaint.rounded(panelRect, 3)
        RigPaint.brushed(ctx, panel, look.panel, streak: look.panel.brightnessComponentOr(0.5) > 0.3 ? 0.55 : 0.3)
        RigPaint.innerEdge(ctx, panel, dark: 0.5, blur: 3)
        RigPaint.text(look.kind, CGRect(x: panelRect.minX + 10, y: panelRect.minY + 4, width: 160, height: 10), font: RigPaint.font(["Futura-Bold"], 7.5),
                      color: look.ink.withAlphaComponent(0.8), align: .left, kern: 2)
        RigPaint.jack(ctx, CGPoint(x: panelRect.minX + 24, y: panelRect.midY + 2), 8)
        RigPaint.text("INPUT", CGRect(x: panelRect.minX + 4, y: panelRect.maxY - 15, width: 40, height: 10), font: RigPaint.font(["Futura-Bold"], 7),
                      color: look.ink)
        RigPaint.jewel(ctx, CGPoint(x: panelRect.maxX - 22, y: panelRect.midY - 4), 8, look.led, lit: isOn)
        for (x, y) in [(panelRect.minX + 6, panelRect.minY + 6), (panelRect.maxX - 6, panelRect.minY + 6)] { RigPaint.screw(ctx, CGPoint(x: x, y: y), 2.4) }
        // Metal corners.
        for (x, y, fx, fy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0), (box.minX, box.maxY, 1.0, -1.0), (box.maxX, box.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            let c = CGMutablePath()
            c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + 20 * fx, y: y)); c.addQuadCurve(to: CGPoint(x: x, y: y + 20 * fy), control: CGPoint(x: x + 8 * fx, y: y + 8 * fy))
            c.closeSubpath()
            RigPaint.vertical(ctx, c, [RigPaint.hex(0xf1f2f3), RigPaint.hex(0x8b9095), RigPaint.hex(0x4a4d51)])
        }
    }
    override var inJack: CGPoint { CGPoint(x: 4, y: 182) }
    override var outJack: CGPoint { CGPoint(x: bounds.width - 4, y: 182) }
}

/// A bat-handle toggle (amp and spring tank power).
final class RigToggle: NSView {
    var isOn = true { didSet { if isOn != oldValue { needsDisplay = true } } }
    var onPress: (() -> Void)?
    var ink = NSColor.white
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        toolTip = "Switch this unit on or off"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY - 2)
        RigPaint.text("ON", CGRect(x: 0, y: -1, width: bounds.width, height: 9), font: RigPaint.font(["Futura-Bold"], 6.5), color: ink)
        RigPaint.jack(ctx, c, 8)
        let tip = CGPoint(x: c.x, y: c.y + (isOn ? -13 : 13))
        ctx.setLineCap(.round)
        ctx.setStrokeColor(RigPaint.hex(0x5a5e63).cgColor); ctx.setLineWidth(5)
        ctx.move(to: c); ctx.addLine(to: tip); ctx.strokePath()
        ctx.setStrokeColor(RigPaint.hex(0xf2f3f4).cgColor); ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: c.x - 0.8, y: c.y)); ctx.addLine(to: CGPoint(x: tip.x - 0.8, y: tip.y)); ctx.strokePath()
        ctx.saveGState(); ctx.addEllipse(in: CGRect(x: tip.x - 4, y: tip.y - 4, width: 8, height: 8)); ctx.clip()
        RigPaint.radial(ctx, tip, 4, [.white, RigPaint.hex(0x8d9196)], focus: CGPoint(x: tip.x - 1.5, y: tip.y - 1.5))
        ctx.restoreGState()
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

private extension NSColor {
    func brightnessComponentOr(_ fallback: CGFloat) -> CGFloat { (usingColorSpace(.sRGB) ?? self).brightnessComponent }
}

// MARK: - Speaker cabinet

/// Speakers behind an open baffle, and the microphone in front of the first one: drag the mic across the cone
/// (Mic: centre to edge) and up/down to move it closer or further (Distance).
final class CabinetUnit: RigUnit {
    private var micDrag: (start: CGPoint, mic: Double, distance: Double)?
    override func build() {
        let ks = makeKnobs(diameter: 22, scale: .dots, label: look.ink, size: 8)
        row(ks, y: bounds.height - 48, from: 20, to: bounds.width - 62)
        power.frame = CGRect(x: bounds.width - 58, y: bounds.height - 66, width: 30, height: 30)
        power.led = RigPaint.hex(0x37d16a)
        power.onPress = { [weak self] in self.map { $0.rig.toggle($0.index) } }
        power.setAccessibilityLabel("\(name) on/off")
        addSubview(power)
    }
    private let power = RackButton()
    override func refresh() { super.refresh(); power.isOn = isOn }
    private var baffle: CGRect { CGRect(x: 20, y: 20, width: bounds.width - 40, height: bounds.height - 104) }
    private var speakers: [(CGPoint, CGFloat)] {
        let b = baffle.insetBy(dx: 10, dy: 10), size = Int((knobValue(0) * 2).rounded())
        switch size {
        case 0: return [(CGPoint(x: b.midX, y: b.midY), min(b.width, b.height) * 0.42)]
        case 1:
            let r = min(b.width / 4, b.height / 2) * 0.92
            return [(CGPoint(x: b.minX + b.width * 0.25, y: b.midY), r), (CGPoint(x: b.minX + b.width * 0.75, y: b.midY), r)]
        default:
            let r = min(b.width / 4, b.height / 4) * 0.92
            return [0.25, 0.75].flatMap { fy in [0.25, 0.75].map { fx in (CGPoint(x: b.minX + b.width * fx, y: b.minY + b.height * fy), r) } }
        }
    }
    /// The mic's head: across the first cone with Mic, larger when close.
    var mic: (center: CGPoint, radius: CGFloat) {
        guard let (c, r) = speakers.first else { return (.zero, 10) }
        let along = CGFloat(knobValue(1)), dist = CGFloat(knobValue(2))
        return (CGPoint(x: c.x + along * r * 0.95, y: c.y + r * 0.15 + dist * 14), 15 - dist * 6)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = bounds.insetBy(dx: 4, dy: 4)
        RigPaint.floorShadow(ctx, box)
        let body = RigPaint.rounded(box, 10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(body); ctx.setFillColor(look.body.cgColor); ctx.fillPath()
        ctx.restoreGState()
        RigPaint.tolex(ctx, body, look.body)
        let b = RigPaint.rounded(baffle, 4)
        RigPaint.paint(ctx, b, RigPaint.hex(0x111112), .matte)
        RigPaint.innerEdge(ctx, b, dark: 0.9, blur: 10)
        for (c, r) in speakers { drawSpeaker(ctx, c, r) }
        drawMic(ctx)
        // The control strip.
        let plateRect = CGRect(x: 20, y: bounds.height - 78, width: bounds.width - 40, height: 64)
        let plate = RigPaint.rounded(plateRect, 4)
        RigPaint.brushed(ctx, plate, look.panel, streak: 0.3)
        RigPaint.innerEdge(ctx, plate, dark: 0.6, blur: 3)
        let sizes = ["1 × 12", "2 × 12", "4 × 12"]
        for (x, y) in [(box.minX + 8, box.minY + 8), (box.maxX - 8, box.minY + 8), (box.minX + 8, box.maxY - 8), (box.maxX - 8, box.maxY - 8)] {
            RigPaint.screw(ctx, CGPoint(x: x, y: y), 3)
        }
        // The badge, on the baffle's top edge.
        let badge = RigPaint.rounded(CGRect(x: baffle.midX - 64, y: baffle.minY - 2, width: 128, height: 16), 3)
        RigPaint.brushed(ctx, badge, RigPaint.hex(0xd5d8db), streak: 0.5)
        RigPaint.text("DALNOK  \(sizes[Int((knobValue(0) * 2).rounded())])", badge.boundingBox, font: RigPaint.font(["Futura-Bold"], 8.5),
                      color: RigPaint.hex(0x1a1a1a), kern: 1.5)
    }
    private func drawSpeaker(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat) {
        func disc(_ rr: CGFloat) -> CGRect { CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr) }
        // Basket rim and bolts.
        ctx.setFillColor(RigPaint.hex(0x2a2b2d).cgColor); ctx.fillEllipse(in: disc(r))
        for k in 0..<8 {
            let a = CGFloat(k) * .pi / 4 + .pi / 8
            RigPaint.screw(ctx, CGPoint(x: c.x + cos(a) * r * 0.93, y: c.y + sin(a) * r * 0.93), max(1.6, r * 0.035), phillips: false)
        }
        // Surround, cone, dust cap.
        ctx.saveGState(); ctx.addEllipse(in: disc(r * 0.86)); ctx.clip()
        RigPaint.radial(ctx, c, r * 0.86, [RigPaint.hex(0x3a3a3b), RigPaint.hex(0x161617), RigPaint.hex(0x2b2b2c)])
        ctx.restoreGState()
        ctx.saveGState(); ctx.addEllipse(in: disc(r * 0.76)); ctx.clip()
        RigPaint.radial(ctx, CGPoint(x: c.x - r * 0.12, y: c.y - r * 0.15), r * 0.9, [RigPaint.hex(0x4a4746), RigPaint.hex(0x262423), RigPaint.hex(0x121111)])
        RigPaint.grain(ctx, disc(r * 0.76), alpha: 0.35, scale: CGSize(width: 0.6, height: 0.6), blend: .softLight)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.8)
        for k in 1...3 { ctx.strokeEllipse(in: disc(r * 0.76 * CGFloat(k) / 3.6 + r * 0.2)) }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.setFillColor(RigPaint.hex(0x2c2c2d).cgColor); ctx.fillEllipse(in: disc(r * 0.24))
        ctx.restoreGState()
        ctx.saveGState(); ctx.addEllipse(in: disc(r * 0.24)); ctx.clip()
        RigPaint.radial(ctx, c, r * 0.24, [RigPaint.hex(0x5c5b5a), RigPaint.hex(0x222222)], focus: CGPoint(x: c.x - r * 0.08, y: c.y - r * 0.1))
        ctx.restoreGState()
    }
    private func drawMic(_ ctx: CGContext) {
        let (c, r) = mic
        // Stand arm from below, then the body and grille head.
        ctx.setLineCap(.round)
        let foot = CGPoint(x: c.x + 26, y: baffle.maxY + 4)
        ctx.setStrokeColor(RigPaint.hex(0x0a0a0a).cgColor); ctx.setLineWidth(3.5)
        ctx.move(to: foot); ctx.addLine(to: CGPoint(x: c.x + r * 0.6, y: c.y + r * 1.6)); ctx.strokePath()
        let body = CGMutablePath()
        body.move(to: CGPoint(x: c.x - r * 0.55, y: c.y + r * 0.6))
        body.addLine(to: CGPoint(x: c.x + r * 0.55, y: c.y + r * 0.6))
        body.addLine(to: CGPoint(x: c.x + r * 0.42, y: c.y + r * 2.3))
        body.addLine(to: CGPoint(x: c.x - r * 0.42, y: c.y + r * 2.3))
        body.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 2, height: -4), blur: 6, color: NSColor.black.withAlphaComponent(0.8).cgColor)
        ctx.addPath(body); ctx.setFillColor(RigPaint.hex(0x303235).cgColor); ctx.fillPath()
        ctx.restoreGState()
        let bodyColors = [RigPaint.hex(0x1a1b1d), RigPaint.hex(0x6a6e73), RigPaint.hex(0x26282b)]
        ctx.saveGState(); ctx.addPath(body); ctx.clip()
        ctx.drawLinearGradient(RigPaint.gradient(bodyColors), start: CGPoint(x: c.x - r, y: c.y), end: CGPoint(x: c.x + r, y: c.y), options: [])
        ctx.restoreGState()
        let head = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 2, height: -4), blur: 6, color: NSColor.black.withAlphaComponent(0.8).cgColor)
        ctx.setFillColor(RigPaint.hex(0x8b8f94).cgColor); ctx.fillEllipse(in: head)
        ctx.restoreGState()
        ctx.saveGState(); ctx.addEllipse(in: head); ctx.clip()
        RigPaint.radial(ctx, c, r, [RigPaint.hex(0xe9ebed), RigPaint.hex(0x8e9298), RigPaint.hex(0x3d4044)], focus: CGPoint(x: c.x - r * 0.4, y: c.y - r * 0.4))
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(0.7)
        var x = head.minX
        while x < head.maxX { ctx.move(to: CGPoint(x: x, y: head.minY)); ctx.addLine(to: CGPoint(x: x, y: head.maxY)); x += 2.2 }
        var y = head.minY
        while y < head.maxY { ctx.move(to: CGPoint(x: head.minX, y: y)); ctx.addLine(to: CGPoint(x: head.maxX, y: y)); y += 2.2 }
        ctx.strokePath()
        ctx.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), m = mic
        guard hypot(p.x - m.center.x, p.y - m.center.y) < m.radius * 2.4 else { return super.mouseDown(with: event) }
        micDrag = (p, knobValue(1), knobValue(2))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let d = micDrag, let (_, r) = speakers.first else { return }
        let p = convert(event.locationInWindow, from: nil)
        knobMoved(knobId(1), max(0, min(1, d.mic + Double((p.x - d.start.x) / (r * 0.95)))))
        knobMoved(knobId(2), max(0, min(1, d.distance + Double((p.y - d.start.y) / 60))))
        refresh()
    }
    override func mouseUp(with event: NSEvent) { micDrag = nil }
    override func resetCursorRects() {
        let m = mic
        addCursorRect(CGRect(x: m.center.x - m.radius * 2, y: m.center.y - m.radius * 2, width: m.radius * 4, height: m.radius * 4), cursor: .openHand)
    }
    override var inJack: CGPoint { CGPoint(x: 4, y: bounds.height - 46) }
    override var outJack: CGPoint { CGPoint(x: bounds.width - 4, y: bounds.height - 46) }
}

// MARK: - Rack unit (EQ, delay, reverb)

final class RackUnit: RigUnit {
    private var lastTouched = 0
    private let bypass = RackButton()
    private var hasDisplay: Bool { name != "EQ" }
    private var face: CGRect { CGRect(x: 24, y: 40, width: bounds.width - 48, height: 118) }
    override func build() {
        let ks = makeKnobs(diameter: 30, scale: .dots, label: look.ink, size: 8)
        let start = face.minX + (hasDisplay ? 186 : 56)
        let end = face.maxX - 56
        row(ks, y: face.minY + (hasDisplay ? 52 : 58), from: start, to: end)
        bypass.frame = CGRect(x: face.maxX - 50, y: face.minY + 38, width: 30, height: 30)
        bypass.led = look.led
        bypass.onPress = { [weak self] in self.map { $0.rig.toggle($0.index) } }
        bypass.setAccessibilityLabel("\(name) on/off")
        addSubview(bypass)
    }
    override func refresh() { super.refresh(); bypass.isOn = isOn }
    override func knobMoved(_ id: UInt32, _ value: Double) {
        lastTouched = Int(id - StudioLayout.knobId(slot, 0))
        super.knobMoved(id, value)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let caseRect = bounds.insetBy(dx: 4, dy: 4)
        RigPaint.floorShadow(ctx, caseRect)
        // A road case: tolex, aluminium edging, corners; the rails inside.
        let c = RigPaint.rounded(caseRect, 6)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(c); ctx.setFillColor(RigPaint.hex(0x202022).cgColor); ctx.fillPath()
        ctx.restoreGState()
        RigPaint.tolex(ctx, c, RigPaint.hex(0x202022))
        let inside = RigPaint.rounded(caseRect.insetBy(dx: 14, dy: 22), 2)
        ctx.saveGState(); ctx.addPath(inside); ctx.setFillColor(RigPaint.hex(0x050505).cgColor); ctx.fillPath(); ctx.restoreGState()
        for x in [caseRect.minX + 14, caseRect.maxX - 26] {
            let rail = RigPaint.rounded(CGRect(x: x, y: caseRect.minY + 22, width: 12, height: caseRect.height - 44), 1)
            RigPaint.brushed(ctx, rail, RigPaint.hex(0x9a9ea3), streak: 0.3)
            var y = caseRect.minY + 28
            while y < caseRect.maxY - 26 { ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: x + 4, y: y, width: 4, height: 4)); y += 10 }
        }
        for (x, y) in [(caseRect.minX, caseRect.minY), (caseRect.maxX - 22, caseRect.minY), (caseRect.minX, caseRect.maxY - 22), (caseRect.maxX - 22, caseRect.maxY - 22)] {
            let corner = RigPaint.rounded(CGRect(x: x, y: y, width: 22, height: 22), 5)
            RigPaint.vertical(ctx, corner, [RigPaint.hex(0xe9ebed), RigPaint.hex(0x80858a), RigPaint.hex(0x44474b)])
            RigPaint.screw(ctx, CGPoint(x: x + 11, y: y + 11), 2.6)
        }
        // The unit's face, with ears.
        let ears = RigPaint.rounded(face.insetBy(dx: -14, dy: 0), 3)
        RigPaint.brushed(ctx, ears, look.panel, streak: 0.35)
        let facePath = RigPaint.rounded(face, 2)
        RigPaint.brushed(ctx, facePath, look.panel, streak: 0.35)
        RigPaint.bevel(ctx, facePath, width: 1.2)
        for x in [face.minX - 7, face.maxX + 7] {
            for y in [face.minY + 18, face.maxY - 18] {
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.addPath(RigPaint.rounded(CGRect(x: x - 4, y: y - 2.5, width: 8, height: 5), 2.5)); ctx.fillPath()
                RigPaint.screw(ctx, CGPoint(x: x, y: y), 3.2)
            }
        }
        RigPaint.text(look.brand, CGRect(x: face.minX + 14, y: face.minY + 6, width: 260, height: 18), font: fitted(look.brand, 220, max: 15),
                      color: look.ink, align: .left, kern: 2.5)
        RigPaint.text(look.kind, CGRect(x: face.minX + 14, y: face.maxY - 17, width: 260, height: 10), font: RigPaint.font(["Futura-Medium"], 7.5),
                      color: look.ink.withAlphaComponent(0.75), align: .left, kern: 2)
        RigPaint.text("DALNOK", CGRect(x: face.maxX - 120, y: face.maxY - 17, width: 106, height: 10), font: RigPaint.font(["Futura-Bold"], 7.5),
                      color: look.ink.withAlphaComponent(0.6), align: .right, kern: 2.5)
        if hasDisplay { drawDisplay(ctx) } else { drawCurveWindow(ctx) }
    }
    /// Delay: red seven-segment-style readout of the delay time; reverb: a blue two-line screen (decay, last control).
    private func drawDisplay(_ ctx: CGContext) {
        let r = CGRect(x: face.minX + 16, y: face.minY + 30, width: 150, height: 48)
        let p = RigPaint.rounded(r, 3)
        let red = name == "Delay"
        ctx.saveGState(); ctx.addPath(p); ctx.setFillColor((red ? RigPaint.hex(0x140303) : RigPaint.hex(0x06142a)).cgColor); ctx.fillPath(); ctx.restoreGState()
        RigPaint.innerEdge(ctx, p, dark: 0.9, blur: 5)
        let knobs = rig.knobs(slot: slot)
        guard !knobs.isEmpty else { return }
        let lit = isOn ? 1.0 : 0.25
        if red {
            let color = RigPaint.hex(0xff3b24, lit)
            RigPaint.text(knobs[0].display, r.insetBy(dx: 6, dy: 4).offsetBy(dx: 0, dy: -4), font: RigPaint.font(["Menlo-Bold"], 20), color: color,
                          align: .right, glow: isOn ? RigPaint.hex(0xff2a1a, 0.8) : nil)
            RigPaint.text("TIME", CGRect(x: r.minX + 6, y: r.maxY - 12, width: 60, height: 9), font: RigPaint.font(["Menlo-Bold"], 7), color: color, align: .left)
        } else {
            let k = knobs[min(lastTouched, knobs.count - 1)]
            let color = RigPaint.hex(0x9fd2ff, lit)
            let font = RigPaint.font(["Menlo-Bold"], 10.5)
            RigPaint.text("HALL  \(knobs[0].display)", CGRect(x: r.minX + 8, y: r.minY + 6, width: r.width - 16, height: 14), font: font, color: color, align: .left,
                          glow: isOn ? RigPaint.hex(0x4aa3ff, 0.6) : nil)
            RigPaint.text("\(k.name.uppercased()) \(k.display)", CGRect(x: r.minX + 8, y: r.minY + 26, width: r.width - 16, height: 14), font: font, color: color,
                          align: .left, glow: isOn ? RigPaint.hex(0x4aa3ff, 0.6) : nil)
        }
        ctx.saveGState(); ctx.addPath(p); ctx.clip() // the glass
        RigPaint.vertical(ctx, p, [NSColor.white.withAlphaComponent(0.12), .clear], [0, 0.45])
        ctx.restoreGState()
    }
    /// EQ: the channel's band layout printed above its knobs.
    private func drawCurveWindow(_ ctx: CGContext) {
        let y = face.minY + 26, step = (face.maxX - 56 - (face.minX + 56)) / 6
        ctx.setStrokeColor(look.ink.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(1)
        for (from, to, label) in [(0, 1, "FILTER"), (1, 5, "EQUALIZER"), (5, 6, "FILTER")] {
            let x0 = face.minX + 56 + step * CGFloat(from) + 8, x1 = face.minX + 56 + step * CGFloat(to) - 8
            let w = (label as NSString).size(withAttributes: [.font: RigPaint.font(["Futura-Bold"], 7)]).width + 12
            ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: (x0 + x1 - w) / 2, y: y))
            ctx.move(to: CGPoint(x: (x0 + x1 + w) / 2, y: y)); ctx.addLine(to: CGPoint(x: x1, y: y))
            RigPaint.text(label, CGRect(x: (x0 + x1 - w) / 2, y: y - 5, width: w, height: 10), font: RigPaint.font(["Futura-Bold"], 7),
                          color: look.ink.withAlphaComponent(0.7), kern: 1.5)
        }
        ctx.strokePath()
    }
    override var inJack: CGPoint { CGPoint(x: 4, y: bounds.height * 0.5) }
    override var outJack: CGPoint { CGPoint(x: bounds.width - 4, y: bounds.height * 0.5) }
}

/// A square rack push-button with its LED.
final class RackButton: NSView {
    var isOn = true { didSet { if isOn != oldValue { needsDisplay = true } } }
    var led = NSColor.red
    var onPress: (() -> Void)?
    private var down = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        toolTip = "Switch this unit on or off"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 3, dy: 3).offsetBy(dx: 0, dy: down ? 1 : 0)
        let p = RigPaint.rounded(r, 3)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: down ? -0.5 : -2), blur: 3, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(p); ctx.setFillColor(RigPaint.hex(0x2b2c2e).cgColor); ctx.fillPath()
        ctx.restoreGState()
        RigPaint.vertical(ctx, p, [RigPaint.hex(0x4a4c50), RigPaint.hex(0x1d1e20)])
        RigPaint.led(ctx, CGPoint(x: r.midX, y: r.midY), 3.2, led, lit: isOn)
    }
    override func mouseDown(with event: NSEvent) { down = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        down = false; needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

// MARK: - Spring tank

final class SpringUnit: RigUnit {
    private let toggle = RigToggle()
    override func build() {
        let ks = makeKnobs(diameter: 30, scale: .numbers, label: look.ink, size: 8)
        row(ks, y: 182, from: 30, to: bounds.width - 110)
        toggle.frame = CGRect(x: bounds.width - 96, y: 160, width: 26, height: 44)
        toggle.ink = look.ink
        toggle.onPress = { [weak self] in self.map { $0.rig.toggle($0.index) } }
        toggle.setAccessibilityLabel("\(name) on/off")
        addSubview(toggle)
    }
    override func refresh() { super.refresh(); toggle.isOn = isOn }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = bounds.insetBy(dx: 4, dy: 4)
        RigPaint.floorShadow(ctx, box)
        let body = RigPaint.rounded(box, 12)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(body); ctx.setFillColor(look.body.cgColor); ctx.fillPath()
        ctx.restoreGState()
        RigPaint.tolex(ctx, body, look.body)
        // A window onto the tank: three springs between their transducers, over grille cloth.
        let win = CGRect(x: box.minX + 16, y: box.minY + 14, width: box.width - 32, height: 116)
        let wp = RigPaint.rounded(win, 6)
        RigPaint.grille(ctx, wp, base: look.cloth ?? .darkGray, thread: look.thread, pitch: 2.6)
        let tank = CGRect(x: win.minX + 30, y: win.minY + 22, width: win.width - 60, height: win.height - 44)
        let tp = RigPaint.rounded(tank, 4)
        ctx.saveGState(); ctx.addPath(tp); ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor); ctx.fillPath(); ctx.restoreGState()
        RigPaint.innerEdge(ctx, tp, dark: 0.9, blur: 6)
        for x in [tank.minX + 6, tank.maxX - 30] {
            RigPaint.brushed(ctx, RigPaint.rounded(CGRect(x: x, y: tank.minY + 8, width: 24, height: tank.height - 16), 2), RigPaint.hex(0x8d9196), streak: 0.4)
        }
        for k in 0..<3 {
            let y = tank.minY + 18 + CGFloat(k) * (tank.height - 36) / 2
            let coil = CGMutablePath()
            var x = tank.minX + 30
            coil.move(to: CGPoint(x: x, y: y))
            while x < tank.maxX - 30 { coil.addLine(to: CGPoint(x: x + 1.5, y: y - 3.5)); coil.addLine(to: CGPoint(x: x + 3, y: y + 3.5)); x += 3 }
            ctx.setStrokeColor(RigPaint.hex(0xc7cbd0).cgColor); ctx.setLineWidth(0.9)
            ctx.addPath(coil); ctx.strokePath()
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1, height: -2), blur: 3, color: NSColor.black.withAlphaComponent(0.8).cgColor)
        RigPaint.text(look.brand, CGRect(x: win.minX, y: win.minY - 4, width: win.width, height: 40), font: brandFont(30), color: RigPaint.hex(0xf6ecd4))
        ctx.restoreGState()
        // The panel.
        let panelRect = CGRect(x: box.minX + 16, y: win.maxY + 10, width: box.width - 32, height: box.maxY - win.maxY - 26)
        let panel = RigPaint.rounded(panelRect, 4)
        RigPaint.brushed(ctx, panel, look.panel, streak: 0.25)
        RigPaint.innerEdge(ctx, panel, dark: 0.5, blur: 3)
        RigPaint.jewel(ctx, CGPoint(x: panelRect.maxX - 26, y: panelRect.midY - 4), 7.5, look.led, lit: isOn)
        RigPaint.text(look.kind, CGRect(x: panelRect.maxX - 52, y: panelRect.maxY - 14, width: 50, height: 10), font: RigPaint.font(["Futura-Bold"], 7),
                      color: look.ink, kern: 2)
    }
    override var inJack: CGPoint { CGPoint(x: 4, y: 182) }
    override var outJack: CGPoint { CGPoint(x: bounds.width - 4, y: 182) }
}

@MainActor
enum RigUnits {
    static func make(rig: StudioRig, slot: Int, index: Int) -> RigUnit {
        switch RigLook.of(StudioLayout.type(rig.value(StudioLayout.typeId(slot)))).form {
        case .stomp: StompUnit(rig: rig, slot: slot, index: index)
        case .wah: WahUnit(rig: rig, slot: slot, index: index)
        case .amp: AmpUnit(rig: rig, slot: slot, index: index)
        case .cabinet: CabinetUnit(rig: rig, slot: slot, index: index)
        case .rack: RackUnit(rig: rig, slot: slot, index: index)
        case .spring: SpringUnit(rig: rig, slot: slot, index: index)
        }
    }
}
