// Guitar Tune's own editor: a rack unit with the played and target notes on an amber readout, an analog cents meter
// with the bend-tolerance band, lamps for in tune and left-alone bends, and the correction controls.
// Everything shown is the engine's measured pitch telemetry; nothing is animated without a signal.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class GuitarTuneEditor: NSView {
    static let preferredSize = CGSize(width: 900, height: 330)
    static let design = CGSize(width: 900, height: 330)
    let engine: Engine
    let slot: Int32
    private(set) var reading = GuitarTuneDisplay.Reading()
    private var knobs: [(id: UInt32, view: RigKnob)] = []
    private var timer: Timer?
    private var face: CGRect { CGRect(x: 40, y: 50, width: Self.design.width - 80, height: 230) }
    private var readout: CGRect { CGRect(x: face.minX + 24, y: face.minY + 46, width: 170, height: 120) }
    private var meter: CGRect { CGRect(x: face.minX + 216, y: face.minY + 22, width: 270, height: 170) }

    init(engine: Engine, slot: Int32) {
        self.engine = engine
        self.slot = slot
        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize))
        identifier = NSUserInterfaceItemIdentifier("guitar-tune-editor")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Guitar Tune")
        let names: [UInt32: String] = [0: "Amount", 1: "Retune", 2: "Bend", 3: "Reference", 4: "Root", 5: "Scale", 6: "Mix"]
        for (id, at) in Self.layout.sorted(by: { $0.key < $1.key }) {
            var p = DalnokPluginParameter()
            guard dalnok_plugin_parameter(engine.handle, slot, Int32(id), &p) == DALNOK_OK else { continue }
            let k = RigKnob(diameter: id <= 2 || id == 6 ? 36 : 28, style: .skirted(cap: RigPaint.hex(0xd9dde1), skirt: RigPaint.hex(0x141416)),
                            name: names[id] ?? fixedString(p.title), scale: .dots)
            k.labelColor = RigPaint.hex(0xdfe3e8)
            k.labelFont = RigPaint.font(["Futura-Bold"], 8.5)
            k.defaultValue = p.default_value
            k.steps = Int(p.step_count)
            k.value = p.value
            k.identifier = NSUserInterfaceItemIdentifier("tune-knob-\(id)")
            k.setAccessibilityLabel("Guitar Tune \(fixedString(p.title))")
            k.toolTip = "\(fixedString(p.title)): drag up or down (⇧ for fine), double-click for the default"
            k.valueText = { [weak self] in self?.parameter(id).map { fixedString($0.display) } ?? "" }
            k.onChange = { [weak self] v in
                guard let self else { return }
                dalnok_plugin_set_parameter(self.engine.handle, self.slot, id, v)
                self.needsDisplay = true
            }
            k.place(at)
            addSubview(k)
            knobs.append((id, k))
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
    /// Draws at the design size, scaled to fit and centred.
    override func layout() {
        super.layout()
        let s = min(bounds.width / Self.design.width, bounds.height / Self.design.height)
        let ox = (bounds.width - Self.design.width * s) / 2, oy = (bounds.height - Self.design.height * s) / 2
        contentScale = s
        contentOrigin = CGPoint(x: ox, y: oy)
        for (id, k) in knobs {
            guard let at = Self.layout[id] else { continue }
            let size = RigKnob.size(k.diameter, scale: k.scale)
            k.frame = CGRect(x: ox + (at.x - size.width / 2) * s, y: oy + (at.y - (size.height - 15) / 2) * s, width: size.width * s, height: size.height * s)
            k.bounds = CGRect(origin: .zero, size: size)
        }
    }
    /// Knob centres on the design: correction above, tuning below.
    static let layout: [UInt32: CGPoint] = [0: CGPoint(x: 560, y: 108), 1: CGPoint(x: 640, y: 108), 2: CGPoint(x: 720, y: 108), 6: CGPoint(x: 800, y: 108),
                                            3: CGPoint(x: 600, y: 202), 4: CGPoint(x: 680, y: 202), 5: CGPoint(x: 760, y: 202)]
    private var contentScale: CGFloat = 1
    private var contentOrigin = CGPoint.zero

    private func parameter(_ id: UInt32) -> DalnokPluginParameter? {
        var p = DalnokPluginParameter()
        return dalnok_plugin_parameter(engine.handle, slot, Int32(id), &p) == DALNOK_OK ? p : nil
    }
    private func value(_ id: UInt32, _ fallback: Double) -> Double { parameter(id)?.value ?? fallback }
    /// Shows a reading without input (self-test snapshots; the next tick returns to the engine's telemetry).
    func preview(_ r: GuitarTuneDisplay.Reading) { reading = r; needsDisplay = true }
    func tick() {
        let next = GuitarTuneDisplay.Reading(hz: value(7, 0) * 1500, cents: value(8, 0.5) * 200 - 100, confidence: value(9, 0) * 100,
                                             reference: 430 + value(3, 0.5) * 20, tolerance: value(2, 0) * 200, bypassed: false)
        let moved = next.hz != reading.hz || next.cents != reading.cents || next.confidence != reading.confidence || next.tolerance != reading.tolerance
        reading = next
        for (id, k) in knobs where !k.dragging { k.value = value(id, k.value) }
        if moved { needsDisplay = true; setAccessibilityValue("\(reading.note) to \(reading.target), \(reading.status)") }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(RigPaint.hex(0x0c0c0d).cgColor); ctx.fill(bounds)
        ctx.saveGState()
        ctx.translateBy(x: contentOrigin.x, y: contentOrigin.y)
        ctx.scaleBy(x: contentScale, y: contentScale)
        drawRack(ctx)
        ctx.restoreGState()
    }

    private func drawRack(_ ctx: CGContext) {
        let full = CGRect(origin: .zero, size: Self.design)
        ctx.setFillColor(RigPaint.hex(0x111214).cgColor); ctx.fill(full)
        RigPaint.grain(ctx, full, alpha: 0.4, scale: CGSize(width: 0.7, height: 0.7), blend: .softLight)
        RigPaint.radial(ctx, CGPoint(x: full.midX, y: 40), 520, [RigPaint.hex(0xffe2b8, 0.12), .clear])
        // Rails, ears and the faceplate.
        for x in [face.minX - 30, face.maxX + 18] {
            RigPaint.brushed(ctx, RigPaint.rounded(CGRect(x: x, y: 20, width: 12, height: full.height - 40), 1), RigPaint.hex(0x8e9297), streak: 0.3)
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.8).cgColor)
        ctx.addPath(RigPaint.rounded(face.insetBy(dx: -22, dy: 0), 3)); ctx.setFillColor(RigPaint.hex(0x222327).cgColor); ctx.fillPath()
        ctx.restoreGState()
        let ears = RigPaint.rounded(face.insetBy(dx: -22, dy: 0), 3)
        RigPaint.brushed(ctx, ears, RigPaint.hex(0x26282c), streak: 0.3)
        let fp = RigPaint.rounded(face, 2)
        RigPaint.brushed(ctx, fp, RigPaint.hex(0x26282c), streak: 0.3)
        RigPaint.bevel(ctx, fp, width: 1.2)
        for x in [face.minX - 11, face.maxX + 11] {
            for y in [face.minY + 22, face.maxY - 22] { RigPaint.screw(ctx, CGPoint(x: x, y: y), 3.6) }
        }
        RigPaint.text("TRUE NOTE", CGRect(x: face.minX + 24, y: face.minY + 12, width: 200, height: 22), font: RigPaint.font(["Futura-CondensedExtraBold", "Futura-Bold"], 18),
                      color: RigPaint.hex(0xf0f2f5), align: .left, kern: 3)
        RigPaint.text("GUITAR PITCH CORRECTOR", CGRect(x: face.minX + 24, y: face.maxY - 24, width: 220, height: 10), font: RigPaint.font(["Futura-Medium"], 7.5),
                      color: RigPaint.hex(0xb7bcc2), align: .left, kern: 2)
        RigPaint.text("DALNOK", CGRect(x: face.maxX - 140, y: face.maxY - 24, width: 120, height: 10), font: RigPaint.font(["Futura-Bold"], 8),
                      color: RigPaint.hex(0x9aa0a6), align: .right, kern: 3)
        RigPaint.text("CORRECTION", CGRect(x: 520, y: face.minY + 14, width: 320, height: 10), font: RigPaint.font(["Futura-Bold"], 7.5),
                      color: RigPaint.hex(0x9aa0a6), kern: 2.5)
        RigPaint.text("TUNING", CGRect(x: 560, y: face.minY + 116, width: 240, height: 10), font: RigPaint.font(["Futura-Bold"], 7.5),
                      color: RigPaint.hex(0x9aa0a6), kern: 2.5)
        drawReadout(ctx)
        drawMeter(ctx)
    }

    /// The played note, big, and the note it's tuned toward.
    private func drawReadout(_ ctx: CGContext) {
        let p = RigPaint.rounded(readout, 4)
        ctx.saveGState(); ctx.addPath(p); ctx.setFillColor(RigPaint.hex(0x120a02).cgColor); ctx.fillPath(); ctx.restoreGState()
        RigPaint.innerEdge(ctx, p, dark: 0.95, blur: 6)
        let amber = RigPaint.hex(0xffa526)
        let tracking = reading.tracking
        RigPaint.text(reading.note, readout.insetBy(dx: 8, dy: 22).offsetBy(dx: 0, dy: -12), font: RigPaint.font(["Menlo-Bold"], 44), color: amber,
                      glow: tracking ? RigPaint.hex(0xff8a00, 0.9) : nil)
        RigPaint.text(tracking ? "→ \(reading.target)" : "PLAY A NOTE", CGRect(x: readout.minX, y: readout.maxY - 34, width: readout.width, height: 16),
                      font: RigPaint.font(["Menlo-Bold"], 13), color: amber.withAlphaComponent(tracking ? 1 : 0.55))
        RigPaint.text(tracking ? String(format: "%.1f Hz", reading.hz) : "", CGRect(x: readout.minX, y: readout.maxY - 16, width: readout.width, height: 12),
                      font: RigPaint.font(["Menlo-Regular"], 9), color: amber.withAlphaComponent(0.7))
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        RigPaint.vertical(ctx, p, [NSColor.white.withAlphaComponent(0.1), .clear], [0, 0.4])
        ctx.restoreGState()
    }

    /// An analog meter, ±50 cents, with the bend tolerance shaded; lamps for in tune and for bends left alone.
    private func drawMeter(_ ctx: CGContext) {
        let p = RigPaint.rounded(meter, 6)
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        ctx.drawLinearGradient(RigPaint.gradient([RigPaint.hex(0xf6ecd0), RigPaint.hex(0xe6d6ad)]), start: CGPoint(x: 0, y: meter.minY),
                               end: CGPoint(x: 0, y: meter.maxY), options: [])
        RigPaint.grain(ctx, meter, alpha: 0.18, blend: .multiply)
        ctx.restoreGState()
        let pivot = CGPoint(x: meter.midX, y: meter.maxY - 18), radius: CGFloat = 128
        let span: CGFloat = 0.3 * .pi // each side of vertical
        func at(_ cents: Double, _ r: CGFloat) -> CGPoint {
            let a = CGFloat(max(-50, min(50, cents)) / 50) * span
            return CGPoint(x: pivot.x + sin(a) * r, y: pivot.y - cos(a) * r)
        }
        // The tolerance band: notes within it are corrected; beyond it, left alone.
        let tol = reading.tolerance
        if tol > 0 {
            let band = CGMutablePath()
            let a0 = CGFloat(-min(tol, 50) / 50) * span - .pi / 2, a1 = CGFloat(min(tol, 50) / 50) * span - .pi / 2
            band.addArc(center: pivot, radius: radius - 2, startAngle: a0, endAngle: a1, clockwise: false)
            band.addArc(center: pivot, radius: radius - 16, startAngle: a1, endAngle: a0, clockwise: true)
            band.closeSubpath()
            ctx.addPath(band); ctx.setFillColor(RigPaint.hex(0x3f8f5a, 0.28).cgColor); ctx.fillPath()
        }
        ctx.setStrokeColor(RigPaint.hex(0x2a2218).cgColor)
        for c in stride(from: -50, through: 50, by: 5) {
            let major = c % 10 == 0
            ctx.setLineWidth(major ? 1.6 : 0.9)
            ctx.move(to: at(Double(c), radius - (major ? 14 : 8))); ctx.addLine(to: at(Double(c), radius)); ctx.strokePath()
            if major {
                let q = at(Double(c), radius + 11)
                RigPaint.text(c == 0 ? "0" : String(format: "%+d", c).replacingOccurrences(of: "-", with: "−"), CGRect(x: q.x - 14, y: q.y - 6, width: 28, height: 12),
                              font: RigPaint.font(["Futura-Medium"], 8.5), color: RigPaint.hex(0x2a2218))
            }
        }
        ctx.setStrokeColor(RigPaint.hex(0xb3261e).cgColor); ctx.setLineWidth(2.4)
        ctx.addArc(center: pivot, radius: radius, startAngle: -.pi / 2 - span * 0.06, endAngle: -.pi / 2 + span * 0.06, clockwise: false); ctx.strokePath()
        RigPaint.text("CENTS", CGRect(x: meter.minX + 18, y: meter.maxY - 26, width: 60, height: 10), font: RigPaint.font(["Futura-Bold"], 8),
                      color: RigPaint.hex(0x2a2218), align: .left, kern: 3)
        RigPaint.text(reading.status, CGRect(x: readout.minX - 10, y: readout.maxY + 8, width: readout.width + 20, height: 12),
                      font: RigPaint.font(["Futura-Medium"], 8.5), color: RigPaint.hex(0xdfe3e8, 0.85))
        // The needle rests at the left stop with no note; it shows only measured pitch.
        let needleCents = reading.tracking ? reading.cents : -56
        let a = CGFloat(max(-56, min(56, needleCents)) / 50) * span
        let tip = CGPoint(x: pivot.x + sin(a) * (radius + 2), y: pivot.y - cos(a) * (radius + 2))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 2, height: -3), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setStrokeColor(RigPaint.hex(0x161310).cgColor); ctx.setLineWidth(1.8); ctx.setLineCap(.round)
        ctx.move(to: pivot); ctx.addLine(to: tip); ctx.strokePath()
        ctx.restoreGState()
        let hub = CGRect(x: pivot.x - 9, y: pivot.y - 9, width: 18, height: 18)
        ctx.saveGState(); ctx.addEllipse(in: hub); ctx.clip()
        RigPaint.radial(ctx, pivot, 9, [RigPaint.hex(0x6b6f74), RigPaint.hex(0x151617)], focus: CGPoint(x: pivot.x - 3, y: pivot.y - 3))
        ctx.restoreGState()
        // The glass and bezel.
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        RigPaint.vertical(ctx, p, [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0.04), .clear], [0, 0.35, 0.36])
        ctx.restoreGState()
        RigPaint.innerEdge(ctx, p, dark: 0.7, blur: 7)
        ctx.addPath(p); ctx.setStrokeColor(RigPaint.hex(0x0b0b0c).cgColor); ctx.setLineWidth(3); ctx.strokePath()
        // Lamps under the meter.
        let lampY = meter.maxY + 18
        RigPaint.led(ctx, CGPoint(x: meter.minX + 60, y: lampY), 4.5, RigPaint.hex(0x37d16a), lit: reading.inTune)
        RigPaint.text("IN TUNE", CGRect(x: meter.minX + 70, y: lampY - 5, width: 70, height: 10), font: RigPaint.font(["Futura-Bold"], 8),
                      color: RigPaint.hex(0xdfe3e8), align: .left, kern: 1.5)
        RigPaint.led(ctx, CGPoint(x: meter.minX + 160, y: lampY), 4.5, RigPaint.hex(0xffb21a), lit: reading.bending)
        RigPaint.text("BEND", CGRect(x: meter.minX + 170, y: lampY - 5, width: 70, height: 10), font: RigPaint.font(["Futura-Bold"], 8),
                      color: RigPaint.hex(0xdfe3e8), align: .left, kern: 1.5)
    }
}
