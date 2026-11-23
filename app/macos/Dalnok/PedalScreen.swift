// Warm Analog: the readout window of a stomp box, so a pedal shows as much as a Graphite faceplate without losing its
// charm. Inspired by how modern pedals carry information (gain-reduction LED ladders on studio compressor pedals, small
// backlit dot-matrix and OLED screens over direct knobs on multi-effects units); the drawing is Dalnok's own.
// A recessed, backlit window in the pedal's LED colour with a faint dot-matrix grid shows:
//   - the control being turned, by name and value (for a few seconds after it moves);
//   - otherwise a live picture suited to the plug-in: a 12-segment gain-reduction ladder (dynamics), the frequency
//     response (EQs and filters) or the output trace (everything else), with a one-line reading;
//   - for the families with a figure (2026-11-23, the owner: bring Warm Analog to Atelier's level), a moving picture of
//     the circuit in the pedal's light, drawn from its parameters: a tape loop with its heads (delay), a spring tank's
//     coil swaying (reverb), a triode's glowing filament and the clipped wave it makes (distortion), a lamp pulsing at
//     the LFO's rate over its wave (modulation).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class PedalScreen: NSView, FigureAnimating {
    enum Mode: Equatable { case ladder, needle, curve, scope, tape, spring, tube, lamp }
    var mode: Mode = .scope { didSet { if mode != oldValue { needsDisplay = true } } }
    var glow: NSColor = .systemOrange { didSet { needsDisplay = true } }
    /// Dark when the pedal is bypassed or not loaded.
    var lit = true { didSet { if lit != oldValue { needsDisplay = true } } }
    /// Gain reduction in dB (ladder), shown 0…24 dB.
    var reduction: Double = 0 { didSet { if abs(reduction - oldValue) > 0.05 { needsDisplay = true } } }
    /// Response in dB at log-spaced points 20 Hz…20 kHz (curve), ±18 dB.
    var curve: [Double] = [] { didSet { needsDisplay = true } }
    /// Output samples (scope), −1…1.
    var trace: [Float] = [] { didSet { needsDisplay = true } }
    /// The idle reading (bottom line), e.g. "−4.2 dB GR" or "−12 dBFS".
    var reading = "" { didSet { if reading != oldValue { needsDisplay = true } } }
    private var touched: (name: String, value: String, at: TimeInterval)?
    /// The figure's parameters (0…1, from the unit's link) and motion.
    var params: (a: Double, b: Double) = (0.5, 0.5) { didSet { if params != oldValue { needsDisplay = true } } }
    private(set) var phase: Double = 0
    var animates: Bool { [.tape, .spring, .tube, .lamp].contains(mode) }
    func advanceFigure(_ dt: Double) {
        guard animates, lit, !showingValue else { return }
        let speed: Double = switch mode {
        case .tape: 1.2 + 1.5 * (1 - params.a)      // a short delay, a fast loop
        case .spring: 3.2
        case .tube: 2.4
        case .lamp: 0.6 + 6 * params.a              // the LFO's rate
        default: 0
        }
        phase = (phase + dt * speed).truncatingRemainder(dividingBy: 2 * .pi * 64)
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { FigureClock.shared.add(self) } else { FigureClock.shared.remove(self) }
    }

    static let height: CGFloat = 32

    /// A control moved: show its name and value for a while.
    func showValue(_ name: String, _ value: String) {
        touched = (name, value, ProcessInfo.processInfo.systemUptime)
        needsDisplay = true
    }
    var showingValue: Bool { touched.map { ProcessInfo.processInfo.systemUptime - $0.at < 2.5 } ?? false }
    /// The text a reader sees now (tests and VoiceOver).
    var text: String { showingValue ? "\(touched!.name) \(touched!.value)" : reading }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        setAccessibilityValue(text)
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        // Bezel: a black recess with a light lower lip, as a window cut into the enclosure.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.addPath(CGPath(roundedRect: outer.offsetBy(dx: 0, dy: 0.8), cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        let glass = outer.insetBy(dx: 2, dy: 2)
        let back = glow.blended(withFraction: 0.86, of: .black) ?? .black
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: glass, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)); ctx.clip()
        ctx.setFillColor((lit ? back : NSColor(white: 0.06, alpha: 1)).cgColor); ctx.fill(glass)
        // Dot-matrix grid.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        var y = glass.minY + 1
        while y < glass.maxY { ctx.fill(CGRect(x: glass.minX, y: y, width: glass.width, height: 0.5)); y += 2 }
        if lit { drawContent(ctx, glass) }
        // Glass highlight.
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: glass.minY), end: CGPoint(x: 0, y: glass.midY), options: [])
        ctx.restoreGState()
    }

    private func drawContent(_ ctx: CGContext, _ r: CGRect) {
        let ink = glow.blended(withFraction: 0.25, of: .white) ?? glow
        let font = NSFont(name: "Menlo-Bold", size: 7.5) ?? .monospacedSystemFont(ofSize: 7.5, weight: .bold)
        let shadow = NSShadow(); shadow.shadowColor = glow; shadow.shadowBlurRadius = 3
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .shadow: shadow]
        if showingValue, let t = touched {
            // Two lines: the control's name, then its value large.
            let name = t.name.uppercased() as NSString
            name.draw(in: CGRect(x: r.minX + 4, y: r.minY + 2, width: r.width - 8, height: 10), withAttributes: attrs)
            let big: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Menlo-Bold", size: 11) ?? font, .foregroundColor: ink, .shadow: shadow]
            let v = t.value as NSString, vs = v.size(withAttributes: big)
            v.draw(at: CGPoint(x: r.maxX - 4 - vs.width, y: r.maxY - vs.height - 1), withAttributes: big)
            return
        }
        let plot = CGRect(x: r.minX + 4, y: r.minY + 3, width: r.width - 8, height: r.height - 15)
        ctx.setShadow(offset: .zero, blur: 3, color: glow.cgColor)
        switch mode {
        case .ladder:
            let n = 12, gap: CGFloat = 1.5, w = (plot.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let lit = Int((min(24, max(0, reduction)) / 24 * Double(n)).rounded()) // 1 segment = 2 dB
            for i in 0..<n {
                let on = i < lit
                ctx.setFillColor((on ? ink : glow.withAlphaComponent(0.16)).cgColor)
                ctx.fill(CGRect(x: plot.minX + CGFloat(i) * (w + gap), y: plot.minY + 1, width: w, height: plot.height - 2))
            }
        case .needle: // a small moving-coil meter reading gain reduction: 0 at the right, the needle falls left
            let pivot = CGPoint(x: r.midX - r.width * 0.12, y: r.maxY + r.height * 0.9), rad = r.height * 1.55
            func ang(_ db: Double) -> CGFloat { (-.pi / 2) + CGFloat(0.55 - 1.1 * min(1, db / 20)) }
            let arc = CGMutablePath(); arc.addArc(center: pivot, radius: rad, startAngle: ang(20), endAngle: ang(0), clockwise: false)
            ctx.addPath(arc); ctx.setStrokeColor(glow.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
            for db in [0.0, 2, 4, 6, 10, 20] {
                let a = ang(db), o = CGPoint(x: pivot.x + cos(a) * rad, y: pivot.y + sin(a) * rad), i = CGPoint(x: pivot.x + cos(a) * (rad - 3.5), y: pivot.y + sin(a) * (rad - 3.5))
                ctx.move(to: i); ctx.addLine(to: o); ctx.setStrokeColor(ink.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
            }
            let a = ang(reduction), tip = CGPoint(x: pivot.x + cos(a) * (rad + 1), y: pivot.y + sin(a) * (rad + 1))
            ctx.move(to: CGPoint(x: pivot.x + cos(a) * (rad - 14), y: pivot.y + sin(a) * (rad - 14))); ctx.addLine(to: tip)
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1.3); ctx.strokePath()
        case .curve: // the response, with a glow under it like a phosphor trace
            ctx.setStrokeColor(glow.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: plot.minX, y: plot.midY)); ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.midY)); ctx.strokePath()
            for k in 1...3 { // decade marks
                let x = plot.minX + plot.width * CGFloat(k) / 3
                ctx.move(to: CGPoint(x: x, y: plot.minY)); ctx.addLine(to: CGPoint(x: x, y: plot.maxY)); ctx.strokePath()
            }
            guard curve.count > 1 else { break }
            let line = CGMutablePath()
            for (i, db) in curve.enumerated() {
                let p = CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(curve.count - 1),
                                y: plot.midY - plot.height / 2 * CGFloat(max(-18, min(18, db)) / 18))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            let fill = line.mutableCopy()!
            fill.addLine(to: CGPoint(x: plot.maxX, y: plot.midY)); fill.addLine(to: CGPoint(x: plot.minX, y: plot.midY)); fill.closeSubpath()
            ctx.addPath(fill); ctx.setFillColor(glow.withAlphaComponent(0.22).cgColor); ctx.fillPath()
            ctx.addPath(line); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1.2); ctx.strokePath()
        case .tape, .spring, .tube, .lamp:
            drawFigure(ctx, plot, ink: ink)
        case .scope:
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1)
            guard trace.count > 1 else {
                ctx.move(to: CGPoint(x: plot.minX, y: plot.midY)); ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.midY)); ctx.strokePath()
                break
            }
            for (i, s) in trace.enumerated() {
                let p = CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(trace.count - 1), y: plot.midY - plot.height / 2 * CGFloat(max(-1, min(1, s))))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let line = reading.uppercased() as NSString
        let ls = line.size(withAttributes: attrs)
        line.draw(at: CGPoint(x: r.maxX - 4 - ls.width, y: r.maxY - ls.height), withAttributes: attrs)
    }

    /// The circuit's picture, in the window's light (`a`, `b`: the family's two parameters, 0…1).
    private func drawFigure(_ ctx: CGContext, _ r: CGRect, ink: NSColor) {
        let (a, b) = (CGFloat(params.a), CGFloat(params.b)), ph = CGFloat(phase)
        let dim = glow.withAlphaComponent(0.35)
        ctx.setLineCap(.round)
        func stroke(_ p: CGPath, _ c: NSColor, _ w: CGFloat) { ctx.addPath(p); ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w); ctx.strokePath() }
        switch mode {
        case .tape: // a loop of tape round two guides, the record head at the left, the play head moved out by the time
            let loop = CGRect(x: r.minX + 2, y: r.minY + 1, width: r.width * 0.62, height: r.height - 2)
            let path = CGPath(roundedRect: loop, cornerWidth: loop.height / 2, cornerHeight: loop.height / 2, transform: nil)
            stroke(path, dim, 1)
            // Tape moving: dashes travelling round the loop.
            ctx.saveGState(); ctx.setLineDash(phase: -ph * 6, lengths: [3, 4]); stroke(path, ink, 1.2); ctx.restoreGState()
            let rec = CGPoint(x: loop.minX + loop.height / 2, y: loop.maxY), play = CGPoint(x: loop.minX + loop.height / 2 + (loop.width - loop.height) * (0.2 + 0.8 * a), y: loop.maxY)
            for (h, label) in [(rec, "R"), (play, "P")] {
                ctx.setFillColor(ink.cgColor); ctx.fill(CGRect(x: h.x - 2, y: h.y - 2.5, width: 4, height: 3))
                _ = label
            }
            // The echoes leaving the play head: bars, each the feedback's fraction of the last.
            var x = loop.maxX + 6, hgt = r.height - 2, k = 0
            while x < r.maxX - 1 && hgt > 1 && k < 8 {
                let pulse = 0.55 + 0.45 * max(0, cos(ph - CGFloat(k) * 0.9))
                ctx.setFillColor(ink.withAlphaComponent(pulse).cgColor)
                ctx.fill(CGRect(x: x, y: r.maxY - hgt, width: 2, height: hgt))
                x += 4 + 6 * a; hgt *= 0.25 + 0.7 * b; k += 1
            }
        case .spring: // a coil between two mounts, swaying; the size its length, the decay how long it rings
            let x0 = r.minX + 3, x1 = r.minX + 3 + (r.width - 6) * (0.55 + 0.45 * a), y = r.midY
            ctx.setFillColor(ink.cgColor)
            for x in [x0, x1] { ctx.fill(CGRect(x: x - 1.5, y: y - 4, width: 3, height: 8)) }
            let coil = CGMutablePath(), turns = 14 + Int(10 * a)
            let sway = sin(ph) * (1.5 + 3 * b)
            for i in 0...turns * 8 {
                let t = CGFloat(i) / CGFloat(turns * 8), env = sin(t * .pi)
                let p = CGPoint(x: x0 + t * (x1 - x0) + cos(t * CGFloat(turns) * 2 * .pi) * 1.2,
                                y: y + sin(t * CGFloat(turns) * 2 * .pi) * 3 + sway * env)
                i == 0 ? coil.move(to: p) : coil.addLine(to: p)
            }
            stroke(coil, ink, 0.8)
            // The tail: how long it rings.
            let tail = CGMutablePath()
            for i in 0...30 { let t = CGFloat(i) / 30; let p = CGPoint(x: x1 + 4 + t * (r.maxX - x1 - 6), y: y - sin(ph * 2 - t * 9) * 4 * exp(-t * (4 - 3 * b))); i == 0 ? tail.move(to: p) : tail.addLine(to: p) }
            if r.maxX - x1 > 12 { stroke(tail, ink.withAlphaComponent(0.8), 0.9) }
        case .tube: // a triode: the filament glows with the drive; beside it the wave it clips
            let bulb = CGRect(x: r.minX + 2, y: r.minY, width: r.height * 0.8, height: r.height)
            stroke(CGPath(roundedRect: bulb, cornerWidth: bulb.width / 2, cornerHeight: bulb.width / 2, transform: nil), dim, 0.9)
            let heat = 0.45 + 0.55 * a * (0.85 + 0.15 * sin(ph * 3))
            ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 6 * heat, color: glow.cgColor)
            let fil = CGMutablePath()
            fil.move(to: CGPoint(x: bulb.midX - 3, y: bulb.maxY - 3)); fil.addLine(to: CGPoint(x: bulb.midX - 1.5, y: bulb.midY))
            fil.addLine(to: CGPoint(x: bulb.midX + 1.5, y: bulb.midY)); fil.addLine(to: CGPoint(x: bulb.midX + 3, y: bulb.maxY - 3))
            stroke(fil, ink.withAlphaComponent(heat), 1.3)
            ctx.restoreGState()
            ctx.setFillColor(dim.cgColor); ctx.fill(CGRect(x: bulb.minX + 2, y: bulb.minY + 4, width: bulb.width - 4, height: 1))
            let w = CGRect(x: bulb.maxX + 5, y: r.minY + 1, width: r.maxX - bulb.maxX - 6, height: r.height - 2)
            let k = 1 + 8 * a, wave = CGMutablePath()
            for i in 0...60 { let t = CGFloat(i) / 60; let v = tanh(k * sin(ph - t * 4 * .pi)) / tanh(k); let p = CGPoint(x: w.minX + t * w.width, y: w.midY - v * w.height / 2); i == 0 ? wave.move(to: p) : wave.addLine(to: p) }
            stroke(wave, ink, 1.1)
        case .lamp: // the LFO's wave with a lamp at the left that brightens with it; depth is the wave's height
            let lampC = CGPoint(x: r.minX + 6, y: r.midY), level = 0.5 + 0.5 * sin(ph)
            ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 2 + 7 * level * (0.4 + 0.6 * b), color: glow.cgColor)
            ctx.setFillColor(ink.withAlphaComponent(0.3 + 0.7 * level).cgColor); ctx.fillEllipse(in: CGRect(x: lampC.x - 3.5, y: lampC.y - 3.5, width: 7, height: 7))
            ctx.restoreGState()
            let w = CGRect(x: r.minX + 15, y: r.minY + 1, width: r.width - 16, height: r.height - 2)
            let cycles = 1 + 4 * a, amp = w.height / 2 * (0.2 + 0.8 * b), wave = CGMutablePath()
            for i in 0...60 { let t = CGFloat(i) / 60; let p = CGPoint(x: w.minX + t * w.width, y: w.midY - sin(ph - t * cycles * 2 * .pi) * amp); i == 0 ? wave.move(to: p) : wave.addLine(to: p) }
            stroke(wave, ink, 1.1)
        default: break
        }
    }
}
