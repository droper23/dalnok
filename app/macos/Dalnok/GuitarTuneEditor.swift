// Guitar Tune's own editor: one white module on the quiet field. The main screen shows the note played, the note it's
// tuned toward and how far off it is (±50 cents, with the bend-tolerance band); the round screens are its controls.
// Everything shown is the engine's measured pitch; with no note the screen rests.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class GuitarTuneEditor: NSView {
    static let preferredSize = CGSize(width: 860, height: 520)
    static let module = CGSize(width: 640, height: 360)
    let engine: Engine
    let slot: Int32
    private(set) var reading = GuitarTuneDisplay.Reading()
    private(set) var dials: [(id: UInt32, view: SpaceDial)] = []
    private var timer: Timer?
    private var scale: CGFloat = 1
    private var origin = CGPoint.zero
    private var screen: CGRect { CGRect(x: 22, y: 58, width: Self.module.width - 44, height: 176) }

    init(engine: Engine, slot: Int32) {
        self.engine = engine
        self.slot = slot
        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize))
        identifier = NSUserInterfaceItemIdentifier("guitar-tune-editor")
        appearance = NSAppearance(named: .aqua)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Guitar Tune")
        let names: [UInt32: String] = [0: "Amount", 1: "Retune", 2: "Bend", 3: "Reference", 4: "Root", 5: "Scale", 6: "Mix"]
        let pictures: [UInt32: DialPicture] = [0: .arc, 1: .rings, 2: .arc, 3: .spectrum, 6: .blend]
        for id in [UInt32(0), 1, 2, 6, 3, 4, 5] {
            guard let p = parameter(id) else { continue }
            let steps = Int(p.step_count)
            let d = SpaceDial(name: names[id] ?? fixedString(p.title), picture: steps > 0 ? .steps(steps + 1) : pictures[id] ?? .arc)
            d.steps = steps
            d.defaultValue = p.default_value
            d.value = p.value
            d.accent = id == 2 ? Space.blue : Space.orange
            d.identifier = NSUserInterfaceItemIdentifier("tune-dial-\(id)")
            d.setAccessibilityLabel("Guitar Tune \(fixedString(p.title))")
            d.toolTip = "\(fixedString(p.title)): drag up or down (⇧ for fine), double-click for the default"
            d.valueText = { [weak self] in self?.parameter(id).map { fixedString($0.display) } ?? "" }
            d.onChange = { [weak self] v in
                guard let self else { return }
                dalnok_plugin_set_parameter(self.engine.handle, self.slot, id, v)
                self.needsDisplay = true
            }
            addSubview(d)
            dials.append((id, d))
        }
        tick()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { timer = nil; return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }
    /// The module at its design size, scaled to fit and centred; the dials across its foot.
    override func layout() {
        super.layout()
        scale = min(1.25, min((bounds.width - 60) / Self.module.width, (bounds.height - 60) / Self.module.height))
        origin = CGPoint(x: (bounds.width - Self.module.width * scale) / 2, y: (bounds.height - Self.module.height * scale) / 2)
        let size = SpaceDial.size, step = (Self.module.width - 32) / CGFloat(max(1, dials.count))
        for (i, (_, d)) in dials.enumerated() {
            let x = 16 + step * (CGFloat(i) + 0.5) - size.width / 2, y: CGFloat = 254
            d.frame = CGRect(x: origin.x + x * scale, y: origin.y + y * scale, width: size.width * scale, height: size.height * scale)
            d.bounds = CGRect(origin: .zero, size: size)
        }
    }

    private func parameter(_ id: UInt32) -> DalnokPluginParameter? {
        var p = DalnokPluginParameter()
        return dalnok_plugin_parameter(engine.handle, slot, Int32(id), &p) == DALNOK_OK ? p : nil
    }
    private func value(_ id: UInt32, _ fallback: Double) -> Double { parameter(id)?.value ?? fallback }
    /// Shows a reading without input (self-test snapshots; the next tick returns to the engine's telemetry).
    func preview(_ r: GuitarTuneDisplay.Reading) {
        reading = r
        for (_, d) in dials { d.light = r.tracking ? 0.6 : 0 }
        needsDisplay = true
    }
    func tick() {
        let next = GuitarTuneDisplay.Reading(hz: value(7, 0) * 1500, cents: value(8, 0.5) * 200 - 100, confidence: value(9, 0) * 100,
                                             reference: 430 + value(3, 0.5) * 20, tolerance: value(2, 0) * 200, bypassed: false)
        let moved = next.hz != reading.hz || next.cents != reading.cents || next.confidence != reading.confidence || next.tolerance != reading.tolerance
        reading = next
        let lit: CGFloat = reading.tracking ? CGFloat(reading.confidence / 100) * 0.7 : 0
        for (id, d) in dials {
            if !d.dragging { d.value = value(id, d.value) }
            d.light = lit
        }
        if moved { needsDisplay = true; setAccessibilityValue("\(reading.note) to \(reading.target), \(reading.status)") }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Space.field(ctx, bounds)
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale, y: scale)
        drawModule(ctx)
        ctx.restoreGState()
    }

    private func drawModule(_ ctx: CGContext) {
        let body = Space.rounded(CGRect(origin: .zero, size: Self.module), 26)
        Space.plastic(ctx, body)
        Space.text("GUITAR TUNE", CGRect(x: 26, y: 20, width: 260, height: 22), font: Space.font(15, .regular), color: Space.ink, align: .left, kern: 4)
        let tracking = reading.tracking
        Space.lamp(ctx, CGPoint(x: Self.module.width - 34, y: 31), Space.orange, lit: tracking)
        Space.text(tracking ? "TRACKING" : "LISTENING", CGRect(x: Self.module.width - 160, y: 22, width: 114, height: 18), font: Space.font(9, .bold),
                   color: Space.inkDim, align: .right, kern: 1.5)
        Space.plinth(ctx, Space.rounded(screen.insetBy(dx: -8, dy: -8), 18))
        let glass = Space.rounded(screen, 12)
        Space.glass(ctx, glass, glow: reading.inTune ? Space.blue : Space.orange, glowLevel: tracking ? 0.7 : 0)
        ctx.saveGState(); ctx.addPath(glass); ctx.clip()
        drawScreen(ctx, screen.insetBy(dx: 8, dy: 8))
        ctx.restoreGState()
        ctx.setFillColor(Space.hex(0x9a9ca3, 0.25).cgColor); ctx.fill(CGRect(x: 32, y: 246, width: Self.module.width - 64, height: 1))
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 32, y: 247, width: Self.module.width - 64, height: 1))
    }

    /// Left: the note played and its target. Right: an arc of ±50 cents with the bend band and the measured error.
    private func drawScreen(_ ctx: CGContext, _ r: CGRect) {
        let tracking = reading.tracking
        let left = CGRect(x: r.minX, y: r.minY, width: r.width * 0.38, height: r.height)
        Space.text(reading.note, left.offsetBy(dx: 0, dy: -14), font: Space.mono(46), color: tracking ? .white : Space.hex(0xffffff, 0.25),
                   glow: tracking ? Space.orange : nil)
        Space.text(tracking ? "→ \(reading.target)" : "PLAY A NOTE", CGRect(x: left.minX, y: left.maxY - 46, width: left.width, height: 18),
                   font: Space.mono(13), color: tracking ? Space.amber : Space.hex(0xffffff, 0.35))
        Space.text(tracking ? String(format: "%.1f Hz", reading.hz) : "", CGRect(x: left.minX, y: left.maxY - 26, width: left.width, height: 14),
                   font: Space.mono(9.5), color: Space.hex(0xffffff, 0.45))
        // The cents arc.
        let c = CGPoint(x: r.minX + r.width * 0.69, y: r.maxY - 26), radius = min(r.height - 40, r.width * 0.3)
        let span = CGFloat.pi * 0.36
        func angle(_ cents: Double) -> CGFloat { -.pi / 2 + CGFloat(max(-50, min(50, cents)) / 50) * span }
        let track = CGMutablePath(); track.addArc(center: c, radius: radius, startAngle: angle(-50), endAngle: angle(50), clockwise: false)
        ctx.addPath(track); ctx.setStrokeColor(Space.hex(0xffffff, 0.08).cgColor); ctx.setLineWidth(3); ctx.strokePath()
        if reading.tolerance > 0 {
            let band = CGMutablePath(); band.addArc(center: c, radius: radius, startAngle: angle(-reading.tolerance), endAngle: angle(reading.tolerance), clockwise: false)
            Space.glowStroke(ctx, band, Space.blue.withAlphaComponent(0.55), width: 3, bloom: 0.4)
        }
        ctx.setStrokeColor(Space.hex(0xffffff, 0.3).cgColor); ctx.setLineWidth(1)
        for cents in stride(from: -50, through: 50, by: 10) {
            let a = angle(Double(cents)), inner = radius - (cents == 0 ? 14 : 7)
            ctx.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner)); ctx.addLine(to: CGPoint(x: c.x + cos(a) * (radius - 3), y: c.y + sin(a) * (radius - 3)))
        }
        ctx.strokePath()
        for (cents, label) in [(-50.0, "−50"), (0, "0"), (50, "+50")] {
            let a = angle(cents), p = CGPoint(x: c.x + cos(a) * (radius + 14), y: c.y + sin(a) * (radius + 14))
            Space.text(label, CGRect(x: p.x - 18, y: p.y - 7, width: 36, height: 14), font: Space.mono(8.5), color: Space.hex(0xffffff, 0.45))
        }
        if tracking {
            let a = angle(reading.cents), color = reading.inTune ? Space.ice : reading.bending ? Space.blue : Space.orange
            let needle = CGMutablePath()
            needle.move(to: CGPoint(x: c.x + cos(a) * radius * 0.25, y: c.y + sin(a) * radius * 0.25))
            needle.addLine(to: CGPoint(x: c.x + cos(a) * (radius + 4), y: c.y + sin(a) * (radius + 4)))
            Space.glowStroke(ctx, needle, color, width: 1.8)
            Space.glowDot(ctx, CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius), 3.6, color)
        }
        Space.text(reading.status, CGRect(x: c.x - 120, y: c.y - 8, width: 240, height: 16), font: Space.font(10, .semibold),
                   color: reading.inTune ? Space.ice : Space.hex(0xffffff, tracking ? 0.85 : 0.4), kern: 1.2)
    }
}
