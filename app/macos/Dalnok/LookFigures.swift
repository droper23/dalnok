// Prism's plug-in figures, "optics" (the owner, 2026-11-23: bring the other looks to Atelier's level; Graphite's
// telemetry figures and Warm Analog's moving pedal circuits were tried the same day and went back). The same five
// families, parameters, handles, hover links and motion as Atelier's engraved figures (AtelierFigures.swift), drawn as
// light on the card's glass, coloured by the spectrum. Dynamics: an iris that closes as it reduces; reverb: caustic
// rings spreading in a pool; delay: light echoes, each a step further along the spectrum; distortion: a sine refracted
// by a prism into its harmonics; modulation: two waves interfering.
// Drag a part (it lights, with its parameter's name and value); the figure holds still under the pointer.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

extension FaceplateScreen {
    /// Graphite and Prism draw the figure in place of the display. Returns false where the look has none.
    func drawLookFigure(_ ctx: CGContext) -> Bool {
        guard let fig = atelierFigure, Theme.look.devices == .cards else { return false }
        let prism = Theme.look.devices == .cards
        let live: Double = switch self {
        case let m as MovingCoilMeter: m.reductionDb
        case let h as HistoryScreen: Double(h.latest.output)
        default: -90
        }
        figureLive = live
        let link = figureLink ?? FigureLink()
        var f = bounds.insetBy(dx: 4, dy: 4)
        if !prism { // Graphite: the unit's screen, a dark glass window, with a faint dot grid
            f = FaceplateDisplay.bezel(ctx, bounds)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: f, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.clip()
            let bg = [NSColor(srgbRed: 0.02, green: 0.04, blue: 0.045, alpha: 1).cgColor, NSColor(srgbRed: 0.035, green: 0.065, blue: 0.07, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: f.minY), end: CGPoint(x: 0, y: f.maxY), options: [])
            }
            ctx.setFillColor(LookPen.phosphor.withAlphaComponent(0.09).cgColor)
            let grid = CGMutablePath() // one fill for the whole grid
            var x = f.minX + 4; while x < f.maxX { var y = f.minY + 4; while y < f.maxY { grid.addRect(CGRect(x: x, y: y, width: 1, height: 1)); y += 8 }; x += 8 }
            ctx.addPath(grid); ctx.fillPath()
        }
        ctx.saveGState()
        let pen = LookPen(prism: prism, ctx: ctx, screen: self, link: link, dim: poweredOff ? 0.35 : 1)
        ctx.setAlpha(pen.dim)
        let field = f.insetBy(dx: 6, dy: 5)
        var handles: [FigureHandle] = []
        switch fig {
        case .governor: handles = pen.aperture(field, reductionDb: live)
        case .chamber: handles = pen.caustics(field, energyDb: live)
        case .pendulum: handles = pen.lightEchoes(field)
        case .clipping: handles = pen.refraction(field)
        case .crank: handles = pen.interference(field)
        }
        figureHandles = handles
        for h in handles where link.ids[h.role] != nil { pen.handle(h, lit: isLit(h.role)) }
        pen.caption(fig, field)
        ctx.restoreGState()
        if !prism {
            ctx.restoreGState()
            FaceplateDisplay.glass(ctx, f, radius: 3)
            FaceplateDisplay.wear(ctx, bounds.insetBy(dx: 4, dy: 4), radius: 3, seed: seed, amount: Faceplate.wear, lightFace: false)
        }
        return true
    }
    func isLit(_ role: FigureRole) -> Bool { figureDrag?.role == role || hoverRole == role || highlightRole == role }
}

/// Draws one look's figures: the strokes, the handles and the tags in that look's idiom.
@MainActor
struct LookPen {
    let prism: Bool
    let ctx: CGContext
    let screen: FaceplateScreen
    let link: FigureLink
    /// A bypassed unit's figure is drawn faint; every stroke's own alpha is multiplied by this.
    var dim: CGFloat = 1
    var angle: CGFloat { CGFloat(screen.figureAngle) }
    /// The spectrum, built once per version (light, dark).
    private static var spectra: [Bool: CGGradient] = [:]
    func spectrum() -> CGGradient? {
        if let g = Self.spectra[light] { return g }
        let cols = (0...6).map { hue(CGFloat($0) / 6).cgColor } as CFArray
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: nil)
        Self.spectra[light] = g
        return g
    }

    /// Graphite's phosphor (signal) and amber (what you hold).
    static let phosphor = Theme.hex(0x5FE3C4)
    static let amber = Theme.hex(0xF2B35A)
    var light: Bool { prism && Theme.isLight }
    /// Ink for text and fine marks.
    var ink: NSColor { prism ? (light ? Theme.text.withAlphaComponent(0.8) : NSColor.white.withAlphaComponent(0.82)) : Self.phosphor.withAlphaComponent(0.85) }
    var faint: NSColor { prism ? (light ? Theme.text.withAlphaComponent(0.28) : NSColor.white.withAlphaComponent(0.25)) : Self.phosphor.withAlphaComponent(0.25) }
    var holdColor: NSColor { prism ? (light ? Theme.hex(0x3F5BD9) : Theme.hex(0xBFEFFF)) : Self.amber }

    /// A colour of the spectrum, 0 red … 1 violet (Prism's hue for a frequency, a repeat, a harmonic).
    func hue(_ t: CGFloat, alpha: CGFloat = 1) -> NSColor {
        let h = 0.0 + 0.78 * max(0, min(1, t))
        return NSColor(calibratedHue: h, saturation: light ? 0.75 : 0.6, brightness: light ? 0.72 : 1, alpha: alpha)
    }

    // MARK: Strokes

    /// The signal's line: phosphor with a glow (Graphite) or light dispersed along the spectrum from `x0` to `x1` (Prism).
    func trace(_ path: CGPath, width: CGFloat = 1.6, x0: CGFloat? = nil, x1: CGFloat? = nil, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.setAlpha(alpha * dim)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        if prism {
            let b = path.boundingBox
            if !light { // a soft bloom under the light
                ctx.addPath(path); ctx.setLineWidth(width * 3.2); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor); ctx.strokePath()
            }
            ctx.addPath(path); ctx.setLineWidth(width); ctx.replacePathWithStrokedPath(); ctx.clip()
            if let g = spectrum() {
                ctx.drawLinearGradient(g, start: CGPoint(x: x0 ?? b.minX, y: 0), end: CGPoint(x: x1 ?? b.maxX, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        } else {
            ctx.setShadow(offset: .zero, blur: 4, color: Self.phosphor.withAlphaComponent(0.8).cgColor)
            ctx.addPath(path); ctx.setLineWidth(width); ctx.setStrokeColor(Self.phosphor.cgColor); ctx.strokePath()
        }
        ctx.restoreGState()
    }
    /// A fine line of the drawing's furniture (axes, guides).
    func rule(_ a: CGPoint, _ b: CGPoint, alpha: CGFloat = 1, dash: [CGFloat] = []) {
        ctx.saveGState()
        ctx.setStrokeColor(faint.withAlphaComponent(faint.alphaComponent * alpha).cgColor); ctx.setLineWidth(0.6)
        if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.restoreGState()
    }
    /// A glowing dot (Graphite) or a bead of light (Prism).
    func dot(_ c: CGPoint, r: CGFloat, color: NSColor? = nil, alpha: CGFloat = 1, glow: Bool = true) {
        let col = color ?? (prism ? (light ? Theme.text : NSColor.white) : Self.phosphor)
        ctx.saveGState()
        ctx.setAlpha(alpha * dim)
        if !light && glow { ctx.setShadow(offset: .zero, blur: r * 2.4, color: col.cgColor) }
        ctx.setFillColor(col.cgColor); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.restoreGState()
    }
    func text(_ s: String, _ p: CGPoint, size: CGFloat = 8.5, color: NSColor? = nil, align: NSTextAlignment = .left) {
        let font = prism ? Theme.ui(size, .medium) : Theme.mono(size - 0.5, .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? ink]
        let z = (s as NSString).size(withAttributes: attrs)
        let x = align == .center ? p.x - z.width / 2 : align == .right ? p.x - z.width : p.x
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (s as NSString).draw(at: CGPoint(x: x, y: p.y), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Handles and tags

    /// A part that can be dragged: Graphite's amber target with ticks along its axis, Prism's ring of light; lit, it fills.
    func handle(_ h: FigureHandle, lit: Bool) {
        let c = h.point, len = max(0.001, hypot(h.axis.dx, h.axis.dy)), ux = h.axis.dx / len, uy = h.axis.dy / len
        ctx.saveGState()
        if prism {
            let r: CGFloat = lit ? 6 : 4.6
            if !light { ctx.setShadow(offset: .zero, blur: lit ? 10 : 6, color: holdColor.cgColor) }
            ctx.setFillColor((light ? NSColor.white : NSColor.black).withAlphaComponent(0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.setStrokeColor(holdColor.cgColor); ctx.setLineWidth(lit ? 2 : 1.4)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if lit { ctx.setFillColor(holdColor.cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)) }
        } else {
            let s: CGFloat = lit ? 5 : 3.8
            let box = CGRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s)
            ctx.setShadow(offset: .zero, blur: lit ? 6 : 3, color: Self.amber.withAlphaComponent(0.8).cgColor)
            ctx.setFillColor((lit ? Self.amber : NSColor.black).withAlphaComponent(lit ? 1 : 0.6).cgColor); ctx.fill(box)
            ctx.setStrokeColor(Self.amber.cgColor); ctx.setLineWidth(1); ctx.stroke(box)
        }
        ctx.restoreGState()
        // Which way it moves: two small chevrons along its axis.
        for sgn in [CGFloat(1), -1] {
            let tip = CGPoint(x: c.x + sgn * ux * 12, y: c.y + sgn * uy * 12)
            let back = CGPoint(x: c.x + sgn * ux * 8.5, y: c.y + sgn * uy * 8.5)
            let n = CGPoint(x: -uy * 2.6, y: ux * 2.6)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: back.x + n.x, y: back.y + n.y)); p.addLine(to: tip); p.addLine(to: CGPoint(x: back.x - n.x, y: back.y - n.y))
            ctx.addPath(p); ctx.setStrokeColor(holdColor.withAlphaComponent(lit ? 1 : 0.55).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        }
    }
    /// A part's value where the figure prints it; lit, a tag with the parameter's name too (kept inside the screen).
    func tag(_ role: FigureRole, at p: CGPoint, align: NSTextAlignment = .left) {
        guard let id = link.ids[role] else { return }
        let lit = screen.isLit(role)
        let value = link.text(id) ?? ""
        guard lit else { if !value.isEmpty { text(value, p, size: 8.5, color: ink.withAlphaComponent(0.75), align: align) }; return }
        let name = link.name(id) ?? role.rawValue.capitalized
        let s = value.isEmpty ? name : "\(name)  \(value)"
        let font = prism ? Theme.ui(9, .semibold) : Theme.mono(8.5, .semibold)
        let w = (s as NSString).size(withAttributes: [.font: font]).width + 10
        var box = CGRect(x: align == .right ? p.x - w + 5 : align == .center ? p.x - w / 2 : p.x - 5, y: p.y - 2, width: w, height: 14)
        let room = screen.bounds.insetBy(dx: 6, dy: 6)
        box.origin.x = max(room.minX, min(room.maxX - w, box.origin.x))
        box.origin.y = max(room.minY, min(room.maxY - 14, box.origin.y))
        ctx.saveGState()
        if prism {
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.setFillColor((light ? NSColor.white : NSColor.black).withAlphaComponent(light ? 0.85 : 0.55).cgColor); ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.setStrokeColor(holdColor.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        } else {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor); ctx.fill(box)
            ctx.setStrokeColor(Self.amber.cgColor); ctx.setLineWidth(1); ctx.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        }
        ctx.restoreGState()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: prism ? (light ? Theme.text : NSColor.white) : Self.amber]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (s as NSString).draw(at: CGPoint(x: box.minX + 5, y: box.minY + 1.5), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
    /// The figure's name in the screen's corner (Graphite in capitals like a readout, Prism quietly on the glass).
    func caption(_ fig: AtelierFigure, _ f: CGRect) {
        let name = fig.prismTitle
        text(prism ? name : name.uppercased(), CGPoint(x: f.minX, y: f.minY - 1), size: prism ? 8 : 7.5, color: ink.withAlphaComponent(0.5))
    }
    func note(_ s: String, _ f: CGRect) { text(s, CGPoint(x: f.maxX, y: f.minY - 1), size: 8, color: ink.withAlphaComponent(0.55), align: .right) }

    // MARK: Prism: optics

    /// Dynamics: an iris round a source of light. The aperture closes as the gain is reduced, and turns slowly;
    /// beside it, the curve the light follows (threshold at its knee, ratio its slope).
    func aperture(_ f: CGRect, reductionDb: Double) -> [FigureHandle] {
        let red = CGFloat(min(1, abs(reductionDb) / 18))
        let R = min(f.height / 2 - 8, f.width * 0.22), c = CGPoint(x: f.minX + R + 10, y: f.midY + 4)
        // The light behind the iris.
        let glow = [hue(0.55, alpha: light ? 0.35 : 0.55).cgColor, hue(0.75, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: R * 1.1, options: [])
        }
        // The aperture is a polygon; each blade runs from one of its corners out to the rim, as a camera's iris.
        let open = R * (0.72 - 0.5 * red), blades = 7
        let turn = angle * 0.25
        let corners = (0..<blades).map { i -> CGPoint in
            let a = turn + CGFloat(i) * 2 * .pi / CGFloat(blades)
            return CGPoint(x: c.x + cos(a) * open, y: c.y + sin(a) * open)
        }
        let leaves = CGMutablePath()
        leaves.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        leaves.addLines(between: corners); leaves.closeSubpath()
        ctx.saveGState()
        ctx.addPath(leaves); ctx.setFillColor((light ? Theme.hex(0xDCE3F2) : NSColor.black).withAlphaComponent(light ? 0.85 : 0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        for (i, p) in corners.enumerated() {
            // The blade's edge: from this corner, along the next side's direction, to the rim.
            let q = corners[(i + 1) % blades], dx = q.x - p.x, dy = q.y - p.y, d = max(0.001, hypot(dx, dy))
            let ux = dx / d, uy = dy / d
            let b = (p.x - c.x) * ux + (p.y - c.y) * uy, cc = pow(p.x - c.x, 2) + pow(p.y - c.y, 2) - R * R
            let t = -b + sqrt(max(0, b * b - cc))
            let edge = CGMutablePath(); edge.move(to: p); edge.addLine(to: CGPoint(x: p.x + ux * t, y: p.y + uy * t))
            trace(edge, width: 0.8, x0: c.x - R, x1: c.x + R, alpha: 0.7)
        }
        let hole = CGMutablePath(); hole.addLines(between: corners); hole.closeSubpath()
        trace(hole, width: 1.2, x0: c.x - open, x1: c.x + open)
        let rim = CGMutablePath(); rim.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        trace(rim, width: 1.4, x0: c.x - R, x1: c.x + R)
        // The curve the light follows.
        let side = min(f.height - 16, f.maxX - (c.x + R) - 22)
        let plot = CGRect(x: f.maxX - side - 4, y: f.minY + 12, width: side, height: side)
        let thr = CGFloat(link.v(.threshold, 0.6)), ratio = CGFloat(link.v(.ratio, 0.4))
        let tIn = 0.25 + 0.6 * thr, slope = 1 / (1 + 7 * ratio)
        func pt(_ x: CGFloat) -> CGPoint { CGPoint(x: plot.minX + x * side, y: plot.maxY - (x <= tIn ? x : tIn + (x - tIn) * slope) * side) }
        rule(CGPoint(x: plot.minX, y: plot.maxY), CGPoint(x: plot.maxX, y: plot.maxY)); rule(CGPoint(x: plot.minX, y: plot.minY), CGPoint(x: plot.minX, y: plot.maxY))
        let curve = CGMutablePath(); curve.move(to: pt(0)); for i in 1...30 { curve.addLine(to: pt(CGFloat(i) / 30)) }
        trace(curve, width: 1.8, x0: plot.minX, x1: plot.maxX)
        let knee = pt(tIn), top = pt(1)
        tag(.threshold, at: CGPoint(x: knee.x + 10, y: knee.y + 8))
        tag(.ratio, at: CGPoint(x: top.x - 14, y: top.y - 16), align: .right)
        // The reduction under the iris (the corner is the curve's).
        text(abs(reductionDb) < 0.05 ? "open" : String(format: "−%.1f dB", abs(reductionDb)), CGPoint(x: c.x, y: min(f.maxY - 10, c.y + R + 1)),
             size: 8, color: ink.withAlphaComponent(0.6), align: .center)
        return [FigureHandle(role: .threshold, point: knee, axis: CGVector(dx: 1, dy: -1), span: side * 0.8),
                FigureHandle(role: .ratio, point: top, axis: CGVector(dx: 0, dy: 1), span: side * 0.6)]
    }

    /// Reverb: rings of light spreading across a pool from where the sound falls, each a colour further along the
    /// spectrum; the pool's width is the size, how far the rings carry before they fade the decay.
    func caustics(_ f: CGRect, energyDb: Double) -> [FigureHandle] {
        let size = CGFloat(link.v(.size, 0.5)), decay = CGFloat(link.v(.decay, 0.5))
        let pool = CGRect(x: f.midX - f.width * (0.22 + 0.26 * size), y: f.minY + 14, width: f.width * (0.44 + 0.52 * size), height: f.height - 20)
        let c = CGPoint(x: pool.midX, y: pool.midY)
        let rim = CGMutablePath(); rim.addEllipse(in: pool)
        trace(rim, width: 1, x0: pool.minX, x1: pool.maxX, alpha: 0.6)
        let reach = 0.35 + 0.65 * decay
        let phase = (angle / (2 * .pi)).truncatingRemainder(dividingBy: 1)
        ctx.saveGState(); ctx.addEllipse(in: pool); ctx.clip()
        for k in 0..<6 {
            let t = (CGFloat(k) / 6 + phase).truncatingRemainder(dividingBy: 1) // 0 at the centre, 1 at the rim
            guard t < reach else { continue }
            let fade = 1 - t / reach
            let ring = CGMutablePath(); ring.addEllipse(in: CGRect(x: c.x - pool.width / 2 * t, y: c.y - pool.height / 2 * t, width: pool.width * t, height: pool.height * t))
            ctx.saveGState(); ctx.setAlpha(fade)
            ctx.addPath(ring); ctx.setLineWidth(1.4 + 1.4 * fade); ctx.setStrokeColor(hue(t * 0.9).cgColor)
            if !light { ctx.setShadow(offset: .zero, blur: 6, color: hue(t * 0.9).cgColor) }
            ctx.strokePath(); ctx.restoreGState()
        }
        ctx.restoreGState()
        dot(c, r: 2.4)
        let sizeP = CGPoint(x: pool.maxX, y: c.y), decayP = CGPoint(x: c.x + pool.width / 2 * reach * 0.98, y: c.y - pool.height / 2 * reach * 0.0)
        let decayMark = CGPoint(x: c.x, y: c.y - pool.height / 2 * reach)
        _ = decayP
        tag(.size, at: CGPoint(x: sizeP.x - 6, y: c.y + 8), align: .right)
        tag(.decay, at: CGPoint(x: decayMark.x + 8, y: decayMark.y - 4))
        if energyDb > -80 { note(String(format: "%.0f dB", energyDb), f) }
        return [FigureHandle(role: .size, point: sizeP, axis: CGVector(dx: 1, dy: 0), span: f.width * 0.26),
                FigureHandle(role: .decay, point: decayMark, axis: CGVector(dx: 0, dy: -1), span: pool.height * 0.5)]
    }

    /// Delay: a pulse of light leaves at the left and repeats along the beam, each echo fainter by the feedback and a
    /// step further along the spectrum; the spacing is the time.
    func lightEchoes(_ f: CGRect) -> [FigureHandle] {
        let time = CGFloat(link.v(.time, 0.4)), fb = CGFloat(link.v(.feedback, 0.5))
        let y = f.midY + 4, x0 = f.minX + 10, gap = f.width * (0.08 + 0.3 * time), g = 0.2 + 0.75 * fb
        let beam = CGMutablePath(); beam.move(to: CGPoint(x: x0, y: y)); beam.addLine(to: CGPoint(x: f.maxX - 4, y: y))
        trace(beam, width: 0.8, x0: x0, x1: f.maxX, alpha: 0.5)
        let travel = (angle / (2 * .pi)).truncatingRemainder(dividingBy: 1) // the pulse moves out along each gap
        var x = x0, a: CGFloat = 1, i = 0, second = CGPoint.zero
        while x < f.maxX - 4 && a > 0.04 {
            let r = 3 + 9 * a
            let col = hue(CGFloat(i) * 0.13)
            ctx.saveGState()
            if !light { ctx.setShadow(offset: .zero, blur: 10 * a + 2, color: col.cgColor) }
            let glow = [col.withAlphaComponent(0.9 * a).cgColor, col.withAlphaComponent(0).cgColor] as CFArray
            if let gg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow, locations: [0, 1]) {
                ctx.drawRadialGradient(gg, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r * 1.8, options: [])
            }
            ctx.restoreGState()
            dot(CGPoint(x: x, y: y), r: 1.2 + 1.6 * a, color: col, alpha: a)
            if i == 1 { second = CGPoint(x: x, y: y - r * 1.6) }
            // The pulse in flight between this echo and the next.
            if i == 0 { dot(CGPoint(x: x + gap * travel, y: y), r: 2.2, color: hue(0.13 * travel), alpha: 1 - 0.3 * travel) }
            x += gap; a *= g; i += 1
        }
        if second == .zero { second = CGPoint(x: x0 + gap, y: y - 10) }
        let timeP = CGPoint(x: x0 + gap, y: y + 16)
        rule(CGPoint(x: x0, y: y + 16), timeP, alpha: 2)
        tag(.time, at: CGPoint(x: x0 + gap / 2, y: y + 20), align: .center)
        tag(.feedback, at: CGPoint(x: second.x + 8, y: second.y - 12))
        return [FigureHandle(role: .time, point: timeP, axis: CGVector(dx: 1, dy: 0), span: f.width * 0.3),
                FigureHandle(role: .feedback, point: second, axis: CGVector(dx: 0, dy: -1), span: 30)]
    }

    /// Distortion: a sine enters a prism and leaves split into its harmonics, more of them, and brighter, with drive.
    func refraction(_ f: CGRect) -> [FigureHandle] {
        let drive = CGFloat(link.v(.drive, 0.4))
        let apex = CGPoint(x: f.midX, y: f.minY + 12 + (1 - drive) * 10)
        let base = f.maxY - 8, hw = (base - apex.y) * 0.62
        let tri = CGMutablePath()
        tri.move(to: apex); tri.addLine(to: CGPoint(x: apex.x + hw, y: base)); tri.addLine(to: CGPoint(x: apex.x - hw, y: base)); tri.closeSubpath()
        ctx.saveGState(); ctx.addPath(tri); ctx.setFillColor((light ? NSColor.white : NSColor.white).withAlphaComponent(light ? 0.5 : 0.06).cgColor); ctx.fillPath(); ctx.restoreGState()
        trace(tri, width: 1.2, x0: apex.x - hw, x1: apex.x + hw)
        let entry = CGPoint(x: apex.x - hw * 0.5, y: (apex.y + base) / 2)
        // The incoming sine.
        let wave = CGMutablePath()
        for i in 0...40 {
            let t = CGFloat(i) / 40
            let p = CGPoint(x: f.minX + 4 + t * (entry.x - f.minX - 4), y: entry.y - sin(angle - t * 3 * .pi) * 7 * (1 - t * 0.6))
            i == 0 ? wave.move(to: p) : wave.addLine(to: p)
        }
        trace(wave, width: 1.6, x0: f.minX, x1: entry.x, alpha: 0.9)
        // The harmonics leaving the far face: a fan of waves, one per harmonic, each its own colour.
        let exit = CGPoint(x: apex.x + hw * 0.5, y: (apex.y + base) / 2)
        let count = 2 + Int(drive * 5)
        for h in 0..<count {
            let spread = (CGFloat(h) - CGFloat(count - 1) / 2) * (6 + 4 * drive)
            let w = CGMutablePath()
            for i in 0...36 {
                let t = CGFloat(i) / 36
                let p = CGPoint(x: exit.x + t * (f.maxX - 4 - exit.x), y: exit.y + spread * t * 2.2 - sin(angle * CGFloat(h + 1) - t * CGFloat(h + 2) * 2 * .pi) * (4 - CGFloat(h) * 0.4) * t)
                i == 0 ? w.move(to: p) : w.addLine(to: p)
            }
            ctx.saveGState(); ctx.setAlpha(max(0.25, 1 - CGFloat(h) * 0.12) * (0.5 + 0.5 * drive))
            ctx.addPath(w); ctx.setLineWidth(1.3); ctx.setLineCap(.round); ctx.setStrokeColor(hue(CGFloat(h) / CGFloat(max(1, count - 1))).cgColor)
            if !light { ctx.setShadow(offset: .zero, blur: 4, color: hue(CGFloat(h) / CGFloat(max(1, count - 1))).cgColor) }
            ctx.strokePath(); ctx.restoreGState()
        }
        tag(.drive, at: CGPoint(x: apex.x + 10, y: apex.y - 2))
        return [FigureHandle(role: .drive, point: apex, axis: CGVector(dx: 0, dy: -1), span: 30)]
    }

    /// Modulation: two waves of light, one steady and one moved by the LFO, interfering where they cross (bright
    /// where they agree); rate sets the moving one's wavelength, depth how far it is moved.
    func interference(_ f: CGRect) -> [FigureHandle] {
        let rate = CGFloat(link.v(.rate, 0.4)), depth = CGFloat(link.v(.depth, 0.5))
        let plot = CGRect(x: f.minX + 4, y: f.minY + 14, width: f.width - 8, height: f.height - 20)
        let amp = (plot.height / 2 - 4) * (0.2 + 0.8 * depth), cycles = 0.8 + 4 * rate
        func y1(_ t: CGFloat) -> CGFloat { plot.midY - sin(t * 3 * 2 * .pi) * (plot.height / 2 - 6) * 0.5 }
        func y2(_ t: CGFloat) -> CGFloat { plot.midY - sin(angle + t * cycles * 2 * .pi) * amp }
        let a = CGMutablePath(), b = CGMutablePath()
        for i in 0...90 {
            let t = CGFloat(i) / 90, x = plot.minX + t * plot.width
            i == 0 ? a.move(to: CGPoint(x: x, y: y1(t))) : a.addLine(to: CGPoint(x: x, y: y1(t)))
            i == 0 ? b.move(to: CGPoint(x: x, y: y2(t))) : b.addLine(to: CGPoint(x: x, y: y2(t)))
        }
        trace(a, width: 1, x0: plot.minX, x1: plot.maxX, alpha: 0.45)
        trace(b, width: 1.7, x0: plot.maxX, x1: plot.minX)
        // Where they meet, a flash of white light.
        for i in 0..<90 {
            let t = CGFloat(i) / 90, t2 = CGFloat(i + 1) / 90
            if (y1(t) - y2(t)) * (y1(t2) - y2(t2)) <= 0 { dot(CGPoint(x: plot.minX + t * plot.width, y: (y1(t) + y2(t)) / 2), r: 2, alpha: 0.9) }
        }
        let wl = plot.width / cycles
        let rateP = CGPoint(x: min(plot.maxX - 4, plot.minX + wl), y: plot.maxY - 2)
        let depthP = CGPoint(x: plot.minX + plot.width * 0.62, y: plot.midY - amp)
        rule(CGPoint(x: plot.minX, y: plot.maxY - 2), rateP, alpha: 2)
        tag(.rate, at: CGPoint(x: rateP.x + 8, y: plot.maxY - 14))
        tag(.depth, at: CGPoint(x: depthP.x + 8, y: max(plot.minY, depthP.y - 14)))
        return [FigureHandle(role: .rate, point: rateP, axis: CGVector(dx: -1, dy: 0), span: plot.width * 0.6),
                FigureHandle(role: .depth, point: depthP, axis: CGVector(dx: 0, dy: -1), span: plot.height * 0.4)]
    }
}

extension AtelierFigure {
    var prismTitle: String {
        switch self {
        case .governor: "Aperture"
        case .chamber: "Caustics"
        case .pendulum: "Light echoes"
        case .clipping: "Refraction"
        case .crank: "Interference"
        }
    }
}

/// A figure's draggable part for VoiceOver and keyboard users: an adjustable slider named after its parameter, whose
/// increment and decrement move the value by a twentieth (the review: the parts weren't reachable without a mouse).
/// Built fresh each time VoiceOver asks (as `AXItem` is).
final class FigurePartElement: NSAccessibilityElement {
    var onStep: ((Double) -> Bool)?
    override func accessibilityPerformIncrement() -> Bool { onStep?(0.05) ?? false }
    override func accessibilityPerformDecrement() -> Bool { onStep?(-0.05) ?? false }
}

extension FaceplateScreen {
    /// The figure's parts as VoiceOver sliders (only the parts linked to a parameter).
    func figureAccessibilityChildren() -> [Any]? {
        guard let fig = atelierFigure, let link = figureLink else { return nil }
        return fig.roles.compactMap { role -> FigurePartElement? in
            guard let id = link.ids[role] else { return nil }
            let e = FigurePartElement()
            e.setAccessibilityRole(.slider)
            e.setAccessibilityLabel(link.name(id) ?? role.rawValue.capitalized)
            if let t = link.text(id) { e.setAccessibilityValue(t) }
            e.setAccessibilityParent(self)
            if let h = figureHandles.first(where: { $0.role == role }), let w = window {
                e.setAccessibilityFrame(w.convertToScreen(convert(NSRect(x: h.point.x - 8, y: h.point.y - 8, width: 16, height: 16), to: nil)))
            }
            e.onStep = { [weak self] d in
                guard let self, let link = self.figureLink, let v = link.value(id) else { return false }
                link.begin(); link.set(id, max(0, min(1, v + d))); link.end()
                self.needsDisplay = true
                return true
            }
            return e
        }
    }
}
